import Foundation
import UsageCore

/// Reads Claude subscription quota windows using a Claude OAuth token.
public struct AnthropicUsageProvider: UsageProvider, Sendable {
    public let provider: Provider = .anthropic

    private let baseURL: URL
    private let now: @Sendable () -> Date

    public init(
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.now = now
    }

    public func fetch(
        connection: AccountConnection,
        credential: OAuthCredential,
        period: DateInterval,
        client: any ProviderHTTPClient
    ) async -> Result<UsageSnapshot, ProviderFailure> {
        guard connection.provider == .anthropic,
              connection.surface == .consumerSubscription else {
            return .failure(.unsupported)
        }
        guard !credential.accessToken.isEmpty else {
            return .failure(.authRequired)
        }

        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/oauth/usage"))
            request.httpMethod = "GET"
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("LLMUsageWidget/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await client.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                return .failure(Self.failure(for: response, data: data))
            }
            let payload = try JSONDecoder().decode(AnthropicQuotaResponse.self, from: data)
            let fetchedAt = now()
            let metrics = payload.metrics(now: fetchedAt)
            return .success(UsageSnapshot(
                accountID: connection.id,
                provider: provider,
                surface: connection.surface,
                identity: connection.identity,
                freshness: Freshness(
                    fetchedAt: fetchedAt,
                    asOf: fetchedAt,
                    state: metrics.isEmpty ? .noData : .fresh
                ),
                metrics: metrics,
                failure: metrics.isEmpty ? .noData : nil
            ))
        } catch is DecodingError {
            return .failure(.invalidResponse)
        } catch {
            return .failure(.offline)
        }
    }

    private static func failure(
        for response: HTTPURLResponse,
        data: Data
    ) -> ProviderFailure {
        switch response.statusCode {
        case 401:
            return .authRequired
        case 403:
            return .permissionDenied
        case 429:
            return .rateLimited(
                retryAt: retryDate(from: response.value(forHTTPHeaderField: "Retry-After"))
            )
        default:
            let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.type
            return .providerError(code: code)
        }
    }

    private static func retryDate(from value: String?) -> Date? {
        guard let value, let seconds = TimeInterval(value) else { return nil }
        return Date().addingTimeInterval(seconds)
    }
}

private struct AnthropicQuotaResponse: Decodable, Sendable {
    let fiveHour: QuotaWindow?
    let sevenDay: QuotaWindow?
    let sevenDayOAuthApps: QuotaWindow?
    let sevenDayOpus: QuotaWindow?
    let sevenDaySonnet: QuotaWindow?
    let sevenDayRoutines: QuotaWindow?
    let limits: [LimitEntry]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        fiveHour = Self.decodeWindow(in: container, key: "five_hour")
        sevenDay = Self.decodeWindow(in: container, key: "seven_day")
        sevenDayOAuthApps = Self.decodeWindow(in: container, key: "seven_day_oauth_apps")
        sevenDayOpus = Self.decodeWindow(in: container, key: "seven_day_opus")
        sevenDaySonnet = Self.decodeWindow(in: container, key: "seven_day_sonnet")
        sevenDayRoutines = Self.decodeFirstWindow(
            in: container,
            keys: [
                "seven_day_routines",
                "seven_day_claude_routines",
                "claude_routines",
                "routines",
                "routine",
                "seven_day_cowork",
                "cowork"
            ]
        )
        limits = Self.decodeValue(in: container, key: "limits")
    }

    private static func decodeWindow(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        key name: String
    ) -> QuotaWindow? {
        guard let key = DynamicCodingKey(stringValue: name) else { return nil }
        return try? container.decodeIfPresent(QuotaWindow.self, forKey: key)
    }

    private static func decodeFirstWindow(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        keys: [String]
    ) -> QuotaWindow? {
        for keyName in keys {
            if let value = decodeWindow(in: container, key: keyName) {
                return value
            }
        }
        return nil
    }

    private static func decodeValue<T: Decodable>(
        in container: KeyedDecodingContainer<DynamicCodingKey>,
        key name: String
    ) -> T? {
        guard let key = DynamicCodingKey(stringValue: name) else { return nil }
        return try? container.decodeIfPresent(T.self, forKey: key)
    }

    func metrics(now: Date) -> [UsageMetric] {
        var values = [
            fiveHour.flatMap { $0.metric(key: "anthropic.oauth.rate_limit.five_hour", now: now, seconds: 18_000) },
            sevenDay.flatMap { $0.metric(key: "anthropic.oauth.rate_limit.seven_day", now: now, seconds: 604_800) },
            sevenDayOAuthApps.flatMap {
                $0.metric(key: "anthropic.oauth.rate_limit.seven_day_oauth_apps", now: now, seconds: 604_800)
            },
            sevenDayOpus.flatMap {
                $0.metric(key: "anthropic.oauth.rate_limit.seven_day_opus", now: now, seconds: 604_800)
            },
            sevenDaySonnet.flatMap {
                $0.metric(key: "anthropic.oauth.rate_limit.seven_day_sonnet", now: now, seconds: 604_800)
            },
            sevenDayRoutines.flatMap {
                $0.metric(key: "anthropic.oauth.rate_limit.seven_day_routines", now: now, seconds: 604_800)
            }
        ].compactMap { $0 }
        values += (limits ?? []).enumerated().compactMap { index, limit in
            limit.metric(key: "anthropic.oauth.rate_limit.\(limit.slug ?? "scoped-\(index)")", now: now)
        }
        return values
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private struct LimitEntry: Decodable, Sendable {
    let percent: Double?
    let resetsAt: Date?
    let slug: String?
    let isActive: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        percent = try container.decodeFlexibleDoubleIfPresent(forKey: .percent)
        if let rawDate = try container.decodeIfPresent(String.self, forKey: .resetsAt) {
            resetsAt = QuotaWindow.parseDate(rawDate)
        } else {
            resetsAt = nil
        }
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive)
        let scope = try container.decodeIfPresent(LimitScope.self, forKey: .scope)
        let group = try container.decodeIfPresent(String.self, forKey: .group)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind)
        slug = scope?.model?.displayName ?? group ?? kind
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case group
        case percent
        case resetsAt = "resets_at"
        case scope
        case isActive = "is_active"
    }

    func metric(key: String, now: Date) -> UsageMetric? {
        guard let percent, isActive != false else { return nil }
        guard let ratio = DecimalString(rawValue: String(percent / 100)) else {
            return nil
        }
        return UsageMetric(
            key: key,
            category: .providerDefined("rate_limit"),
            unit: .ratio,
            value: .known(ratio),
            limit: .known(DecimalString(rawValue: "1")!),
            scope: .unknown,
            period: .interval(
                start: now.addingTimeInterval(-604_800),
                end: now,
                window: .rolling
            ),
            reset: resetsAt.map { .at($0, precision: .second) } ?? .notReported
        )
    }
}

private struct LimitScope: Decodable {
    let model: LimitModel?
}

private struct LimitModel: Decodable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

private struct QuotaWindow: Decodable, Sendable {
    let utilization: DecimalString?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try container.decodeFlexibleDecimalIfPresent(forKey: .utilization)
        if let rawDate = try container.decodeIfPresent(String.self, forKey: .resetsAt) {
            resetsAt = Self.parseDate(rawDate)
        } else {
            resetsAt = nil
        }
    }

    func metric(
        key: String,
        now: Date,
        seconds: TimeInterval
    ) -> UsageMetric? {
        guard let utilization else { return nil }
        return UsageMetric(
            key: key,
            category: .providerDefined("rate_limit"),
            unit: .ratio,
            value: .known(utilization),
            limit: .known(DecimalString(rawValue: "1")!),
            scope: .unknown,
            period: .interval(
                start: now.addingTimeInterval(-seconds),
                end: now,
                window: .rolling
            ),
            reset: resetsAt.map { .at($0, precision: .second) } ?? .notReported
        )
    }

    fileprivate static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }
}

private struct ErrorEnvelope: Decodable {
    let error: ProviderError
}

private struct ProviderError: Decodable {
    let type: String?
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDecimalIfPresent(
        forKey key: Key
    ) throws -> DecimalString? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let decimal = try? decode(Decimal.self, forKey: key) {
            return DecimalString(rawValue: NSDecimalNumber(decimal: decimal).stringValue)
        }
        if let string = try? decode(String.self, forKey: key) {
            return DecimalString(rawValue: string)
        }
        throw DecodingError.typeMismatch(
            DecimalString.self,
            .init(codingPath: codingPath, debugDescription: "Expected a decimal value.")
        )
    }

    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let number = try? decode(Double.self, forKey: key) {
            return number
        }
        if let string = try? decode(String.self, forKey: key) {
            return Double(string)
        }
        throw DecodingError.typeMismatch(
            Double.self,
            .init(codingPath: codingPath, debugDescription: "Expected a floating-point value.")
        )
    }
}

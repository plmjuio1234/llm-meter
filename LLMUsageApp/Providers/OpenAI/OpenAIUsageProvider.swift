import Foundation
import UsageCore

/// Reads the current ChatGPT/Codex subscription quota using the OAuth token
/// returned by the ChatGPT sign-in flow.
public struct OpenAIUsageProvider: UsageProvider, Sendable {
    public let provider: Provider = .openAI

    private let baseURL: URL
    private let now: @Sendable () -> Date

    public init(
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
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
        guard connection.provider == .openAI,
              connection.surface == .consumerSubscription else {
            return .failure(.unsupported)
        }
        guard !credential.accessToken.isEmpty else {
            return .failure(.authRequired)
        }

        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("wham/usage"))
            request.httpMethod = "GET"
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("LLMUsageWidget", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let accountID = credential.accountID {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }

            let (data, response) = try await client.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                return .failure(Self.failure(for: response, data: data))
            }
            let payload = try JSONDecoder().decode(OpenAIQuotaResponse.self, from: data)
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
        } catch let failure as ProviderFailure {
            return .failure(failure)
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
            let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.code
            return .providerError(code: code)
        }
    }

    private static func retryDate(from value: String?) -> Date? {
        guard let value, let seconds = TimeInterval(value) else { return nil }
        return Date().addingTimeInterval(seconds)
    }
}

private struct OpenAIQuotaResponse: Decodable, Sendable {
    let rateLimit: RateLimit?
    let additionalRateLimits: [NamedRateLimit]?
    let codeReviewRateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case codeReviewRateLimit = "code_review_rate_limit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimit = try? container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        codeReviewRateLimit = try? container.decodeIfPresent(
            RateLimit.self,
            forKey: .codeReviewRateLimit
        )
        additionalRateLimits = (try? container.decodeIfPresent(
            [LossyNamedRateLimit].self,
            forKey: .additionalRateLimits
        ))?.compactMap(\.value)
    }

    func metrics(now: Date) -> [UsageMetric] {
        var metrics: [UsageMetric] = []
        if let rateLimit {
            metrics += rateLimit.metrics(prefix: "openai.oauth.rate_limit", now: now)
        }
        for additional in additionalRateLimits ?? [] {
            metrics += additional.rateLimit.metrics(
                prefix: "openai.oauth.rate_limit.\(slug(additional.id))",
                now: now
            )
        }
        if let codeReviewRateLimit {
            metrics += codeReviewRateLimit.metrics(
                prefix: "openai.oauth.code_review",
                now: now
            )
        }
        return metrics
    }

    private func slug(_ value: String) -> String {
        let result = value.lowercased().map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(result)
    }
}

private struct RateLimit: Decodable, Sendable {
    let primaryWindow: QuotaWindow?
    let secondaryWindow: QuotaWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    static let empty = RateLimit(primaryWindow: nil, secondaryWindow: nil)

    private init(primaryWindow: QuotaWindow?, secondaryWindow: QuotaWindow?) {
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryWindow = try? container.decodeIfPresent(
            QuotaWindow.self,
            forKey: .primaryWindow
        )
        secondaryWindow = try? container.decodeIfPresent(
            QuotaWindow.self,
            forKey: .secondaryWindow
        )
    }

    func metrics(prefix: String, now: Date) -> [UsageMetric] {
        [
            primaryWindow.flatMap { $0.metric(key: "\(prefix).primary", now: now) },
            secondaryWindow.flatMap { $0.metric(key: "\(prefix).secondary", now: now) }
        ].compactMap { $0 }
    }
}

private struct NamedRateLimit: Decodable, Sendable {
    let id: String
    let rateLimit: RateLimit

    enum CodingKeys: String, CodingKey {
        case id
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id))
            ?? (try? container.decodeIfPresent(String.self, forKey: .limitName))
            ?? (try? container.decodeIfPresent(String.self, forKey: .meteredFeature))
            ?? "additional"
        rateLimit = (try? container.decodeIfPresent(RateLimit.self, forKey: .rateLimit))
            ?? (try? RateLimit(from: decoder))
            ?? .empty
    }
}

private struct LossyNamedRateLimit: Decodable {
    let value: NamedRateLimit?

    init(from decoder: Decoder) throws {
        value = try? NamedRateLimit(from: decoder)
    }
}

private struct QuotaWindow: Decodable, Sendable {
    let usedPercent: DecimalString?
    let limitWindowSeconds: Int?
    let resetAt: Date?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.decodeFlexibleDecimalIfPresent(forKey: .usedPercent)
        limitWindowSeconds = try container.decodeFlexibleIntIfPresent(forKey: .limitWindowSeconds)
        resetAt = try container.decodeFlexibleDateIfPresent(forKey: .resetAt)
    }

    func metric(key: String, now: Date) -> UsageMetric? {
        guard let usedPercent else { return nil }
        let period: MeasurementPeriod
        if let limitWindowSeconds, limitWindowSeconds > 0 {
            period = .interval(
                start: now.addingTimeInterval(-TimeInterval(limitWindowSeconds)),
                end: now,
                window: .rolling
            )
        } else {
            period = .unknown
        }
        let reset: Reset = resetAt.map { .at($0, precision: .second) } ?? .notReported
        return UsageMetric(
            key: key,
            category: .providerDefined("rate_limit"),
            unit: .count("percent"),
            value: .known(usedPercent),
            limit: .known(DecimalString(rawValue: "100")!),
            scope: .unknown,
            period: period,
            reset: reset
        )
    }
}

private struct ErrorEnvelope: Decodable {
    let error: ProviderError
}

private struct ProviderError: Decodable {
    let code: String?
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDecimalIfPresent(
        forKey key: Key
    ) throws -> DecimalString? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let string = try? decode(String.self, forKey: key) {
            return DecimalString(rawValue: string)
        }
        if let decimal = try? decode(Decimal.self, forKey: key) {
            return DecimalString(rawValue: NSDecimalNumber(decimal: decimal).stringValue)
        }
        if let integer = try? decode(Int.self, forKey: key) {
            return DecimalString(rawValue: String(integer))
        }
        throw DecodingError.typeMismatch(
            DecimalString.self,
            .init(codingPath: codingPath, debugDescription: "Expected a decimal value.")
        )
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let integer = try? decode(Int.self, forKey: key) {
            return integer
        }
        if let string = try? decode(String.self, forKey: key) {
            return Int(string)
        }
        throw DecodingError.typeMismatch(
            Int.self,
            .init(codingPath: codingPath, debugDescription: "Expected an integer value.")
        )
    }

    func decodeFlexibleDateIfPresent(forKey key: Key) throws -> Date? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let timestamp = try? decode(TimeInterval.self, forKey: key) {
            return Date(timeIntervalSince1970: timestamp)
        }
        if let string = try? decode(String.self, forKey: key) {
            if let timestamp = TimeInterval(string) {
                return Date(timeIntervalSince1970: timestamp)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string) ?? {
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: string)
            }()
        }
        throw DecodingError.typeMismatch(
            Date.self,
            .init(codingPath: codingPath, debugDescription: "Expected a timestamp value.")
        )
    }
}

import Foundation
import UsageCore

/// Reads the documented Kimi OpenPlatform balance endpoint with an API key.
public struct MoonshotUsageProvider: UsageProvider, Sendable {
    public let provider: Provider

    private let baseURL: URL
    private let now: @Sendable () -> Date

    public init(
        provider: Provider = .moonshot,
        baseURL: URL = URL(string: "https://api.moonshot.ai")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.now = now
    }

    public func fetch(
        connection: AccountConnection,
        credential: OAuthCredential,
        period: DateInterval,
        client: any ProviderHTTPClient
    ) async -> Result<UsageSnapshot, ProviderFailure> {
        guard connection.provider == provider,
              provider == .moonshot || provider == .moonshotChina,
              connection.surface == .api else {
            return .failure(.unsupported)
        }
        guard credential.kind == .apiKey, !credential.accessToken.isEmpty else {
            return .failure(.authRequired)
        }

        do {
            let (data, response) = try await AdditionalProviderSupport.request(
                url: baseURL.appendingPathComponent("v1/users/me/balance"),
                credential: credential,
                client: client
            )
            guard (200..<300).contains(response.statusCode) else {
                return .failure(AdditionalProviderSupport.failure(for: response, data: data))
            }

            let payload = try JSONDecoder().decode(MoonshotBalanceResponse.self, from: data)
            guard payload.status, payload.code == 0 else {
                return .failure(.providerError(code: payload.scode))
            }
            let metrics = payload.data.metrics()
            return .success(
                AdditionalProviderSupport.snapshot(
                    connection: connection,
                    provider: provider,
                    metrics: metrics,
                    now: now()
                )
            )
        } catch is DecodingError {
            return .failure(.invalidResponse)
        } catch {
            return .failure(.offline)
        }
    }
}

/// Reads the documented DeepSeek user balance endpoint with an API key.
public struct DeepSeekUsageProvider: UsageProvider, Sendable {
    public let provider: Provider = .deepSeek

    private let baseURL: URL
    private let now: @Sendable () -> Date

    public init(
        baseURL: URL = URL(string: "https://api.deepseek.com")!,
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
        guard connection.provider == .deepSeek,
              connection.surface == .api else {
            return .failure(.unsupported)
        }
        guard credential.kind == .apiKey, !credential.accessToken.isEmpty else {
            return .failure(.authRequired)
        }

        do {
            let (data, response) = try await AdditionalProviderSupport.request(
                url: baseURL.appendingPathComponent("user/balance"),
                credential: credential,
                client: client
            )
            guard (200..<300).contains(response.statusCode) else {
                return .failure(AdditionalProviderSupport.failure(for: response, data: data))
            }

            let payload = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
            let metrics = payload.balanceInfos.flatMap { $0.metrics() }
            guard !metrics.isEmpty else {
                return .success(
                    AdditionalProviderSupport.snapshot(
                        connection: connection,
                        provider: provider,
                        metrics: [],
                        now: now(),
                        failure: .noData
                    )
                )
            }
            return .success(
                AdditionalProviderSupport.snapshot(
                    connection: connection,
                    provider: provider,
                    metrics: metrics,
                    now: now(),
                    failure: payload.isAvailable ? nil : .providerError(code: "account_unavailable")
                )
            )
        } catch is DecodingError {
            return .failure(.invalidResponse)
        } catch {
            return .failure(.offline)
        }
    }
}

/// Reads the documented OpenRouter API-key usage and per-key limit endpoint.
public struct OpenRouterUsageProvider: UsageProvider, Sendable {
    public let provider: Provider = .openRouter

    private let baseURL: URL
    private let now: @Sendable () -> Date

    public init(
        baseURL: URL = URL(string: "https://openrouter.ai")!,
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
        guard connection.provider == .openRouter,
              connection.surface == .api else {
            return .failure(.unsupported)
        }
        guard credential.kind == .apiKey, !credential.accessToken.isEmpty else {
            return .failure(.authRequired)
        }

        do {
            let (data, response) = try await AdditionalProviderSupport.request(
                url: baseURL.appendingPathComponent("api/v1/key"),
                credential: credential,
                client: client
            )
            guard (200..<300).contains(response.statusCode) else {
                return .failure(AdditionalProviderSupport.failure(for: response, data: data))
            }

            let payload = try JSONDecoder().decode(OpenRouterKeyResponse.self, from: data)
            let metrics = payload.data.metrics()
            return .success(
                AdditionalProviderSupport.snapshot(
                    connection: connection,
                    provider: provider,
                    metrics: metrics,
                    now: now()
                )
            )
        } catch is DecodingError {
            return .failure(.invalidResponse)
        } catch {
            return .failure(.offline)
        }
    }
}

/// A visible connection for providers that do not publish account-wide usage.
/// It never calls an undocumented endpoint and intentionally reports unsupported.
public struct UnsupportedUsageProvider: UsageProvider, Sendable {
    public let provider: Provider

    public init(provider: Provider) {
        self.provider = provider
    }

    public func fetch(
        connection: AccountConnection,
        credential: OAuthCredential,
        period: DateInterval,
        client: any ProviderHTTPClient
    ) async -> Result<UsageSnapshot, ProviderFailure> {
        .failure(.unsupported)
    }
}

private enum AdditionalProviderSupport {
    static func request(
        url: URL,
        credential: OAuthCredential,
        client: any ProviderHTTPClient
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(credential.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LLMUsageWidget/1.0", forHTTPHeaderField: "User-Agent")
        return try await client.data(for: request)
    }

    static func failure(
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
                retryAt: response.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init)
                    .map { Date().addingTimeInterval($0) }
            )
        default:
            let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.code
            return .providerError(code: code)
        }
    }

    static func snapshot(
        connection: AccountConnection,
        provider: Provider,
        metrics: [UsageMetric],
        now: Date,
        failure: UsageFailure? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: connection.id,
            provider: provider,
            surface: connection.surface,
            identity: connection.identity,
            freshness: Freshness(
                fetchedAt: now,
                asOf: now,
                state: metrics.isEmpty ? .noData : .fresh
            ),
            metrics: metrics,
            failure: failure ?? (metrics.isEmpty ? .noData : nil)
        )
    }
}

private struct MoonshotBalanceResponse: Decodable {
    let code: Int
    let data: MoonshotBalance
    let scode: String?
    let status: Bool
}

private struct MoonshotBalance: Decodable {
    let availableBalance: DecimalString?
    let voucherBalance: DecimalString?
    let cashBalance: DecimalString?

    enum CodingKeys: String, CodingKey {
        case availableBalance = "available_balance"
        case voucherBalance = "voucher_balance"
        case cashBalance = "cash_balance"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableBalance = try container.decodeFlexibleDecimalIfPresent(forKey: .availableBalance)
        voucherBalance = try container.decodeFlexibleDecimalIfPresent(forKey: .voucherBalance)
        cashBalance = try container.decodeFlexibleDecimalIfPresent(forKey: .cashBalance)
    }

    func metrics() -> [UsageMetric] {
        [
            availableBalance.map {
                Self.metric(key: "moonshot.api.balance.available", value: $0)
            },
            voucherBalance.map {
                Self.metric(key: "moonshot.api.balance.voucher", value: $0)
            },
            cashBalance.map {
                Self.metric(key: "moonshot.api.balance.cash", value: $0)
            }
        ].compactMap { $0 }
    }

    private static func metric(key: String, value: DecimalString) -> UsageMetric {
        UsageMetric(
            key: key,
            category: .cost,
            unit: .currency("USD"),
            value: .known(value),
            scope: .unknown,
            period: .unknown
        )
    }
}

private struct DeepSeekBalanceResponse: Decodable {
    let isAvailable: Bool
    let balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? false
        balanceInfos = try container.decodeIfPresent(
            [DeepSeekBalanceInfo].self,
            forKey: .balanceInfos
        ) ?? []
    }
}

private struct DeepSeekBalanceInfo: Decodable {
    let currency: String
    let totalBalance: DecimalString?
    let grantedBalance: DecimalString?
    let toppedUpBalance: DecimalString?

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currency = try container.decode(String.self, forKey: .currency)
        totalBalance = try container.decodeFlexibleDecimalIfPresent(forKey: .totalBalance)
        grantedBalance = try container.decodeFlexibleDecimalIfPresent(forKey: .grantedBalance)
        toppedUpBalance = try container.decodeFlexibleDecimalIfPresent(forKey: .toppedUpBalance)
    }

    func metrics() -> [UsageMetric] {
        let currencyCode = currency.uppercased()
        return [
            totalBalance.map {
                Self.metric(
                    key: "deepseek.api.balance.\(currencyCode.lowercased()).total",
                    value: $0,
                    currency: currencyCode
                )
            },
            grantedBalance.map {
                Self.metric(
                    key: "deepseek.api.balance.\(currencyCode.lowercased()).granted",
                    value: $0,
                    currency: currencyCode
                )
            },
            toppedUpBalance.map {
                Self.metric(
                    key: "deepseek.api.balance.\(currencyCode.lowercased()).topped_up",
                    value: $0,
                    currency: currencyCode
                )
            }
        ].compactMap { $0 }
    }

    private static func metric(
        key: String,
        value: DecimalString,
        currency: String
    ) -> UsageMetric {
        UsageMetric(
            key: key,
            category: .cost,
            unit: .currency(currency),
            value: .known(value),
            scope: .unknown,
            period: .unknown
        )
    }
}

private struct OpenRouterKeyResponse: Decodable {
    let data: OpenRouterKey
}

private struct OpenRouterKey: Decodable {
    let label: String?
    let limit: DecimalString?
    let limitRemaining: DecimalString?
    let limitReset: String?
    let usage: DecimalString
    let usageDaily: DecimalString?
    let usageWeekly: DecimalString?
    let usageMonthly: DecimalString?

    enum CodingKeys: String, CodingKey {
        case label
        case limit
        case limitRemaining = "limit_remaining"
        case limitReset = "limit_reset"
        case usage
        case usageDaily = "usage_daily"
        case usageWeekly = "usage_weekly"
        case usageMonthly = "usage_monthly"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        limit = try container.decodeFlexibleDecimalIfPresent(forKey: .limit)
        limitRemaining = try container.decodeFlexibleDecimalIfPresent(forKey: .limitRemaining)
        limitReset = try container.decodeIfPresent(String.self, forKey: .limitReset)
        usage = try container.decodeFlexibleDecimalIfPresent(forKey: .usage) ?? DecimalString(rawValue: "0")!
        usageDaily = try container.decodeFlexibleDecimalIfPresent(forKey: .usageDaily)
        usageWeekly = try container.decodeFlexibleDecimalIfPresent(forKey: .usageWeekly)
        usageMonthly = try container.decodeFlexibleDecimalIfPresent(forKey: .usageMonthly)
    }

    func metrics() -> [UsageMetric] {
        [
            Self.metric(
                key: "openrouter.api.key.usage",
                value: usage,
                limit: limit,
                reset: .notReported
            ),
            limitRemaining.map {
                Self.metric(
                    key: "openrouter.api.key.remaining",
                    value: $0,
                    limit: limit,
                    reset: .notReported
                )
            },
            usageDaily.map {
                Self.metric(
                    key: "openrouter.api.key.usage.daily",
                    value: $0,
                    limit: nil,
                    reset: .notReported
                )
            },
            usageWeekly.map {
                Self.metric(
                    key: "openrouter.api.key.usage.weekly",
                    value: $0,
                    limit: nil,
                    reset: .notReported
                )
            },
            usageMonthly.map {
                Self.metric(
                    key: "openrouter.api.key.usage.monthly",
                    value: $0,
                    limit: nil,
                    reset: .notReported
                )
            }
        ].compactMap { $0 }
    }

    private static func metric(
        key: String,
        value: DecimalString,
        limit: DecimalString?,
        reset: Reset
    ) -> UsageMetric {
        UsageMetric(
            key: key,
            category: .cost,
            unit: .currency("USD"),
            value: .known(value),
            limit: limit.map(ReportedValue.known),
            scope: .unknown,
            period: .unknown,
            reset: reset
        )
    }
}

private struct ErrorEnvelope: Decodable {
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
        if let double = try? decode(Double.self, forKey: key) {
            return DecimalString(rawValue: String(double))
        }
        throw DecodingError.typeMismatch(
            DecimalString.self,
            .init(codingPath: codingPath, debugDescription: "Expected a decimal value.")
        )
    }
}

private extension DecimalString {
    init?(rawValue: String?) {
        guard let rawValue else { return nil }
        self.init(rawValue: rawValue)
    }
}

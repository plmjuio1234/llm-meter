import Foundation

public enum UsageCoreModule {
    public static let version = 1
}

/// A connection-local identity. It deliberately does not derive from a label,
/// provider principal, or credential, so two connections never collide by accident.
public struct AccountID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var description: String { rawValue.uuidString }
}

public enum Provider: Codable, Hashable, Sendable {
    case openAI
    case anthropic
    case moonshot
    case moonshotChina
    case deepSeek
    case openRouter
    case zhipu
    case miniMax
    case qwen
    case other(String)
}

public enum Surface: Codable, Hashable, Sendable {
    case api
    case consumerSubscription
    case other(String)
}

/// The provider-owned boundary to which a meter applies. Unknown scope is not
/// compatible with any aggregate, including another unknown scope.
public enum UsageScope: Codable, Hashable, Sendable {
    case organization(String)
    case workspace(String)
    case project(String)
    case account(String)
    case providerDefined(kind: String, identifier: String)
    case unknown
}

public struct AccountIdentity: Codable, Hashable, Sendable {
    public let provider: Provider
    public let remotePrincipalID: String
    public let scope: UsageScope

    public init(provider: Provider, remotePrincipalID: String, scope: UsageScope) {
        self.provider = provider
        self.remotePrincipalID = remotePrincipalID
        self.scope = scope
    }
}

/// A validated base-ten decimal that retains the provider's original spelling,
/// including trailing zeroes and therefore its reported precision.
public struct DecimalString: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.parts(of: rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public var decimalValue: Decimal? { Decimal(string: rawValue, locale: Locale(identifier: "en_US_POSIX")) }

    public static func adding(_ values: [DecimalString]) -> DecimalString? {
        guard !values.isEmpty else { return nil }
        let parts = values.compactMap { Self.parts(of: $0.rawValue) }
        guard parts.count == values.count else { return nil }
        let scale = parts.map { $0.fraction.count }.max() ?? 0
        var total = SignedDigits.zero
        for part in parts {
            let digits = part.whole + part.fraction + String(repeating: "0", count: scale - part.fraction.count)
            total = total.adding(SignedDigits(negative: part.negative, digits: digits))
        }
        let rendered = total.rendered(scale: scale)
        return DecimalString(rawValue: rendered)
    }

    private static func parts(of value: String) -> (negative: Bool, whole: String, fraction: String)? {
        guard !value.isEmpty else { return nil }
        var text = value[...]
        var negative = false
        if text.first == "-" || text.first == "+" {
            negative = text.first == "-"
            text.removeFirst()
        }
        guard !text.isEmpty else { return nil }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2,
              let whole = pieces.first, !whole.isEmpty,
              whole.allSatisfy(\.isNumber) else { return nil }
        let fraction = pieces.count == 2 ? String(pieces[1]) : ""
        guard pieces.count == 1 || (!fraction.isEmpty && fraction.allSatisfy(\.isNumber)) else { return nil }
        return (negative, String(whole), fraction)
    }

    private struct SignedDigits {
        var negative: Bool
        var digits: String

        static let zero = SignedDigits(negative: false, digits: "0")

        init(negative: Bool, digits: String) {
            let trimmed = digits.drop(while: { $0 == "0" })
            self.digits = trimmed.isEmpty ? "0" : String(trimmed)
            self.negative = self.digits == "0" ? false : negative
        }

        func adding(_ other: SignedDigits) -> SignedDigits {
            if negative == other.negative {
                return SignedDigits(negative: negative, digits: Self.addMagnitude(digits, other.digits))
            }
            switch Self.compareMagnitude(digits, other.digits) {
            case .orderedSame: return .zero
            case .orderedDescending:
                return SignedDigits(negative: negative, digits: Self.subtractMagnitude(digits, other.digits))
            case .orderedAscending:
                return SignedDigits(negative: other.negative, digits: Self.subtractMagnitude(other.digits, digits))
            }
        }

        func rendered(scale: Int) -> String {
            var value = digits
            if scale > 0 {
                if value.count <= scale {
                    value = String(repeating: "0", count: scale - value.count + 1) + value
                }
                value.insert(".", at: value.index(value.endIndex, offsetBy: -scale))
            }
            return negative ? "-" + value : value
        }

        private static func compareMagnitude(_ lhs: String, _ rhs: String) -> ComparisonResult {
            if lhs.count != rhs.count { return lhs.count < rhs.count ? .orderedAscending : .orderedDescending }
            if lhs == rhs { return .orderedSame }
            return lhs.lexicographicallyPrecedes(rhs) ? .orderedAscending : .orderedDescending
        }

        private static func addMagnitude(_ lhs: String, _ rhs: String) -> String {
            let left = lhs.reversed().map { Int(String($0))! }
            let right = rhs.reversed().map { Int(String($0))! }
            var output: [Int] = []
            var carry = 0
            for index in 0..<max(left.count, right.count) {
                let sum = (index < left.count ? left[index] : 0) + (index < right.count ? right[index] : 0) + carry
                output.append(sum % 10)
                carry = sum / 10
            }
            if carry > 0 { output.append(carry) }
            return output.reversed().map(String.init).joined()
        }

        /// Precondition: lhs >= rhs.
        private static func subtractMagnitude(_ lhs: String, _ rhs: String) -> String {
            let left = lhs.reversed().map { Int(String($0))! }
            let right = rhs.reversed().map { Int(String($0))! }
            var output: [Int] = []
            var borrow = 0
            for index in left.indices {
                var digit = left[index] - borrow - (index < right.count ? right[index] : 0)
                if digit < 0 { digit += 10; borrow = 1 } else { borrow = 0 }
                output.append(digit)
            }
            while output.count > 1 && output.last == 0 { output.removeLast() }
            return output.reversed().map(String.init).joined()
        }
    }
}

public enum UnknownValueReason: String, Codable, Hashable, Sendable {
    case notReported
    case unsupported
    case invalidResponse
    case partialCoverage
}

public enum ReportedValue: Codable, Hashable, Sendable {
    case known(DecimalString)
    case unknown(UnknownValueReason)

    public var decimalString: DecimalString? {
        guard case let .known(value) = self else { return nil }
        return value
    }
}

public enum MetricCategory: Codable, Hashable, Sendable {
    case tokens
    case requests
    case cost
    case messages
    case providerDefined(String)
}

public enum MetricUnit: Codable, Hashable, Sendable {
    case count(String)
    case currency(String)
    case ratio

    fileprivate var normalized: MetricUnit {
        switch self {
        case let .currency(code): return .currency(code.uppercased())
        default: return self
        }
    }
}

public enum WindowKind: Codable, Hashable, Sendable {
    case fixed
    case rolling
    case calendar
    case providerDefined(String)
}

/// A half-open measurement interval `[start, end)`.
public enum MeasurementPeriod: Codable, Hashable, Sendable {
    case interval(start: Date, end: Date, window: WindowKind)
    case unknown

    public func doesNotOverlap(_ other: MeasurementPeriod) -> Bool {
        guard case let .interval(lhsStart, lhsEnd, _) = self,
              case let .interval(rhsStart, rhsEnd, _) = other else { return false }
        return lhsEnd <= rhsStart || rhsEnd <= lhsStart
    }

    fileprivate var window: WindowKind? {
        guard case let .interval(_, _, window) = self else { return nil }
        return window
    }

    fileprivate var isValid: Bool {
        guard case let .interval(start, end, _) = self else { return false }
        return start < end
    }
}

public enum ResetPrecision: String, Codable, Hashable, Sendable {
    case second, minute, hour, day
}

public enum Reset: Codable, Hashable, Sendable {
    case at(Date, precision: ResetPrecision)
    case notReported
    case unknown
}

public enum SourceQuality: String, Codable, Hashable, Sendable {
    case providerReported
    case estimated
}

public enum FreshnessState: String, Codable, Hashable, Sendable {
    case fresh
    case stale
    case noData
}

public struct Freshness: Codable, Hashable, Sendable {
    public let fetchedAt: Date
    public let asOf: Date?
    public let freshUntil: Date?
    public let state: FreshnessState

    public init(fetchedAt: Date, asOf: Date? = nil, freshUntil: Date? = nil, state: FreshnessState) {
        self.fetchedAt = fetchedAt
        self.asOf = asOf
        self.freshUntil = freshUntil
        self.state = state
    }
}

public enum UsageFailure: Codable, Hashable, Sendable {
    case authRequired
    case permissionDenied
    case rateLimited(retryAt: Date?)
    case offline
    case providerError(code: String?)
    case invalidResponse
    case unsupported
    case partial
    case noData
}

public struct UsageMetric: Codable, Hashable, Sendable {
    public let key: String
    public let category: MetricCategory
    public let unit: MetricUnit
    public let value: ReportedValue
    public let limit: ReportedValue?
    public let scope: UsageScope
    public let period: MeasurementPeriod
    public let reset: Reset
    public let sourceQuality: SourceQuality

    public init(
        key: String,
        category: MetricCategory,
        unit: MetricUnit,
        value: ReportedValue,
        limit: ReportedValue? = nil,
        scope: UsageScope,
        period: MeasurementPeriod,
        reset: Reset = .notReported,
        sourceQuality: SourceQuality = .providerReported
    ) {
        self.key = key
        self.category = category
        self.unit = unit
        self.value = value
        self.limit = limit
        self.scope = scope
        self.period = period
        self.reset = reset
        self.sourceQuality = sourceQuality
    }

    /// Ratio meters use the provider value directly. Amount meters divide by a
    /// provider-reported limit. The result is intentionally not clamped to 1.
    public var utilization: Decimal? {
        guard let value = value.decimalString?.decimalValue else { return nil }
        if unit == .ratio { return value }
        guard let limit = limit?.decimalString?.decimalValue, limit != 0 else { return nil }
        return value / limit
    }
}

public struct UsageSnapshot: Codable, Hashable, Sendable {
    public let accountID: AccountID
    public let provider: Provider
    public let surface: Surface
    public let identity: AccountIdentity?
    public let freshness: Freshness
    public let metrics: [UsageMetric]
    public let failure: UsageFailure?

    public init(
        accountID: AccountID,
        provider: Provider,
        surface: Surface,
        identity: AccountIdentity? = nil,
        freshness: Freshness,
        metrics: [UsageMetric],
        failure: UsageFailure? = nil
    ) {
        self.accountID = accountID
        self.provider = provider
        self.surface = surface
        self.identity = identity
        self.freshness = freshness
        self.metrics = metrics
        self.failure = failure
    }
}

public struct AggregateInput: Hashable, Sendable {
    public let accountID: AccountID
    public let provider: Provider
    public let metric: UsageMetric

    public init(accountID: AccountID, provider: Provider, metric: UsageMetric) {
        self.accountID = accountID
        self.provider = provider
        self.metric = metric
    }
}

public enum AggregationIncompatibility: Error, Equatable, Sendable {
    case empty
    case duplicateAccount(AccountID)
    case provider
    case metric
    case unit
    case currency
    case scope
    case window
    case overlappingPeriods
    case unknownPeriod
}

public struct AggregateCoverage: Codable, Equatable, Sendable {
    public let known: Int
    public let total: Int

    public init(known: Int, total: Int) {
        self.known = known
        self.total = total
    }
}

public struct UsageAggregate: Codable, Equatable, Sendable {
    /// Unknown for ratio-only meters and whenever any input amount is unknown.
    public let total: ReportedValue
    public let highestUtilization: DecimalString?
    public let coverage: AggregateCoverage
    public let isRatioOnly: Bool

    public init(total: ReportedValue, highestUtilization: DecimalString?, coverage: AggregateCoverage, isRatioOnly: Bool) {
        self.total = total
        self.highestUtilization = highestUtilization
        self.coverage = coverage
        self.isRatioOnly = isRatioOnly
    }
}

public enum UsageAggregator {
    public static func aggregate(_ inputs: [AggregateInput]) -> Result<UsageAggregate, AggregationIncompatibility> {
        guard let first = inputs.first else { return .failure(.empty) }

        var accountIDs = Set<AccountID>()
        for input in inputs {
            guard accountIDs.insert(input.accountID).inserted else { return .failure(.duplicateAccount(input.accountID)) }
            guard input.provider == first.provider else { return .failure(.provider) }
            guard input.metric.key == first.metric.key && input.metric.category == first.metric.category else { return .failure(.metric) }
            if case let .currency(lhs) = first.metric.unit, case let .currency(rhs) = input.metric.unit,
               lhs.caseInsensitiveCompare(rhs) != .orderedSame { return .failure(.currency) }
            guard input.metric.unit.normalized == first.metric.unit.normalized else { return .failure(.unit) }
            guard input.metric.scope != .unknown, input.metric.scope == first.metric.scope else { return .failure(.scope) }
            guard input.metric.period.isValid else { return .failure(.unknownPeriod) }
            guard input.metric.period.window == first.metric.period.window else { return .failure(.window) }
        }

        for left in inputs.indices {
            for right in inputs.indices where right > left {
                guard inputs[left].metric.period.doesNotOverlap(inputs[right].metric.period) else {
                    return .failure(.overlappingPeriods)
                }
            }
        }

        let knownValues = inputs.compactMap { $0.metric.value.decimalString }
        let utilizations = inputs.compactMap(\.metric.utilization)
        let highest = utilizations.max().flatMap { DecimalString(rawValue: NSDecimalNumber(decimal: $0).stringValue) }
        let ratioOnly = first.metric.unit == .ratio
        let total: ReportedValue
        if ratioOnly {
            total = .unknown(.unsupported)
        } else if knownValues.count != inputs.count {
            total = .unknown(.partialCoverage)
        } else if let sum = DecimalString.adding(knownValues) {
            total = .known(sum)
        } else {
            total = .unknown(.invalidResponse)
        }

        return .success(UsageAggregate(
            total: total,
            highestUtilization: highest,
            coverage: AggregateCoverage(known: knownValues.count, total: inputs.count),
            isRatioOnly: ratioOnly
        ))
    }
}

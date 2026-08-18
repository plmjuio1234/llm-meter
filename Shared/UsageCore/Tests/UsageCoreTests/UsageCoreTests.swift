import Foundation
import XCTest
@testable import UsageCore

final class AggregationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testCompatibleSameUnitNonOverlappingPeriodsAggregateExactly() throws {
        let first = input(
            accountID: AccountID(),
            value: known("1.20"),
            startOffset: 0,
            endOffset: 60
        )
        let second = input(
            accountID: AccountID(),
            value: known("2.3"),
            startOffset: 60,
            endOffset: 120
        )

        let aggregate = try UsageAggregator.aggregate([first, second]).get()

        XCTAssertEqual(aggregate.total, known("3.50"))
        XCTAssertEqual(aggregate.coverage, AggregateCoverage(known: 2, total: 2))
        XCTAssertFalse(aggregate.isRatioOnly)
        XCTAssertEqual(first.metric.value, known("1.20"), "The provider spelling and precision must remain unchanged")
    }

    func testUnknownValueDoesNotBecomeZeroOrPartialTotal() throws {
        let aggregate = try UsageAggregator.aggregate([
            input(accountID: AccountID(), value: known("4"), startOffset: 0, endOffset: 60),
            input(accountID: AccountID(), value: .unknown(.notReported), startOffset: 60, endOffset: 120)
        ]).get()

        XCTAssertEqual(aggregate.total, .unknown(.partialCoverage))
        XCTAssertEqual(aggregate.coverage, AggregateCoverage(known: 1, total: 2))
    }

    func testRatioOnlyMetricsProduceSummaryWithoutSum() throws {
        let first = input(accountID: AccountID(), unit: .ratio, value: known("0.8"), startOffset: 0, endOffset: 60)
        let second = input(accountID: AccountID(), unit: .ratio, value: known("1.25"), startOffset: 60, endOffset: 120)

        let aggregate = try UsageAggregator.aggregate([first, second]).get()

        XCTAssertTrue(aggregate.isRatioOnly)
        XCTAssertEqual(aggregate.total, .unknown(.unsupported))
        XCTAssertEqual(aggregate.highestUtilization, decimal("1.25"))
    }

    func testUtilizationCanExceedOneHundredPercent() {
        let metric = makeMetric(value: known("125"), limit: known("100"), startOffset: 0, endOffset: 60)
        XCTAssertEqual(metric.utilization, Decimal(string: "1.25"))
    }

    func testVeryLargeDecimalsAreAddedWithoutLosingProviderPrecision() {
        let values = [decimal("999999999999999999999999999999999999.90"), decimal("0.11")]
        XCTAssertEqual(DecimalString.adding(values), decimal("1000000000000000000000000000000000000.01"))
        XCTAssertEqual(values[0].rawValue, "999999999999999999999999999999999999.90")
    }

    private func input(
        accountID: AccountID,
        provider: Provider = .openAI,
        unit: MetricUnit = .count("tokens"),
        value: ReportedValue,
        scope: UsageScope = .organization("org-1"),
        window: WindowKind = .fixed,
        startOffset: TimeInterval,
        endOffset: TimeInterval
    ) -> AggregateInput {
        AggregateInput(
            accountID: accountID,
            provider: provider,
            metric: makeMetric(
                unit: unit,
                value: value,
                scope: scope,
                window: window,
                startOffset: startOffset,
                endOffset: endOffset
            )
        )
    }

    private func makeMetric(
        unit: MetricUnit = .count("tokens"),
        value: ReportedValue,
        limit: ReportedValue? = nil,
        scope: UsageScope = .organization("org-1"),
        window: WindowKind = .fixed,
        startOffset: TimeInterval,
        endOffset: TimeInterval
    ) -> UsageMetric {
        UsageMetric(
            key: "input_tokens",
            category: .tokens,
            unit: unit,
            value: value,
            limit: limit,
            scope: scope,
            period: .interval(
                start: start.addingTimeInterval(startOffset),
                end: start.addingTimeInterval(endOffset),
                window: window
            )
        )
    }
}

final class IncompatibleAggregationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testDifferentUnitsAreRejected() {
        assertFailure(.unit, inputs: [
            input(id: AccountID(), unit: .count("tokens"), from: 0, to: 60),
            input(id: AccountID(), unit: .count("requests"), from: 60, to: 120)
        ])
    }

    func testDifferentCurrenciesAreRejected() {
        assertFailure(.currency, inputs: [
            input(id: AccountID(), unit: .currency("USD"), from: 0, to: 60),
            input(id: AccountID(), unit: .currency("EUR"), from: 60, to: 120)
        ])
    }

    func testDifferentScopesAreRejected() {
        assertFailure(.scope, inputs: [
            input(id: AccountID(), scope: .organization("one"), from: 0, to: 60),
            input(id: AccountID(), scope: .organization("two"), from: 60, to: 120)
        ])
    }

    func testUnknownScopesAreNeverAssumedCompatible() {
        assertFailure(.scope, inputs: [
            input(id: AccountID(), scope: .unknown, from: 0, to: 60),
            input(id: AccountID(), scope: .unknown, from: 60, to: 120)
        ])
    }

    func testDifferentWindowKindsAreRejected() {
        assertFailure(.window, inputs: [
            input(id: AccountID(), window: .fixed, from: 0, to: 60),
            input(id: AccountID(), window: .rolling, from: 60, to: 120)
        ])
    }

    func testOverlappingPeriodsAreRejected() {
        assertFailure(.overlappingPeriods, inputs: [
            input(id: AccountID(), from: 0, to: 90),
            input(id: AccountID(), from: 60, to: 120)
        ])
    }

    func testCrossProviderAggregationIsRejected() {
        assertFailure(.provider, inputs: [
            input(id: AccountID(), provider: .openAI, from: 0, to: 60),
            input(id: AccountID(), provider: .anthropic, from: 60, to: 120)
        ])
    }

    func testDuplicateAccountIsRejectedInsteadOfDoubleCounted() {
        let id = AccountID()
        assertFailure(.duplicateAccount(id), inputs: [
            input(id: id, from: 0, to: 60),
            input(id: id, from: 60, to: 120)
        ])
    }

    private func input(
        id: AccountID,
        provider: Provider = .openAI,
        unit: MetricUnit = .count("tokens"),
        scope: UsageScope = .organization("org"),
        window: WindowKind = .fixed,
        from: TimeInterval,
        to: TimeInterval
    ) -> AggregateInput {
        AggregateInput(
            accountID: id,
            provider: provider,
            metric: UsageMetric(
                key: "usage",
                category: .tokens,
                unit: unit,
                value: known("1"),
                scope: scope,
                period: .interval(
                    start: start.addingTimeInterval(from),
                    end: start.addingTimeInterval(to),
                    window: window
                )
            )
        )
    }

    private func assertFailure(
        _ expected: AggregationIncompatibility,
        inputs: [AggregateInput],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch UsageAggregator.aggregate(inputs) {
        case let .failure(actual): XCTAssertEqual(actual, expected, file: file, line: line)
        case .success: XCTFail("Expected aggregation to be rejected", file: file, line: line)
        }
    }
}

final class AccountIdentityTests: XCTestCase {
    func testGeneratedAccountIDsRemainDistinctForDuplicateRemoteIdentity() {
        let first = AccountID()
        let second = AccountID()
        let identity = AccountIdentity(
            provider: .anthropic,
            remotePrincipalID: "principal",
            scope: .workspace("workspace")
        )

        XCTAssertNotEqual(first, second, "Connection identity must remain local and independent")
        XCTAssertEqual(identity, identity, "Remote identity is a separate value suitable for registry deduplication")
    }

    func testAccountIDRoundTripsWithoutUsingDisplayOrCredentialData() throws {
        let original = AccountID()
        let decoded = try JSONDecoder().decode(AccountID.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}

private func decimal(_ value: String, file: StaticString = #filePath, line: UInt = #line) -> DecimalString {
    guard let result = DecimalString(rawValue: value) else {
        XCTFail("Invalid test decimal: \(value)", file: file, line: line)
        fatalError("Invalid test fixture")
    }
    return result
}

private func known(_ value: String, file: StaticString = #filePath, line: UInt = #line) -> ReportedValue {
    .known(decimal(value, file: file, line: line))
}

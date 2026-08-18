import Foundation
import XCTest
import UsageCore
@testable import LLMUsageApp

final class NotificationCoordinatorTests: XCTestCase {
    func testThresholdsNotifyOnlyOnFreshTransitions() async throws {
        let deliverer = RecordingDeliverer()
        let coordinator = NotificationCoordinator(deliverer: deliverer)
        let accountID = AccountID()

        let at80 = snapshot(
            accountID: accountID,
            value: "80",
            state: .fresh
        )
        let firstCount = try await coordinator.process(
            SharedSnapshot(
                generatedAt: .now,
                accounts: [account(accountID: accountID, usage: at80)]
            )
        )
        XCTAssertEqual(firstCount.count, 1)
        let duplicateCount = try await coordinator.process(
            SharedSnapshot(
                generatedAt: .now,
                accounts: [account(accountID: accountID, usage: at80)]
            )
        )
        XCTAssertEqual(duplicateCount.count, 0)

        let at95 = snapshot(
            accountID: accountID,
            value: "96",
            state: .fresh
        )
        let thresholdCount = try await coordinator.process(
            SharedSnapshot(
                generatedAt: .now,
                accounts: [account(accountID: accountID, usage: at95)]
            )
        )
        XCTAssertEqual(thresholdCount.count, 1)

        let stale = snapshot(
            accountID: accountID,
            value: "99",
            state: .stale
        )
        let staleCount = try await coordinator.process(
            SharedSnapshot(
                generatedAt: .now,
                accounts: [account(accountID: accountID, usage: stale)]
            )
        )
        XCTAssertEqual(staleCount.count, 0)
        let thresholdNotificationCount = await deliverer.count()
        XCTAssertEqual(thresholdNotificationCount, 2)
    }

    func testAuthNotificationIsDeduplicated() async throws {
        let deliverer = RecordingDeliverer()
        let coordinator = NotificationCoordinator(deliverer: deliverer)
        let accountID = AccountID()
        let usage = UsageSnapshot(
            accountID: accountID,
            provider: .anthropic,
            surface: .api,
            freshness: Freshness(fetchedAt: .now, state: .noData),
            metrics: [],
            failure: .authRequired
        )
        let snapshot = SharedSnapshot(
            generatedAt: .now,
            accounts: [account(accountID: accountID, usage: usage)]
        )

        let firstCount = try await coordinator.process(snapshot)
        XCTAssertEqual(firstCount.count, 1)
        let duplicateCount = try await coordinator.process(snapshot)
        XCTAssertEqual(duplicateCount.count, 0)
        let authNotificationCount = await deliverer.count()
        XCTAssertEqual(authNotificationCount, 1)
    }

    private func account(
        accountID: AccountID,
        usage: UsageSnapshot
    ) -> SharedAccountSnapshot {
        SharedAccountSnapshot(
            accountID: accountID,
            provider: usage.provider,
            surface: usage.surface,
            label: "Fixture",
            isEnabled: true,
            usage: usage
        )
    }

    private func snapshot(
        accountID: AccountID,
        value: String,
        state: FreshnessState
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            provider: .openAI,
            surface: .api,
            freshness: Freshness(fetchedAt: .now, state: state),
            metrics: [
                UsageMetric(
                    key: "requests",
                    category: .requests,
                    unit: .count("requests"),
                    value: .known(DecimalString(rawValue: value)!),
                    limit: .known(DecimalString(rawValue: "100")!),
                    scope: .organization("org"),
                    period: .interval(
                        start: Date(timeIntervalSince1970: 1_700_000_000),
                        end: Date(timeIntervalSince1970: 1_700_000_060),
                        window: .calendar
                    )
                )
            ]
        )
    }
}

private actor RecordingDeliverer: NotificationDelivering {
    var notifications: [UsageNotification] = []

    func requestAuthorization() async throws {}

    func deliver(_ notification: UsageNotification) async throws {
        notifications.append(notification)
    }

    func count() -> Int {
        notifications.count
    }
}

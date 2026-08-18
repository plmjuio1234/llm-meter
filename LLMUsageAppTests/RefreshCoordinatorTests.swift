import Foundation
import os
import XCTest
import UsageCore
@testable import LLMUsageApp

final class RefreshCoordinatorTests: XCTestCase {
    func testRefreshWritesSnapshotReloadsWidgetAndIsolatesFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("refresh-\(UUID().uuidString)", isDirectory: true)
        let store = SnapshotStore(containerURL: root)
        let vault = TestCredentialStore()
        let registry = AccountRegistry(vault: vault)
        let first = try await registry.add(
            AccountDraft(provider: .openAI, surface: .consumerSubscription, label: "Healthy"),
            credential: OAuthCredential(accessToken: "first-oauth-token")
        )
        let second = try await registry.add(
            AccountDraft(provider: .openAI, surface: .consumerSubscription, label: "Fails"),
            credential: OAuthCredential(accessToken: "second-oauth-token")
        )

        let provider = FixtureUsageProvider(
            results: [
                first.id: .success(snapshot(for: first, value: "10")),
                second.id: .success(snapshot(for: second, value: "20"))
            ]
        )
        let reloads = ReloadCounter()
        let coordinator = RefreshCoordinator(
            registry: registry,
            vault: vault,
            snapshotStore: store,
            providers: [.openAI: provider],
            client: EmptyHTTPClient(),
            now: { Date(timeIntervalSince1970: 1_700_000_120) },
            reloadTimelines: { reloads.increment() }
        )
        let period = DateInterval(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_000_060)
        )

        _ = try await coordinator.refresh(period: period, trigger: .launch)
        provider.setResult(.failure(.offline), for: second.id)
        let reports = try await coordinator.refresh(period: period, trigger: .manual)

        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reloads.value, 2)
        let stored = try await store.read()
        let healthy = try XCTUnwrap(stored.accounts.first { $0.accountID == first.id })
        let failed = try XCTUnwrap(stored.accounts.first { $0.accountID == second.id })
        XCTAssertEqual(healthy.usage?.freshness.state, .fresh)
        XCTAssertEqual(failed.usage?.freshness.state, .stale)
        XCTAssertEqual(failed.usage?.failure, .offline)
        XCTAssertEqual(failed.usage?.metrics.first?.value.decimalString?.rawValue, "20")
    }

    func testRateLimitBackoffPreventsSecondProviderCallUntilEligible() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backoff-\(UUID().uuidString)", isDirectory: true)
        let store = SnapshotStore(containerURL: root)
        let vault = TestCredentialStore()
        let registry = AccountRegistry(vault: vault)
        let account = try await registry.add(
            AccountDraft(provider: .anthropic, surface: .consumerSubscription, label: "Limited"),
            credential: OAuthCredential(accessToken: "oauth-token")
        )
        let retryAt = Date(timeIntervalSince1970: 1_700_000_100)
        let provider = FixtureUsageProvider(
            results: [account.id: .failure(.rateLimited(retryAt: retryAt))]
        )
        let coordinator = RefreshCoordinator(
            registry: registry,
            vault: vault,
            snapshotStore: store,
            providers: [.anthropic: provider],
            client: EmptyHTTPClient(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            reloadTimelines: {}
        )
        let period = DateInterval(
            start: Date(timeIntervalSince1970: 1_699_999_900),
            end: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let first = try await coordinator.refresh(period: period, trigger: .launch)
        let second = try await coordinator.refresh(period: period, trigger: .manual)

        XCTAssertEqual(first.first?.status, .skippedRateLimited(retryAt))
        XCTAssertEqual(second.first?.status, .skippedRateLimited(retryAt))
        XCTAssertEqual(provider.callCount(for: account.id), 1)
    }

    private func snapshot(for account: AccountConnection, value: String) -> UsageSnapshot {
        UsageSnapshot(
            accountID: account.id,
            provider: account.provider,
            surface: account.surface,
            identity: account.identity,
            freshness: Freshness(
                fetchedAt: Date(timeIntervalSince1970: 1_700_000_060),
                asOf: Date(timeIntervalSince1970: 1_700_000_060),
                state: .fresh
            ),
            metrics: [
                UsageMetric(
                    key: "requests",
                    category: .requests,
                    unit: .count("requests"),
                    value: .known(DecimalString(rawValue: value)!),
                    scope: .organization("org"),
                    period: .interval(
                        start: Date(timeIntervalSince1970: 1_700_000_000),
                        end: Date(timeIntervalSince1970: 1_700_000_060),
                        window: .calendar
                    ),
                    reset: .notReported
                )
            ]
        )
    }
}

private final class TestCredentialStore: CredentialStoring, @unchecked Sendable {
    private let values = OSAllocatedUnfairLock(
        initialState: [CredentialReference: Data]()
    )

    func store(_ credential: Data, reference: CredentialReference) throws {
        values.withLock { $0[reference] = credential }
    }

    func credential(for reference: CredentialReference) throws -> Data {
        try values.withLock {
            guard let value = $0[reference] else {
                throw CredentialVaultError.keychain(-25300)
            }
            return value
        }
    }

    func delete(_ reference: CredentialReference) throws {
        _ = values.withLock { $0.removeValue(forKey: reference) }
    }
}

private final class FixtureUsageProvider: UsageProvider, @unchecked Sendable {
    let provider: Provider
    private struct State: Sendable {
        var results: [AccountID: Result<UsageSnapshot, ProviderFailure>]
        var calls: [AccountID: Int]
    }
    private let state: OSAllocatedUnfairLock<State>

    init(
        provider: Provider = .openAI,
        results: [AccountID: Result<UsageSnapshot, ProviderFailure>]
    ) {
        self.provider = provider
        self.state = OSAllocatedUnfairLock(
            initialState: State(results: results, calls: [:])
        )
    }

    func fetch(
        connection: AccountConnection,
        credential: OAuthCredential,
        period: DateInterval,
        client: any ProviderHTTPClient
    ) async -> Result<UsageSnapshot, ProviderFailure> {
        state.withLock {
            $0.calls[connection.id, default: 0] += 1
            return $0.results[connection.id] ?? .failure(.invalidResponse)
        }
    }

    func setResult(_ result: Result<UsageSnapshot, ProviderFailure>, for accountID: AccountID) {
        state.withLock { $0.results[accountID] = result }
    }

    func callCount(for accountID: AccountID) -> Int {
        state.withLock { $0.calls[accountID, default: 0] }
    }
}

private struct EmptyHTTPClient: ProviderHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw ProviderFailure.offline
    }
}

private final class ReloadCounter: @unchecked Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    func increment() {
        count.withLock { $0 += 1 }
    }

    var value: Int {
        count.withLock { $0 }
    }
}

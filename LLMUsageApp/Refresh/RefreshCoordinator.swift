import Foundation
import UsageCore

public enum RefreshTrigger: String, Sendable {
    case launch
    case loginItem
    case wake
    case manual
    case interval
    case networkRecovery
}

public enum RefreshStatus: Equatable, Sendable {
    case refreshed
    case skippedDisabled
    case skippedRateLimited(Date)
    case failed(UsageFailure)
}

public struct RefreshReport: Equatable, Sendable {
    public let accountID: AccountID
    public let status: RefreshStatus

    public init(accountID: AccountID, status: RefreshStatus) {
        self.accountID = accountID
        self.status = status
    }
}

/// Serializes refresh decisions while isolating provider failures per account.
public actor RefreshCoordinator {
    private let registry: AccountRegistry
    private let vault: any CredentialStoring
    private let snapshotStore: SnapshotStore
    private let providers: [Provider: any UsageProvider]
    private let client: any ProviderHTTPClient
    private let now: @Sendable () -> Date
    private let reloadTimelines: @Sendable () -> Void
    private var lastGood: [AccountID: UsageSnapshot] = [:]
    private var retryAt: [AccountID: Date] = [:]
    private var hasLoadedExistingSnapshot = false

    public init(
        registry: AccountRegistry,
        vault: any CredentialStoring,
        snapshotStore: SnapshotStore,
        providers: [Provider: any UsageProvider],
        client: any ProviderHTTPClient,
        now: @escaping @Sendable () -> Date = { Date() },
        reloadTimelines: @escaping @Sendable () -> Void
    ) {
        self.registry = registry
        self.vault = vault
        self.snapshotStore = snapshotStore
        self.providers = providers
        self.client = client
        self.now = now
        self.reloadTimelines = reloadTimelines
    }

    @discardableResult
    public func refresh(
        period: DateInterval,
        trigger: RefreshTrigger
    ) async throws -> [RefreshReport] {
        try await loadExistingSnapshotIfNeeded()

        let connections = await registry.allConnections()
        var reports: [RefreshReport] = []
        var projections: [SharedAccountSnapshot] = []

        for connection in connections {
            let result = await refresh(
                connection: connection,
                period: period,
                trigger: trigger
            )
            reports.append(result.report)
            projections.append(
                SharedAccountSnapshot(
                    connection: connection,
                    usage: result.snapshot
                )
            )
        }

        let currentOrder = await registry.allConnections().map(\.id)
        let orderIndex = Dictionary(
            uniqueKeysWithValues: currentOrder.enumerated().map { ($1, $0) }
        )
        projections.sort {
            (orderIndex[$0.accountID] ?? Int.max) < (orderIndex[$1.accountID] ?? Int.max)
        }
        try await snapshotStore.write(
            SharedSnapshot(generatedAt: now(), accounts: projections)
        )
        reloadTimelines()
        return reports
    }

    private func loadExistingSnapshotIfNeeded() async throws {
        guard !hasLoadedExistingSnapshot else { return }
        hasLoadedExistingSnapshot = true
        guard FileManager.default.fileExists(atPath: snapshotStore.fileURL.path) else {
            return
        }
        let existing = try await snapshotStore.read()

        for account in existing.accounts {
            guard let usage = account.usage, usage.failure == nil else { continue }
            lastGood[account.accountID] = usage
        }
    }

    private func refresh(
        connection: AccountConnection,
        period: DateInterval,
        trigger: RefreshTrigger
    ) async -> (report: RefreshReport, snapshot: UsageSnapshot?) {
        guard connection.isEnabled else {
            return (
                RefreshReport(accountID: connection.id, status: .skippedDisabled),
                lastGood[connection.id]
            )
        }

        if let scheduledRetry = retryAt[connection.id] {
            if scheduledRetry > now() {
                return (
                    RefreshReport(
                        accountID: connection.id,
                        status: .skippedRateLimited(scheduledRetry)
                    ),
                    staleSnapshot(
                        for: connection,
                        previous: lastGood[connection.id],
                        failure: .rateLimited(retryAt: scheduledRetry)
                    )
                )
            }
            retryAt.removeValue(forKey: connection.id)
        }

        guard let provider = providers[connection.provider] else {
            let failure = ProviderFailure.unsupported
            return failedResult(connection: connection, failure: failure)
        }

        do {
            let credentialData = try vault.credential(for: connection.credentialReference)
            var credential = try OAuthCredential.decode(credentialData)
            if credential.needsRefresh(now: now()) {
                do {
                    let refreshed = try await OAuthTokenService.refresh(
                        provider: connection.provider,
                        credential: credential,
                        client: client,
                        now: now
                    )
                    try vault.store(
                        refreshed.encoded(),
                        reference: connection.credentialReference
                    )
                    credential = refreshed
                } catch let error as OAuthTokenError {
                    let failure: ProviderFailure
                    switch error {
                    case .authRequired:
                        failure = .authRequired
                    case let .rateLimited(retryAt):
                        failure = .rateLimited(retryAt: retryAt)
                    case .offline:
                        failure = .offline
                    case .invalidResponse:
                        failure = .invalidResponse
                    }
                    return failedResult(connection: connection, failure: failure)
                } catch {
                    return failedResult(connection: connection, failure: .authRequired)
                }
            }

            let result = await provider.fetch(
                connection: connection,
                credential: credential,
                period: period,
                client: client
            )
            switch result {
            case let .success(snapshot):
                lastGood[connection.id] = snapshot
                retryAt.removeValue(forKey: connection.id)
                return (
                    RefreshReport(accountID: connection.id, status: .refreshed),
                    snapshot
                )
            case let .failure(failure):
                return failedResult(connection: connection, failure: failure)
            }
        } catch {
            return failedResult(connection: connection, failure: .authRequired)
        }
    }

    private func failedResult(
        connection: AccountConnection,
        failure: ProviderFailure
    ) -> (report: RefreshReport, snapshot: UsageSnapshot?) {
        if case let .rateLimited(scheduledRetry) = failure, let scheduledRetry {
            retryAt[connection.id] = scheduledRetry
        }

        let status: RefreshStatus = {
            if case let .rateLimited(retryAt) = failure, let retryAt {
                return .skippedRateLimited(retryAt)
            }
            return .failed(failure.usageFailure)
        }()

        return (
            RefreshReport(accountID: connection.id, status: status),
            staleSnapshot(
                for: connection,
                previous: lastGood[connection.id],
                failure: failure
            )
        )
    }

    private func staleSnapshot(
        for connection: AccountConnection,
        previous: UsageSnapshot?,
        failure: ProviderFailure
    ) -> UsageSnapshot {
        if let previous {
            return UsageSnapshot(
                accountID: connection.id,
                provider: connection.provider,
                surface: connection.surface,
                identity: connection.identity,
                freshness: Freshness(
                    fetchedAt: previous.freshness.fetchedAt,
                    asOf: previous.freshness.asOf,
                    freshUntil: previous.freshness.freshUntil,
                    state: .stale
                ),
                metrics: previous.metrics,
                failure: failure.usageFailure
            )
        }

        return UsageSnapshot(
            accountID: connection.id,
            provider: connection.provider,
            surface: connection.surface,
            identity: connection.identity,
            freshness: Freshness(
                fetchedAt: now(),
                state: .noData
            ),
            metrics: [],
            failure: failure.usageFailure
        )
    }
}

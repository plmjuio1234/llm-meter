import Foundation
import os
import UsageCore

enum FixtureData {
    static func install(
        registry: AccountRegistry,
        snapshotStore: SnapshotStore
    ) async throws {
        let openAI = try await registry.add(
                AccountDraft(
                    provider: .openAI,
                    surface: .consumerSubscription,
                    label: "OpenAI fixture",
                    identity: AccountIdentity(
                        provider: .openAI,
                        remotePrincipalID: "fixture-org",
                        scope: .organization("fixture-org")
                    )
                ),
                credential: OAuthCredential(
                    accessToken: "fixture-openai-oauth-token",
                    refreshToken: "fixture-openai-refresh-token",
                    accountID: "fixture-org"
                )
            )
        let anthropic = try await registry.add(
                AccountDraft(
                    provider: .anthropic,
                    surface: .consumerSubscription,
                    label: "Anthropic stale fixture",
                    identity: AccountIdentity(
                        provider: .anthropic,
                        remotePrincipalID: "fixture-workspace",
                        scope: .workspace("fixture-workspace")
                    )
                ),
                credential: OAuthCredential(
                    accessToken: "fixture-anthropic-oauth-token",
                    refreshToken: "fixture-anthropic-refresh-token",
                    accountID: "fixture-workspace"
                )
            )

        let now = Date()
        let period = MeasurementPeriod.interval(
                start: now.addingTimeInterval(-24 * 60 * 60),
                end: now,
                window: .calendar
            )
        let freshMetric = UsageMetric(
                key: "openai.oauth.rate_limit.primary",
                category: .providerDefined("rate_limit"),
                unit: .count("percent"),
                value: .known(DecimalString(rawValue: "80")!),
                limit: .known(DecimalString(rawValue: "100")!),
                scope: .organization("fixture-org"),
                period: period,
                reset: .at(now.addingTimeInterval(24 * 60 * 60), precision: .day)
            )
        let fresh = UsageSnapshot(
                accountID: openAI.id,
                provider: openAI.provider,
                surface: openAI.surface,
                identity: openAI.identity,
                freshness: Freshness(fetchedAt: now, asOf: now, state: .fresh),
                metrics: [freshMetric]
            )
        let stale = UsageSnapshot(
                accountID: anthropic.id,
                provider: anthropic.provider,
                surface: anthropic.surface,
                identity: anthropic.identity,
                freshness: Freshness(fetchedAt: now.addingTimeInterval(-3600), state: .stale),
                metrics: [],
                failure: .authRequired
            )

        try await snapshotStore.write(
                SharedSnapshot(
                    generatedAt: now,
                    accounts: [
                        SharedAccountSnapshot(connection: openAI, usage: fresh),
                        SharedAccountSnapshot(connection: anthropic, usage: stale)
                    ]
                )
        )
    }
}

final class FixtureCredentialStore: CredentialStoring, @unchecked Sendable {
    private let values = OSAllocatedUnfairLock(
        initialState: [CredentialReference: Data]()
    )

    func store(_ credential: Data, reference: CredentialReference) throws {
        values.withLock { $0[reference] = credential }
    }

    func credential(for reference: CredentialReference) throws -> Data {
        try values.withLock {
            guard let credential = $0[reference] else {
                throw CredentialVaultError.keychain(-25300)
            }
            return credential
        }
    }

    func delete(_ reference: CredentialReference) throws {
        _ = values.withLock { $0.removeValue(forKey: reference) }
    }
}

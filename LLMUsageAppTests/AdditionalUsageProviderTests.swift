import Foundation
import os
import XCTest
import UsageCore
@testable import LLMUsageApp

final class AdditionalUsageProviderTests: XCTestCase {
    func testMoonshotBalanceUsesOfficialPathAndCurrencyMetrics() async throws {
        let client = AdditionalFixtureHTTPClient(
            data: Data(
                """
                {
                  "code": 0,
                  "data": {
                    "available_balance": 49.58894,
                    "voucher_balance": "46.58893",
                    "cash_balance": 3.00001
                  },
                  "scode": "0x0",
                  "status": true
                }
                """.utf8
            )
        )
        let provider = MoonshotUsageProvider(
            baseURL: URL(string: "https://fixture.moonshot.local")!,
            now: { Date(timeIntervalSince1970: 1_735_776_100) }
        )

        let result = await provider.fetch(
            connection: connection(provider: .moonshot),
            credential: .apiKey("moonshot-api-key"),
            period: DateInterval(start: .distantPast, end: .now),
            client: client
        )

        let snapshot = try XCTUnwrap(try? result.get())
        XCTAssertEqual(
            snapshot.metrics.map(\.key),
            [
                "moonshot.api.balance.available",
                "moonshot.api.balance.voucher",
                "moonshot.api.balance.cash"
            ]
        )
        XCTAssertEqual(snapshot.metrics[0].unit, .currency("USD"))
        XCTAssertEqual(snapshot.metrics[0].value.decimalString?.rawValue, "49.58894")
        XCTAssertEqual(client.requests[0].url?.path, "/v1/users/me/balance")
        XCTAssertEqual(
            client.requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer moonshot-api-key"
        )
    }

    func testDeepSeekBalanceDecodesCurrencyBreakdown() async throws {
        let client = AdditionalFixtureHTTPClient(
            data: Data(
                """
                {
                  "is_available": true,
                  "balance_infos": [
                    {
                      "currency": "USD",
                      "total_balance": "12.50",
                      "granted_balance": 10,
                      "topped_up_balance": 2.5
                    }
                  ]
                }
                """.utf8
            )
        )

        let result = await DeepSeekUsageProvider(
            baseURL: URL(string: "https://fixture.deepseek.local")!
        ).fetch(
            connection: connection(provider: .deepSeek),
            credential: .apiKey("deepseek-api-key"),
            period: DateInterval(start: .distantPast, end: .now),
            client: client
        )

        let snapshot = try XCTUnwrap(try? result.get())
        XCTAssertEqual(
            snapshot.metrics.map(\.key),
            [
                "deepseek.api.balance.usd.total",
                "deepseek.api.balance.usd.granted",
                "deepseek.api.balance.usd.topped_up"
            ]
        )
        XCTAssertEqual(snapshot.metrics[0].value.decimalString?.rawValue, "12.50")
        XCTAssertEqual(client.requests[0].url?.path, "/user/balance")
    }

    func testOpenRouterKeyUsagePreservesLimitAndDailyBreakdown() async throws {
        let client = AdditionalFixtureHTTPClient(
            data: Data(
                """
                {
                  "data": {
                    "label": "coding",
                    "limit": 100,
                    "limit_remaining": 72.5,
                    "limit_reset": "monthly",
                    "usage": 27.5,
                    "usage_daily": 3.5,
                    "usage_weekly": 12,
                    "usage_monthly": 27.5
                  }
                }
                """.utf8
            )
        )

        let result = await OpenRouterUsageProvider(
            baseURL: URL(string: "https://fixture.openrouter.local")!
        ).fetch(
            connection: connection(provider: .openRouter),
            credential: .apiKey("openrouter-api-key"),
            period: DateInterval(start: .distantPast, end: .now),
            client: client
        )

        let snapshot = try XCTUnwrap(try? result.get())
        let usage = try XCTUnwrap(
            snapshot.metrics.first { $0.key == "openrouter.api.key.usage" }
        )
        XCTAssertEqual(usage.value.decimalString?.rawValue, "27.5")
        XCTAssertEqual(usage.limit?.decimalString?.rawValue, "100")
        XCTAssertEqual(usage.utilization, Decimal(string: "0.275"))
        XCTAssertTrue(snapshot.metrics.contains { $0.key == "openrouter.api.key.usage.daily" })
        XCTAssertEqual(client.requests[0].url?.path, "/api/v1/key")
    }

    func testAdditionalProvidersRejectOAuthCredential() async {
        let client = AdditionalFixtureHTTPClient(data: Data("{}".utf8))
        let result = await DeepSeekUsageProvider().fetch(
            connection: connection(provider: .deepSeek),
            credential: OAuthCredential(accessToken: "oauth-token"),
            period: DateInterval(start: .distantPast, end: .now),
            client: client
        )

        XCTAssertEqual(result, .failure(.authRequired))
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testCodingPlanProvidersRemainExplicitlyUnsupportedWithoutUsageAPI() async {
        let client = AdditionalFixtureHTTPClient(data: Data())
        for provider in [Provider.zhipu, .miniMax, .qwen] {
            let result = await UnsupportedUsageProvider(provider: provider).fetch(
                connection: connection(provider: provider),
                credential: .apiKey("coding-plan-key"),
                period: DateInterval(start: .distantPast, end: .now),
                client: client
            )
            XCTAssertEqual(result, .failure(.unsupported))
        }
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testCredentialKindDefaultsToOAuthForPersistedLegacyData() throws {
        let legacy = Data(
            """
            {"accessToken":"legacy-token"}
            """.utf8
        )

        let credential = try OAuthCredential.decode(legacy)
        XCTAssertEqual(credential.kind, .oauth)
        XCTAssertEqual(OAuthCredential.apiKey("api-key").kind, .apiKey)
    }

    func testKeychainStoreUpdatesExistingReference() throws {
        let vault = CredentialVault(service: "local.llmusage.additional.\(UUID().uuidString)")
        let reference = CredentialReference()
        defer { try? vault.removeAllCredentials() }

        try vault.store(Data("first".utf8), reference: reference)
        try vault.store(Data("second".utf8), reference: reference)

        XCTAssertEqual(try vault.credential(for: reference), Data("second".utf8))
    }

    private func connection(provider: Provider) -> AccountConnection {
        AccountConnection(
            provider: provider,
            surface: .api,
            label: "Fixture \(provider)",
            identity: nil,
            credentialReference: CredentialReference()
        )
    }
}

private final class AdditionalFixtureHTTPClient: ProviderHTTPClient, @unchecked Sendable {
    let data: Data
    let statusCode: Int
    private let lock = OSAllocatedUnfairLock(initialState: [URLRequest]())

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    var requests: [URLRequest] {
        lock.withLock { $0 }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { $0.append(request) }
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }
}

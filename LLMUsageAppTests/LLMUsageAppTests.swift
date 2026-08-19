import Foundation
import os
import XCTest
import UsageCore
@testable import LLMUsageApp

final class LLMUsageAppTests: XCTestCase {
    func testScaffoldLoads() {
        XCTAssertEqual("LLM Usage", "LLM Usage")
    }

    func testQuickStatusCountsReadyAttentionAndDisabledAccounts() {
        let freshAccountID = AccountID()
        let staleAccountID = AccountID()
        let noDataAccountID = AccountID()
        let disabledAccountID = AccountID()
        let snapshot = SharedSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            accounts: [
                SharedAccountSnapshot(
                    accountID: freshAccountID,
                    provider: .openAI,
                    surface: .consumerSubscription,
                    label: "Fresh",
                    isEnabled: true,
                    usage: quickStatusUsage(accountID: freshAccountID, state: .fresh)
                ),
                SharedAccountSnapshot(
                    accountID: staleAccountID,
                    provider: .anthropic,
                    surface: .consumerSubscription,
                    label: "Stale",
                    isEnabled: true,
                    usage: quickStatusUsage(accountID: staleAccountID, state: .stale)
                ),
                SharedAccountSnapshot(
                    accountID: noDataAccountID,
                    provider: .openRouter,
                    surface: .api,
                    label: "No data",
                    isEnabled: true
                ),
                SharedAccountSnapshot(
                    accountID: disabledAccountID,
                    provider: .deepSeek,
                    surface: .api,
                    label: "Disabled",
                    isEnabled: false
                )
            ]
        )

        let status = DashboardQuickStatus(snapshot: snapshot)

        XCTAssertEqual(status.totalAccounts, 4)
        XCTAssertEqual(status.activeAccounts, 3)
        XCTAssertEqual(status.healthyAccounts, 1)
        XCTAssertEqual(status.attentionAccounts, 2)
        XCTAssertEqual(status.disabledAccounts, 1)
        XCTAssertEqual(status.state, .attention)
        XCTAssertEqual(status.title, "2 accounts need attention")
        XCTAssertEqual(status.detail, "1 ready · 3 active · 1 disabled")
    }

    func testOAuthRefreshRotatesAccessTokenAndPreservesAccountMetadata() async throws {
        let client = TokenFixtureClient(
            data: Data(
                """
                {
                  "access_token": "refreshed-access",
                  "refresh_token": "rotated-refresh",
                  "expires_in": 3600
                }
                """.utf8
            )
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let credential = OAuthCredential(
            accessToken: "expired-access",
            refreshToken: "old-refresh",
            expiresAt: now,
            accountID: "account-123",
            email: "user@example.com"
        )

        let refreshed = try await OAuthTokenService.refresh(
            provider: .openAI,
            credential: credential,
            client: client,
            now: { now }
        )

        XCTAssertEqual(refreshed.accessToken, "refreshed-access")
        XCTAssertEqual(refreshed.refreshToken, "rotated-refresh")
        XCTAssertEqual(refreshed.accountID, "account-123")
        XCTAssertEqual(refreshed.email, "user@example.com")
        XCTAssertEqual(refreshed.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(
            client.requests[0].url?.absoluteString,
            "https://auth.openai.com/api/accounts/oauth/token"
        )
        let body = String(data: client.requests[0].httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=old-refresh"))
    }

    func testOAuthExchangeSendsPKCEFields() async throws {
        let client = TokenFixtureClient(
            data: Data(
                """
                {
                  "access_token": "access",
                  "refresh_token": "refresh",
                  "expires_in": "1800",
                  "id_token": "header.payload.signature"
                }
                """.utf8
            )
        )

        let credential = try await OAuthTokenService.exchange(
            provider: .anthropic,
            code: "authorization-code",
            verifier: "pkce-verifier",
            redirectURI: "http://localhost:3210/callback",
            client: client,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        XCTAssertEqual(credential.accessToken, "access")
        XCTAssertEqual(credential.idToken, "header.payload.signature")
        let body = String(data: client.requests[0].httpBody!, encoding: .utf8)!
        let fields = URLComponents(string: "https://fixture.local?\(body)")?.queryItems ?? []
        XCTAssertEqual(fields.first(where: { $0.name == "grant_type" })?.value, "authorization_code")
        XCTAssertEqual(fields.first(where: { $0.name == "code" })?.value, "authorization-code")
        XCTAssertEqual(fields.first(where: { $0.name == "code_verifier" })?.value, "pkce-verifier")
        XCTAssertEqual(
            fields.first(where: { $0.name == "redirect_uri" })?.value,
            "http://localhost:3210/callback"
        )
    }

    func testOAuthAccountLinkerCompletesLoopbackCallbackWithoutAPIInput() async throws {
        let client = TokenFixtureClient(
            data: Data(
                """
                {
                  "access_token": "linked-access",
                  "refresh_token": "linked-refresh",
                  "expires_in": 1800
                }
                """.utf8
            )
        )
        let browser = OAuthBrowserDriver()
        let linker = await MainActor.run {
            OAuthAccountLinker(
                client: client,
                openURL: { url in browser.open(url) }
            )
        }

        let link = try await linker.link(provider: .anthropic)

        XCTAssertEqual(link.draft.provider, .anthropic)
        XCTAssertEqual(link.draft.surface, .consumerSubscription)
        XCTAssertEqual(link.credential.accessToken, "linked-access")
        XCTAssertEqual(browser.lastURL?.host, "claude.ai")
        XCTAssertEqual(browser.lastURL?.path, "/oauth/authorize")
    }

    func testAccountDetailReadsConnectionAndRefreshMetadata() {
        let accountID = AccountID()
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let account = SharedAccountSnapshot(
            accountID: accountID,
            provider: .openAI,
            surface: .consumerSubscription,
            label: "Work",
            isEnabled: false,
            identity: AccountIdentity(
                provider: .openAI,
                remotePrincipalID: "remote-account",
                scope: .account("remote-account")
            ),
            usage: UsageSnapshot(
                accountID: accountID,
                provider: .openAI,
                surface: .consumerSubscription,
                freshness: Freshness(fetchedAt: fetchedAt, state: .fresh),
                metrics: []
            )
        )

        XCTAssertFalse(AccountDetailPresentation.isEnabled(account))
        XCTAssertEqual(AccountDetailPresentation.remoteAccountID(account), "remote-account")
        XCTAssertEqual(AccountDetailPresentation.lastRefresh(account), fetchedAt)
    }
}

private func quickStatusUsage(
    accountID: AccountID,
    state: FreshnessState
) -> UsageSnapshot {
    UsageSnapshot(
        accountID: accountID,
        provider: .openAI,
        surface: .consumerSubscription,
        freshness: Freshness(
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: state
        ),
        metrics: []
    )
}

final class QuotaPresentationTests: XCTestCase {
    func testOpenAIGaugeUsesPrimaryWindowAndIgnoresSpark() {
        let primary = UsageMetric(
            key: "openai.oauth.rate_limit.primary",
            category: .providerDefined("rate_limit"),
            unit: .count("percent"),
            value: .known(DecimalString(rawValue: "42")!),
            limit: .known(DecimalString(rawValue: "100")!),
            scope: .unknown,
            period: .unknown
        )
        let spark = UsageMetric(
            key: "openai.oauth.rate_limit.gpt-5-3-codex-spark.primary",
            category: .providerDefined("rate_limit"),
            unit: .count("percent"),
            value: .known(DecimalString(rawValue: "3")!),
            limit: .known(DecimalString(rawValue: "100")!),
            scope: .unknown,
            period: .unknown
        )
        let usage = UsageSnapshot(
            accountID: AccountID(),
            provider: .openAI,
            surface: .consumerSubscription,
            freshness: Freshness(fetchedAt: .now, state: .fresh),
            metrics: [spark, primary]
        )

        XCTAssertEqual(
            QuotaPresentation.primaryMetric(for: usage, provider: .openAI)?.key,
            primary.key
        )
        XCTAssertEqual(
            try XCTUnwrap(QuotaPresentation.remainingFraction(for: primary)),
            0.58,
            accuracy: 0.0001
        )
    }

    func testOpenAIGaugeDoesNotFallBackToSparkWhenPrimaryMissing() {
        let usage = UsageSnapshot(
            accountID: AccountID(),
            provider: .openAI,
            surface: .consumerSubscription,
            freshness: Freshness(fetchedAt: .now, state: .fresh),
            metrics: [
                UsageMetric(
                    key: "openai.oauth.rate_limit.gpt-5-3-codex-spark.primary",
                    category: .providerDefined("rate_limit"),
                    unit: .count("percent"),
                    value: .known(DecimalString(rawValue: "3")!),
                    limit: .known(DecimalString(rawValue: "100")!),
                    scope: .unknown,
                    period: .unknown
                )
            ]
        )

        XCTAssertNil(QuotaPresentation.primaryMetric(for: usage, provider: .openAI))
    }
}

private final class TokenFixtureClient: ProviderHTTPClient, @unchecked Sendable {
    let data: Data
    private let lock = OSAllocatedUnfairLock(initialState: [URLRequest]())

    init(data: Data) {
        self.data = data
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
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

private final class OAuthBrowserDriver: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [URL]())

    var lastURL: URL? {
        lock.withLock { $0.last }
    }

    func open(_ url: URL) -> Bool {
        lock.withLock { $0.append(url) }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let redirectValue = items.first(where: { $0.name == "redirect_uri" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value,
              var callback = URLComponents(string: redirectValue) else {
            return false
        }
        callback.queryItems = [
            URLQueryItem(name: "code", value: "browser-authorization-code"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let callbackURL = callback.url else { return false }
        Task.detached {
            _ = try? await URLSession.shared.data(from: callbackURL)
        }
        return true
    }
}

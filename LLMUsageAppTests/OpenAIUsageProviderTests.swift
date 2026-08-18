import Foundation
import os
import XCTest
import UsageCore
@testable import LLMUsageApp

final class OpenAIUsageProviderTests: XCTestCase {
    func testOAuthQuotaDecodesAndSendsChatGPTAccountHeader() async throws {
        let client = FixtureHTTPClient(
            data: Data(
                """
                {
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 42,
                      "limit_window_seconds": 18000,
                      "reset_at": 1735779600
                    },
                    "secondary_window": {
                      "used_percent": "8.5",
                      "limit_window_seconds": 604800,
                      "reset_at": 1736200000
                    }
                  }
                }
                """.utf8
            )
        )
        let provider = OpenAIUsageProvider(
            baseURL: URL(string: "https://fixture.openai.local/backend-api")!,
            now: { Date(timeIntervalSince1970: 1_735_776_100) }
        )

        let result = await provider.fetch(
            connection: connection(),
            credential: OAuthCredential(
                accessToken: "oauth-access-token",
                accountID: "chatgpt-account-123"
            ),
            period: DateInterval(start: .distantPast, end: .now),
            client: client
        )

        let snapshot = try XCTUnwrap(try? result.get())
        XCTAssertEqual(snapshot.metrics.count, 2)
        XCTAssertEqual(
            snapshot.metrics.map(\.key),
            ["openai.oauth.rate_limit.primary", "openai.oauth.rate_limit.secondary"]
        )
        XCTAssertEqual(snapshot.metrics[0].value.decimalString?.rawValue, "42")
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].url?.path, "/backend-api/wham/usage")
        XCTAssertEqual(
            client.requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer oauth-access-token"
        )
        XCTAssertEqual(
            client.requests[0].value(forHTTPHeaderField: "ChatGPT-Account-Id"),
            "chatgpt-account-123"
        )
    }

    func testAPIConnectionIsUnsupportedAndNeverUsesCredential() async {
        let client = FixtureHTTPClient(data: Data("{}".utf8))
        let provider = OpenAIUsageProvider()

        let result = await provider.fetch(
            connection: connection(surface: .api),
            credential: OAuthCredential(accessToken: "oauth-access-token"),
            period: DateInterval(start: .distantPast, end: .now),
            client: client
        )

        XCTAssertEqual(result, .failure(.unsupported))
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testRateLimitResponseMapsToBackoff() async {
        let client = FixtureHTTPClient(
            data: Data("{}".utf8),
            statusCode: 429,
            headers: ["Retry-After": "30"]
        )
        let provider = OpenAIUsageProvider()

        let result = await provider.fetch(
            connection: connection(),
            credential: OAuthCredential(accessToken: "oauth-access-token"),
            period: DateInterval(start: .distantPast, end: .now),
            client: client
        )

        guard case let .failure(.rateLimited(retryAt)) = result else {
            return XCTFail("Expected OAuth usage rate limiting.")
        }
        XCTAssertNotNil(retryAt)
    }

    func testNestedAdditionalRateLimitsAndStringTimestampsRemainReadable() async throws {
        let client = FixtureHTTPClient(
            data: Data(
                """
                {
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 11,
                      "limit_window_seconds": 18000,
                      "reset_at": 1735779600
                    }
                  },
                  "additional_rate_limits": [
                    {
                      "limit_name": "gpt-5.3-codex-spark",
                      "rate_limit": {
                        "primary_window": {
                          "used_percent": "3",
                          "limit_window_seconds": "3600",
                          "reset_at": "1735779600"
                        }
                      }
                    }
                  ]
                }
                """.utf8
            )
        )

        let result = await OpenAIUsageProvider(
            baseURL: URL(string: "https://fixture.openai.local/backend-api")!
        ).fetch(
            connection: connection(),
            credential: OAuthCredential(accessToken: "oauth-token"),
            period: DateInterval(start: .distantPast, end: .now),
            client: client
        )

        let snapshot = try XCTUnwrap(try? result.get())
        XCTAssertEqual(snapshot.metrics.count, 2)
        XCTAssertTrue(snapshot.metrics.contains { $0.key.contains("gpt-5-3-codex-spark") })
    }

    private func connection(
        surface: Surface = .consumerSubscription
    ) -> AccountConnection {
        AccountConnection(
            provider: .openAI,
            surface: surface,
            label: "OpenAI OAuth",
            identity: AccountIdentity(
                provider: .openAI,
                remotePrincipalID: "chatgpt-account-123",
                scope: .account("chatgpt-account-123")
            ),
            credentialReference: CredentialReference()
        )
    }
}

private final class FixtureHTTPClient: ProviderHTTPClient, @unchecked Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
    private let lock = OSAllocatedUnfairLock(initialState: [URLRequest]())

    init(
        data: Data,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }

    var requests: [URLRequest] {
        lock.withLock { $0 }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { $0.append(request) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (data, response)
    }
}

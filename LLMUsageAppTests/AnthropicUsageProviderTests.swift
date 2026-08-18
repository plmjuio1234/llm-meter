import Foundation
import os
import XCTest
import UsageCore
@testable import LLMUsageApp

final class AnthropicUsageProviderTests: XCTestCase {
    func testOAuthQuotaDecodesAndSendsOAuthHeaders() async throws {
        let client = FixtureHTTPClient(
            data: Data(
                """
                {
                  "five_hour": {
                    "utilization": 0.42,
                    "resets_at": "2025-01-02T03:04:05.000Z"
                  },
                  "seven_day": {
                    "utilization": "0.08",
                    "resets_at": "2025-01-07T03:04:05Z"
                  },
                  "seven_day_opus": null
                }
                """.utf8
            )
        )
        let provider = AnthropicUsageProvider(
            baseURL: URL(string: "https://fixture.anthropic.local")!,
            now: { Date(timeIntervalSince1970: 1_735_776_100) }
        )

        let result = await provider.fetch(
            connection: connection(),
            credential: OAuthCredential(accessToken: "claude-oauth-token"),
            period: DateInterval(start: .distantPast, end: .now),
            client: client
        )

        let snapshot = try XCTUnwrap(try? result.get())
        XCTAssertEqual(snapshot.metrics.count, 2)
        XCTAssertEqual(
            snapshot.metrics.map(\.key),
            [
                "anthropic.oauth.rate_limit.five_hour",
                "anthropic.oauth.rate_limit.seven_day"
            ]
        )
        XCTAssertEqual(snapshot.metrics[0].value.decimalString?.rawValue, "0.42")
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].url?.path, "/api/oauth/usage")
        XCTAssertEqual(
            client.requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer claude-oauth-token"
        )
        XCTAssertEqual(
            client.requests[0].value(forHTTPHeaderField: "anthropic-beta"),
            "oauth-2025-04-20"
        )
    }

    func testAPIConnectionIsUnsupported() async {
        let client = FixtureHTTPClient(data: Data("{}".utf8))
        let provider = AnthropicUsageProvider()

        let result = await provider.fetch(
            connection: connection(surface: .api),
            credential: OAuthCredential(accessToken: "oauth-token"),
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
            headers: ["Retry-After": "60"]
        )
        let provider = AnthropicUsageProvider()

        let result = await provider.fetch(
            connection: connection(),
            credential: OAuthCredential(accessToken: "oauth-token"),
            period: DateInterval(start: .distantPast, end: .now),
            client: client
        )

        guard case let .failure(.rateLimited(retryAt)) = result else {
            return XCTFail("Expected OAuth usage rate limiting.")
        }
        XCTAssertNotNil(retryAt)
    }

    func testScopedLimitsShapeProducesAQuotaMetric() async throws {
        let client = FixtureHTTPClient(
            data: Data(
                """
                {
                  "limits": [
                    {
                      "kind": "weekly_scoped",
                      "group": "weekly",
                      "percent": 42,
                      "resets_at": "2025-01-07T03:04:05Z",
                      "scope": {
                        "model": {
                          "display_name": "Opus"
                        }
                      },
                      "is_active": true
                    }
                  ]
                }
                """.utf8
            )
        )

        let result = await AnthropicUsageProvider(
            baseURL: URL(string: "https://fixture.anthropic.local")!
        ).fetch(
            connection: connection(),
            credential: OAuthCredential(accessToken: "oauth-token"),
            period: DateInterval(start: .distantPast, end: .now),
            client: client
        )

        let snapshot = try XCTUnwrap(try? result.get())
        let metric = try XCTUnwrap(snapshot.metrics.first)
        XCTAssertEqual(metric.key, "anthropic.oauth.rate_limit.Opus")
        XCTAssertEqual(metric.value.decimalString?.rawValue, "0.42")
    }

    private func connection(
        surface: Surface = .consumerSubscription
    ) -> AccountConnection {
        AccountConnection(
            provider: .anthropic,
            surface: surface,
            label: "Claude OAuth",
            identity: AccountIdentity(
                provider: .anthropic,
                remotePrincipalID: "claude-account-123",
                scope: .account("claude-account-123")
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

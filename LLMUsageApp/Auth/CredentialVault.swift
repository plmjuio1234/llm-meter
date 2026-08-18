import Foundation
import Security
import UsageCore
import AppKit
import CryptoKit
import Network

public enum CredentialKind: String, Codable, Equatable, Sendable {
    case oauth
    case apiKey = "api_key"
}

public struct OAuthCredential: Codable, Equatable, Sendable {
    public let kind: CredentialKind
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let accountID: String?
    public let email: String?
    public let idToken: String?

    public init(
        accessToken: String,
        kind: CredentialKind = .oauth,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        accountID: String? = nil,
        email: String? = nil,
        idToken: String? = nil
    ) {
        self.kind = kind
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.email = email
        self.idToken = idToken
    }

    public static func apiKey(_ value: String) -> Self {
        Self(accessToken: value, kind: .apiKey)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case accessToken
        case refreshToken
        case expiresAt
        case accountID
        case email
        case idToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(CredentialKind.self, forKey: .kind) ?? .oauth
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(accountID, forKey: .accountID)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(idToken, forKey: .idToken)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> OAuthCredential {
        let credential = try JSONDecoder().decode(Self.self, from: data)
        guard !credential.accessToken.isEmpty else {
            throw OAuthCredentialError.missingAccessToken
        }
        return credential
    }

    public func needsRefresh(now: Date, leeway: TimeInterval = 300) -> Bool {
        guard kind == .oauth else { return false }
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leeway)
    }
}

public enum OAuthCredentialError: Error, Equatable, Sendable {
    case missingAccessToken
}

public enum OAuthTokenError: Error, Equatable, Sendable {
    case authRequired
    case rateLimited(retryAt: Date?)
    case offline
    case invalidResponse
}

public enum OAuthTokenService {
    private struct Configuration {
        let tokenURL: URL
        let clientID: String
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval?
        let expiresAt: Date?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt = "expires_at"
            case idToken = "id_token"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try container.decode(String.self, forKey: .accessToken)
            refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
            expiresIn = Self.decodeTimeInterval(container, forKey: .expiresIn)
            expiresAt = Self.decodeDate(container, forKey: .expiresAt)
            idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
        }

        private static func decodeTimeInterval(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> TimeInterval? {
            if let value = try? container.decode(TimeInterval.self, forKey: key) {
                return value
            }
            if let value = try? container.decode(String.self, forKey: key) {
                return TimeInterval(value)
            }
            return nil
        }

        private static func decodeDate(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Date? {
            if let value = try? container.decode(TimeInterval.self, forKey: key) {
                return Date(timeIntervalSince1970: value)
            }
            guard let value = try? container.decode(String.self, forKey: key) else {
                return nil
            }
            if let timestamp = TimeInterval(value) {
                return Date(timeIntervalSince1970: timestamp)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value) ?? {
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: value)
            }()
        }
    }

    public static func exchange(
        provider: Provider,
        code: String,
        verifier: String,
        redirectURI: String,
        client: any ProviderHTTPClient,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> OAuthCredential {
        let configuration = try configuration(for: provider)
        let response = try await request(
            url: configuration.tokenURL,
            clientID: configuration.clientID,
            fields: [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("code_verifier", verifier),
                ("redirect_uri", redirectURI)
            ],
            client: client
        )
        return try makeCredential(response, now: now)
    }

    public static func refresh(
        provider: Provider,
        credential: OAuthCredential,
        client: any ProviderHTTPClient,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> OAuthCredential {
        guard credential.kind == .oauth else {
            throw OAuthTokenError.authRequired
        }
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw OAuthTokenError.authRequired
        }
        let configuration = try configuration(for: provider)
        let response = try await request(
            url: configuration.tokenURL,
            clientID: configuration.clientID,
            fields: [
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken)
            ],
            client: client
        )
        let refreshed = try makeCredential(response, now: now)
        return OAuthCredential(
            accessToken: refreshed.accessToken,
            kind: .oauth,
            refreshToken: refreshed.refreshToken ?? credential.refreshToken,
            expiresAt: refreshed.expiresAt,
            accountID: credential.accountID,
            email: credential.email,
            idToken: refreshed.idToken ?? credential.idToken
        )
    }

    private static func configuration(for provider: Provider) throws -> Configuration {
        switch provider {
        case .openAI:
            return Configuration(
                tokenURL: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!,
                clientID: "app_EMoamEEZ73f0CkXaXp7hrann"
            )
        case .anthropic:
            return Configuration(
                tokenURL: URL(string: "https://console.anthropic.com/v1/oauth/token")!,
                clientID: "https://claude.ai/oauth/claude-code-client-metadata"
            )
        case .moonshot, .moonshotChina, .deepSeek, .openRouter, .zhipu, .miniMax, .qwen, .other:
            throw OAuthTokenError.invalidResponse
        }
    }

    private static func request(
        url: URL,
        clientID: String,
        fields: [(String, String)],
        client: any ProviderHTTPClient
    ) async throws -> TokenResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncoded([("client_id", clientID)] + fields)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.data(for: request)
        } catch let error as OAuthTokenError {
            throw error
        } catch {
            throw OAuthTokenError.offline
        }

        switch response.statusCode {
        case 200..<300:
            do {
                let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
                guard !tokenResponse.accessToken.isEmpty else {
                    throw OAuthTokenError.invalidResponse
                }
                return tokenResponse
            } catch let error as OAuthTokenError {
                throw error
            } catch {
                throw OAuthTokenError.invalidResponse
            }
        case 401, 403:
            throw OAuthTokenError.authRequired
        case 429:
            throw OAuthTokenError.rateLimited(
                retryAt: retryDate(from: response.value(forHTTPHeaderField: "Retry-After"))
            )
        default:
            throw OAuthTokenError.invalidResponse
        }
    }

    private static func makeCredential(
        _ response: TokenResponse,
        now: @Sendable () -> Date
    ) throws -> OAuthCredential {
        guard !response.accessToken.isEmpty else {
            throw OAuthTokenError.invalidResponse
        }
        return OAuthCredential(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: response.expiresAt ?? response.expiresIn.map { now().addingTimeInterval($0) },
            idToken: response.idToken
        )
    }

    private static func formEncoded(_ fields: [(String, String)]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func retryDate(from value: String?) -> Date? {
        guard let value, let seconds = TimeInterval(value) else { return nil }
        return Date().addingTimeInterval(seconds)
    }
}

public struct OAuthAccountLink: Sendable {
    public let draft: AccountDraft
    public let credential: OAuthCredential

    public init(draft: AccountDraft, credential: OAuthCredential) {
        self.draft = draft
        self.credential = credential
    }
}

public enum OAuthLinkingError: Error, Equatable, Sendable {
    case unsupportedProvider
    case listenerUnavailable
    case browserUnavailable
    case callbackFailed
    case stateMismatch
    case authorizationDenied
    case invalidResponse
}

@MainActor
public final class OAuthAccountLinker {
    private struct Configuration {
        let authorizationURL: URL
        let clientID: String
        let scope: String
        let callbackPath: String
        let fixedPort: UInt16?
    }

    private let client: any ProviderHTTPClient
    private let openURL: @MainActor @Sendable (URL) -> Bool

    public init(
        client: any ProviderHTTPClient = URLSessionProviderHTTPClient(),
        openURL: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.client = client
        self.openURL = openURL
    }

    public func link(provider: Provider) async throws -> OAuthAccountLink {
        let configuration = try configuration(for: provider)
        let listener = try LoopbackOAuthListener(port: configuration.fixedPort)
        let port = try await listener.start()
        defer { listener.stop() }

        let verifier = PKCE.randomString()
        let state = verifier
        let redirectURI = "http://localhost:\(port)\(configuration.callbackPath)"
        let authorizationURL = try authorizationURL(
            configuration: configuration,
            redirectURI: redirectURI,
            verifier: verifier,
            state: state
        )
        guard openURL(authorizationURL) else {
            throw OAuthLinkingError.browserUnavailable
        }

        let callback = try await listener.waitForCallback()
        guard callback.error == nil else {
            throw OAuthLinkingError.authorizationDenied
        }
        guard callback.state == state else {
            throw OAuthLinkingError.stateMismatch
        }
        guard let code = callback.code, !code.isEmpty else {
            throw OAuthLinkingError.callbackFailed
        }

        var credential = try await OAuthTokenService.exchange(
            provider: provider,
            code: code,
            verifier: verifier,
            redirectURI: redirectURI,
            client: client
        )
        let claims = JWTClaims(token: credential.idToken ?? credential.accessToken)
        credential = OAuthCredential(
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            expiresAt: credential.expiresAt,
            accountID: claims.accountID,
            email: claims.email,
            idToken: credential.idToken
        )

        let accountID = credential.accountID ?? "oauth-\(UUID().uuidString)"
        let label = credential.email ?? "\(provider.displayName) OAuth"
        let draft = AccountDraft(
            provider: provider,
            surface: .consumerSubscription,
            label: label,
            identity: AccountIdentity(
                provider: provider,
                remotePrincipalID: accountID,
                scope: .account(accountID)
            )
        )
        return OAuthAccountLink(draft: draft, credential: credential)
    }

    private func configuration(for provider: Provider) throws -> Configuration {
        switch provider {
        case .openAI:
            return Configuration(
                authorizationURL: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
                clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
                scope: "openid profile email offline_access",
                callbackPath: "/auth/callback",
                fixedPort: 1455
            )
        case .anthropic:
            return Configuration(
                authorizationURL: URL(string: "https://claude.ai/oauth/authorize")!,
                clientID: "https://claude.ai/oauth/claude-code-client-metadata",
                scope: "user:profile user:inference",
                callbackPath: "/callback",
                fixedPort: nil
            )
        case .moonshot, .moonshotChina, .deepSeek, .openRouter, .zhipu, .miniMax, .qwen, .other:
            throw OAuthLinkingError.unsupportedProvider
        }
    }

    private func authorizationURL(
        configuration: Configuration,
        redirectURI: String,
        verifier: String,
        state: String
    ) throws -> URL {
        var components = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: configuration.scope),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components?.url else {
            throw OAuthLinkingError.invalidResponse
        }
        return url
    }
}

private extension Provider {
    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .moonshot: return "Kimi / Moonshot"
        case .moonshotChina: return "Kimi / Moonshot China"
        case .deepSeek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        case .zhipu: return "GLM / Zhipu"
        case .miniMax: return "MiniMax"
        case .qwen: return "Qwen"
        case let .other(value): return value
        }
    }
}

private enum PKCE {
    static func randomString() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64URLEncoded()
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

private struct JWTClaims {
    let accountID: String?
    let email: String?

    init(token: String) {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let data = Data(base64URLEncoded: String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            accountID = nil
            email = nil
            return
        }
        let auth = object["https://api.openai.com/auth"] as? [String: Any]
        accountID = auth?["chatgpt_account_id"] as? String
            ?? auth?["account_id"] as? String
            ?? object["account_id"] as? String
            ?? object["sub"] as? String
        email = object["email"] as? String
    }
}

private final class LoopbackOAuthListener: @unchecked Sendable {
    fileprivate struct Callback {
        let code: String?
        let state: String?
        let error: String?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "local.llmusage.oauth-loopback")
    private let lock = NSLock()
    private var callbackContinuation: CheckedContinuation<Callback, Error>?
    private var buffer = Data()

    init(port: UInt16?) throws {
        let endpoint: NWEndpoint.Port
        if let port {
            guard let fixed = NWEndpoint.Port(rawValue: port) else {
                throw OAuthLinkingError.listenerUnavailable
            }
            endpoint = fixed
        } else {
            endpoint = .any
        }
        do {
            listener = try NWListener(using: .tcp, on: endpoint)
        } catch {
            throw OAuthLinkingError.listenerUnavailable
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = self.listener.port?.rawValue else {
                        continuation.resume(throwing: OAuthLinkingError.listenerUnavailable)
                        return
                    }
                    continuation.resume(returning: port)
                case .failed:
                    continuation.resume(throwing: OAuthLinkingError.listenerUnavailable)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.receive(connection)
            }
            listener.start(queue: self.queue)
        }
    }

    fileprivate func waitForCallback() async throws -> Callback {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                callbackContinuation = continuation
            }
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            callbackContinuation?.resume(throwing: OAuthLinkingError.callbackFailed)
            callbackContinuation = nil
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            self?.read(from: connection)
        }
        connection.start(queue: queue)
    }

    private func read(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, isComplete, _ in
            guard let self else { return }
            if let data {
                self.buffer.append(data)
            }
            if let headerEnd = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: self.buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.finish(connection: connection, request: header)
            } else if !isComplete {
                self.read(from: connection)
            } else {
                self.finish(connection: connection, request: "")
            }
        }
    }

    private func finish(connection: NWConnection, request: String) {
        let path = request.split(separator: "\r\n").first?
            .split(separator: " ").dropFirst().first.map(String.init)
        var callback = Callback(code: nil, state: nil, error: nil)
        if let path, let components = URLComponents(string: "http://localhost\(path)") {
            let items = components.queryItems ?? []
            callback = Callback(
                code: items.first(where: { $0.name == "code" })?.value,
                state: items.first(where: { $0.name == "state" })?.value,
                error: items.first(where: { $0.name == "error" })?.value
            )
        }
        let body = Self.completionPage(for: callback)
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Cache-Control: no-store\r
        X-Content-Type-Options: nosniff\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
        lock.withLock {
            callbackContinuation?.resume(returning: callback)
            callbackContinuation = nil
        }
    }

    private static func completionPage(for callback: Callback) -> String {
        let succeeded = callback.error == nil && callback.code?.isEmpty == false
        let status = succeeded ? "success" : "failure"
        let title = succeeded ? "Account connected" : "Connection could not be completed"
        let message = succeeded
            ? "Your account is securely connected. You can return to LLM Usage."
            : "The sign-in was not completed. Return to LLM Usage and try again."
        let icon = succeeded
            ? """
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M5 12.5 9.5 17 19 7.5"></path>
              </svg>
              """
            : """
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path d="M12 7.5v5.5"></path>
                <path d="M12 17.5h.01"></path>
              </svg>
              """

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light dark">
          <title>LLM Usage</title>
          <style>
            :root {
              color-scheme: light dark;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display",
                "SF Pro Text", system-ui, sans-serif;
            }
            * { box-sizing: border-box; }
            body {
              align-items: center;
              background:
                radial-gradient(circle at 18% 12%, rgba(0, 113, 227, .14), transparent 36%),
                radial-gradient(circle at 86% 88%, rgba(52, 199, 89, .12), transparent 34%),
                #f5f5f7;
              color: #1d1d1f;
              display: flex;
              justify-content: center;
              margin: 0;
              min-height: 100vh;
              padding: 24px;
            }
            .card {
              -webkit-backdrop-filter: blur(24px);
              backdrop-filter: blur(24px);
              background: rgba(255, 255, 255, .78);
              border: 1px solid rgba(255, 255, 255, .86);
              border-radius: 28px;
              box-shadow: 0 24px 70px rgba(0, 0, 0, .12);
              max-width: 440px;
              padding: 42px 36px 34px;
              text-align: center;
              width: 100%;
            }
            .icon {
              align-items: center;
              background: #34c759;
              border-radius: 22px;
              box-shadow: 0 10px 24px rgba(52, 199, 89, .28);
              color: white;
              display: flex;
              height: 68px;
              justify-content: center;
              margin: 0 auto 24px;
              width: 68px;
            }
            .failure .icon {
              background: #ff9f0a;
              box-shadow: 0 10px 24px rgba(255, 159, 10, .24);
            }
            svg {
              fill: none;
              height: 34px;
              stroke: currentColor;
              stroke-linecap: round;
              stroke-linejoin: round;
              stroke-width: 2.5;
              width: 34px;
            }
            h1 {
              font-size: 28px;
              letter-spacing: -.02em;
              line-height: 1.15;
              margin: 0 0 12px;
            }
            p {
              color: #6e6e73;
              font-size: 16px;
              line-height: 1.5;
              margin: 0 auto;
              max-width: 330px;
            }
            .button {
              background: #0071e3;
              border: 0;
              border-radius: 999px;
              color: white;
              cursor: pointer;
              display: inline-block;
              font: inherit;
              font-size: 15px;
              font-weight: 600;
              margin-top: 28px;
              padding: 12px 22px;
              transition: transform .16s ease, background .16s ease;
            }
            .button:hover { background: #0077ed; transform: translateY(-1px); }
            .button:active { transform: translateY(0); }
            .hint {
              color: #86868b;
              font-size: 12px;
              margin-top: 14px;
            }
            @media (prefers-color-scheme: dark) {
              body {
                background:
                  radial-gradient(circle at 18% 12%, rgba(10, 132, 255, .2), transparent 36%),
                  radial-gradient(circle at 86% 88%, rgba(48, 209, 88, .14), transparent 34%),
                  #1c1c1e;
                color: #f5f5f7;
              }
              .card {
                background: rgba(44, 44, 46, .78);
                border-color: rgba(255, 255, 255, .12);
                box-shadow: 0 24px 70px rgba(0, 0, 0, .34);
              }
              p { color: #98989d; }
              .hint { color: #8e8e93; }
            }
            @media (prefers-reduced-motion: reduce) {
              .button { transition: none; }
            }
          </style>
        </head>
        <body>
          <main class="card \(status)" data-status="\(status)" aria-live="polite">
            <div class="icon">\(icon)</div>
            <h1>\(title)</h1>
            <p>\(message)</p>
            <button class="button" type="button" onclick="window.close()">Close window</button>
            <div class="hint">If it stays open, you can close this tab manually.</div>
          </main>
        </body>
        </html>
        """
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}

public protocol CredentialStoring: Sendable {
    func store(_ credential: Data, reference: CredentialReference) throws
    func credential(for reference: CredentialReference) throws -> Data
    func delete(_ reference: CredentialReference) throws
}

public enum CredentialVaultError: Error, Equatable, Sendable {
    case keychain(OSStatus)
}

/// Host-only credential storage backed by a generic-password Keychain service.
public final class CredentialVault: CredentialStoring, @unchecked Sendable {
    public let service: String
    private let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func store(_ credential: Data, reference: CredentialReference) throws {
        var query = baseQuery(for: reference)
        query[kSecValueData as String] = credential
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var update = baseQuery(for: reference)
            update[kSecValueData as String] = credential
            update[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let updateStatus = SecItemUpdate(
                baseQuery(for: reference) as CFDictionary,
                update as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw CredentialVaultError.keychain(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else { throw CredentialVaultError.keychain(status) }
    }

    public func credential(for reference: CredentialReference) throws -> Data {
        var query = baseQuery(for: reference)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw CredentialVaultError.keychain(status) }
        guard let data = result as? Data else { throw CredentialVaultError.keychain(errSecInternalError) }
        return data
    }

    public func delete(_ reference: CredentialReference) throws {
        let status = SecItemDelete(baseQuery(for: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialVaultError.keychain(status)
        }
    }

    /// Deletes only items belonging to this vault service. Intended for explicit
    /// service teardown, including uniquely named test services.
    public func removeAllCredentials() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialVaultError.keychain(status)
        }
    }

    private func baseQuery(for reference: CredentialReference) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.rawValue.uuidString
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

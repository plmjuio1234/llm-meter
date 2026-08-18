import Foundation
import UsageCore

public enum ProviderFailure: Error, Equatable, Sendable {
    case authRequired
    case permissionDenied
    case rateLimited(retryAt: Date?)
    case offline
    case invalidResponse
    case unsupported
    case providerError(code: String?)
}

public protocol UsageProvider: Sendable {
    var provider: Provider { get }

    func fetch(
        connection: AccountConnection,
        credential: OAuthCredential,
        period: DateInterval,
        client: any ProviderHTTPClient
    ) async -> Result<UsageSnapshot, ProviderFailure>
}

public protocol ProviderHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionProviderHTTPClient: ProviderHTTPClient, @unchecked Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderFailure.invalidResponse
        }
        return (data, httpResponse)
    }
}

extension ProviderFailure {
    public var usageFailure: UsageFailure {
        switch self {
        case .authRequired: return .authRequired
        case .permissionDenied: return .permissionDenied
        case let .rateLimited(retryAt): return .rateLimited(retryAt: retryAt)
        case .offline: return .offline
        case .invalidResponse: return .invalidResponse
        case .unsupported: return .unsupported
        case let .providerError(code): return .providerError(code: code)
        }
    }
}

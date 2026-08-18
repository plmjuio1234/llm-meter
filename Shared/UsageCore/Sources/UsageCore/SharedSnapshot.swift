import Foundation

public enum SharedSnapshotError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case appGroupUnavailable(String)
}

/// Credential-free account projection consumed by the host and widget.
public struct SharedAccountSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let accountID: AccountID
    public let provider: Provider
    public let surface: Surface
    public let label: String
    public let isEnabled: Bool
    public let identity: AccountIdentity?
    public let usage: UsageSnapshot?

    public var id: AccountID { accountID }

    public init(
        accountID: AccountID,
        provider: Provider,
        surface: Surface,
        label: String,
        isEnabled: Bool,
        identity: AccountIdentity? = nil,
        usage: UsageSnapshot? = nil
    ) {
        self.accountID = accountID
        self.provider = provider
        self.surface = surface
        self.label = label
        self.isEnabled = isEnabled
        self.identity = identity
        self.usage = usage
    }
}

/// Versioned, sanitized App Group file payload. No credential fields are
/// present in this type by construction.
public struct SharedSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let accounts: [SharedAccountSnapshot]

    public init(generatedAt: Date, accounts: [SharedAccountSnapshot]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case accounts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw SharedSnapshotError.unsupportedSchemaVersion(version)
        }
        schemaVersion = version
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        accounts = try container.decode([SharedAccountSnapshot].self, forKey: .accounts)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(accounts, forKey: .accounts)
    }
}

import Foundation
import UsageCore

/// An opaque pointer to credential material held by the host application's vault.
/// This value is safe to persist; it never contains credential bytes.
public struct CredentialReference: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var description: String { rawValue.uuidString }
}

/// Host-owned connection metadata. Credential material is deliberately represented
/// only by an opaque Keychain reference.
public struct AccountConnection: Codable, Hashable, Sendable, Identifiable {
    public let id: AccountID
    public let provider: Provider
    public let surface: Surface
    public let label: String
    public let isEnabled: Bool
    public let identity: AccountIdentity?
    public let credentialReference: CredentialReference
    public let displayOrder: Int

    public init(
        id: AccountID = AccountID(),
        provider: Provider,
        surface: Surface,
        label: String,
        isEnabled: Bool = true,
        identity: AccountIdentity? = nil,
        credentialReference: CredentialReference,
        displayOrder: Int = 0
    ) {
        self.id = id
        self.provider = provider
        self.surface = surface
        self.label = label
        self.isEnabled = isEnabled
        self.identity = identity
        self.credentialReference = credentialReference
        self.displayOrder = displayOrder
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case surface
        case label
        case isEnabled
        case identity
        case credentialReference
        case displayOrder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AccountID.self, forKey: .id)
        provider = try container.decode(Provider.self, forKey: .provider)
        surface = try container.decode(Surface.self, forKey: .surface)
        label = try container.decode(String.self, forKey: .label)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        identity = try container.decodeIfPresent(AccountIdentity.self, forKey: .identity)
        credentialReference = try container.decode(CredentialReference.self, forKey: .credentialReference)
        displayOrder = try container.decodeIfPresent(Int.self, forKey: .displayOrder) ?? 0
    }

    func withDisplayOrder(_ displayOrder: Int) -> AccountConnection {
        AccountConnection(
            id: id,
            provider: provider,
            surface: surface,
            label: label,
            isEnabled: isEnabled,
            identity: identity,
            credentialReference: credentialReference,
            displayOrder: displayOrder
        )
    }
}

/// Non-secret values collected by account onboarding.
public struct AccountDraft: Hashable, Sendable {
    public let provider: Provider
    public let surface: Surface
    public let label: String
    public let isEnabled: Bool
    public let identity: AccountIdentity?

    public init(
        provider: Provider,
        surface: Surface,
        label: String,
        isEnabled: Bool = true,
        identity: AccountIdentity? = nil
    ) {
        self.provider = provider
        self.surface = surface
        self.label = label
        self.isEnabled = isEnabled
        self.identity = identity
    }
}

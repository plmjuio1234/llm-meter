import Foundation
import UsageCore

public enum AccountRegistryError: Error, Equatable, Sendable {
    case accountNotFound(AccountID)
    case emptyCredential
    case identityProviderMismatch
    case invalidDisplayOrder
    case persistence(String)
}

/// Serializes connection lifecycle changes while delegating secret persistence to
/// the host vault. Each connection owns exactly one credential reference.
public actor AccountRegistry {
    private var connections: [AccountID: AccountConnection]
    private let vault: any CredentialStoring
    private let persistenceURL: URL?
    private var hasLoadedPersistence = false

    public init(
        vault: any CredentialStoring,
        persistenceURL: URL? = nil,
        connections: [AccountConnection] = []
    ) {
        self.vault = vault
        self.persistenceURL = persistenceURL
        self.connections = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })
    }

    public func load() throws {
        guard !hasLoadedPersistence else { return }
        hasLoadedPersistence = true
        guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: persistenceURL)
            let loaded = try JSONDecoder().decode([AccountConnection].self, from: data)
            let migrated = Set(loaded.map(\.displayOrder)).count <= 1
                ? loaded.enumerated().map { $0.element.withDisplayOrder($0.offset) }
                : loaded
            connections = Dictionary(uniqueKeysWithValues: migrated.map { ($0.id, $0) })
        } catch {
            hasLoadedPersistence = false
            throw AccountRegistryError.persistence(error.localizedDescription)
        }
    }

    public func allConnections() -> [AccountConnection] {
        connections.values.sorted {
            if $0.displayOrder != $1.displayOrder {
                return $0.displayOrder < $1.displayOrder
            }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
    }

    public func connection(id: AccountID) -> AccountConnection? {
        connections[id]
    }

    @discardableResult
    public func add(_ draft: AccountDraft, credential: OAuthCredential) throws -> AccountConnection {
        try load()
        guard !credential.accessToken.isEmpty else { throw AccountRegistryError.emptyCredential }
        try validateIdentity(draft.identity, provider: draft.provider)

        let reference = CredentialReference()
        try vault.store(try credential.encoded(), reference: reference)
        let connection = AccountConnection(
            provider: draft.provider,
            surface: draft.surface,
            label: draft.label,
            isEnabled: draft.isEnabled,
            identity: draft.identity,
            credentialReference: reference,
            displayOrder: (connections.values.map(\.displayOrder).max() ?? -1) + 1
        )
        connections[connection.id] = connection
        do {
            try persist()
        } catch {
            connections.removeValue(forKey: connection.id)
            do {
                try vault.delete(reference)
            } catch {
                throw AccountRegistryError.persistence("Account rollback failed.")
            }
            throw error
        }
        return connection
    }

    @discardableResult
    public func edit(
        id: AccountID,
        label: String,
        surface: Surface,
        identity: AccountIdentity?
    ) throws -> AccountConnection {
        try load()
        guard let existing = connections[id] else { throw AccountRegistryError.accountNotFound(id) }
        try validateIdentity(identity, provider: existing.provider)
        let edited = AccountConnection(
            id: existing.id,
            provider: existing.provider,
            surface: surface,
            label: label,
            isEnabled: existing.isEnabled,
            identity: identity,
            credentialReference: existing.credentialReference,
            displayOrder: existing.displayOrder
        )
        connections[id] = edited
        do {
            try persist()
        } catch {
            connections[id] = existing
            throw error
        }
        return edited
    }

    @discardableResult
    public func disable(id: AccountID) throws -> AccountConnection {
        try load()
        guard let existing = connections[id] else { throw AccountRegistryError.accountNotFound(id) }
        let disabled = AccountConnection(
            id: existing.id,
            provider: existing.provider,
            surface: existing.surface,
            label: existing.label,
            isEnabled: false,
            identity: existing.identity,
            credentialReference: existing.credentialReference,
            displayOrder: existing.displayOrder
        )
        connections[id] = disabled
        do {
            try persist()
        } catch {
            connections[id] = existing
            throw error
        }
        return disabled
    }

    @discardableResult
    public func enable(id: AccountID) throws -> AccountConnection {
        try load()
        guard let existing = connections[id] else { throw AccountRegistryError.accountNotFound(id) }
        let enabled = AccountConnection(
            id: existing.id,
            provider: existing.provider,
            surface: existing.surface,
            label: existing.label,
            isEnabled: true,
            identity: existing.identity,
            credentialReference: existing.credentialReference,
            displayOrder: existing.displayOrder
        )
        connections[id] = enabled
        do {
            try persist()
        } catch {
            connections[id] = existing
            throw error
        }
        return enabled
    }

    @discardableResult
    public func remove(id: AccountID) throws -> AccountConnection {
        try load()
        guard let existing = connections[id] else { throw AccountRegistryError.accountNotFound(id) }
        // Keep registry metadata if Keychain deletion fails so the operation can be retried.
        let credential = try vault.credential(for: existing.credentialReference)
        try vault.delete(existing.credentialReference)
        connections.removeValue(forKey: id)
        do {
            try persist()
        } catch {
            connections[id] = existing
            do {
                try vault.store(credential, reference: existing.credentialReference)
            } catch {
                throw AccountRegistryError.persistence("Account rollback failed.")
            }
            throw error
        }
        return existing
    }

    public func reorder(ids: [AccountID]) throws {
        try load()
        guard ids.count == connections.count, Set(ids) == Set(connections.keys) else {
            throw AccountRegistryError.invalidDisplayOrder
        }
        let previous = connections
        connections = Dictionary(uniqueKeysWithValues: ids.enumerated().compactMap { index, id in
            guard let connection = previous[id] else { return nil }
            return (id, connection.withDisplayOrder(index))
        })
        do {
            try persist()
        } catch {
            connections = previous
            throw error
        }
    }

    private func persist() throws {
        guard let persistenceURL else { return }
        let data = try JSONEncoder().encode(allConnections())
        try FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: [.atomic])
    }

    private func validateIdentity(_ identity: AccountIdentity?, provider: Provider) throws {
        guard identity == nil || identity?.provider == provider else {
            throw AccountRegistryError.identityProviderMismatch
        }
    }
}

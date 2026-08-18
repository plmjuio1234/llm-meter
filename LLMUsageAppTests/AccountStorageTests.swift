import Foundation
import AppKit
import Security
import SwiftUI
import XCTest
import UsageCore
@testable import LLMUsageApp

final class AccountRegistryTests: XCTestCase {
    func testRegistryPersistsMetadataWithoutPersistingCredentialBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("accounts-\(UUID().uuidString)", isDirectory: true)
        let metadataURL = root.appendingPathComponent("accounts.json")
        let vault = MemoryCredentialVault()
        let firstRegistry = AccountRegistry(vault: vault, persistenceURL: metadataURL)

        let connection = try await firstRegistry.add(
            AccountDraft(provider: .anthropic, surface: .consumerSubscription, label: "Persisted"),
            credential: OAuthCredential(
                accessToken: "persisted-oauth-token",
                refreshToken: "persisted-refresh-token"
            )
        )

        let secondRegistry = AccountRegistry(vault: vault, persistenceURL: metadataURL)
        try await secondRegistry.load()
        let loaded = await secondRegistry.connection(id: connection.id)
        XCTAssertEqual(loaded, connection)
        let metadata = try Data(contentsOf: metadataURL)
        XCTAssertNil(metadata.range(of: Data("persisted-secret".utf8)))
    }

    func testRegistrySupportsMultipleConnectionsWithoutFixedLimit() async throws {
        let vault = MemoryCredentialVault()
        let registry = AccountRegistry(vault: vault)

        for index in 0..<5 {
            _ = try await registry.add(
                AccountDraft(
                    provider: .openAI,
                    surface: .consumerSubscription,
                    label: "Account \(index)"
                ),
                credential: OAuthCredential(accessToken: "token-\(index)")
            )
        }

        let connections = await registry.allConnections()
        XCTAssertEqual(connections.count, 5)
        XCTAssertEqual(Set(connections.map(\.label)), Set((0..<5).map { "Account \($0)" }))
    }

    func testRegistryPersistsCustomDisplayOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ordered-accounts-\(UUID().uuidString)", isDirectory: true)
        let metadataURL = root.appendingPathComponent("accounts.json")
        let vault = MemoryCredentialVault()
        let registry = AccountRegistry(vault: vault, persistenceURL: metadataURL)
        let first = try await registry.add(
            AccountDraft(provider: .openAI, surface: .api, label: "First"),
            credential: OAuthCredential(accessToken: "first")
        )
        let second = try await registry.add(
            AccountDraft(provider: .openAI, surface: .api, label: "Second"),
            credential: OAuthCredential(accessToken: "second")
        )
        let third = try await registry.add(
            AccountDraft(provider: .openAI, surface: .api, label: "Third"),
            credential: OAuthCredential(accessToken: "third")
        )

        try await registry.reorder(ids: [third.id, first.id, second.id])
        let ordered = await registry.allConnections()
        XCTAssertEqual(ordered.map(\.label), ["Third", "First", "Second"])

        let reloaded = AccountRegistry(vault: vault, persistenceURL: metadataURL)
        try await reloaded.load()
        let reloadedOrder = await reloaded.allConnections()
        XCTAssertEqual(reloadedOrder.map(\.label), ["Third", "First", "Second"])
    }

    @MainActor
    func testDashboardMoveAccountUpdatesAndPersistsSnapshotOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashboard-order-\(UUID().uuidString)", isDirectory: true)
        let store = SnapshotStore(containerURL: root)
        let vault = MemoryCredentialVault()
        let registry = AccountRegistry(vault: vault)
        let first = try await registry.add(
            AccountDraft(provider: .openAI, surface: .api, label: "First"),
            credential: OAuthCredential(accessToken: "first")
        )
        let second = try await registry.add(
            AccountDraft(provider: .openAI, surface: .api, label: "Second"),
            credential: OAuthCredential(accessToken: "second")
        )
        try await store.write(
            SharedSnapshot(
                generatedAt: .now,
                accounts: [
                    SharedAccountSnapshot(connection: first),
                    SharedAccountSnapshot(connection: second)
                ]
            )
        )
        let coordinator = RefreshCoordinator(
            registry: registry,
            vault: vault,
            snapshotStore: store,
            providers: [:],
            client: URLSessionProviderHTTPClient(),
            reloadTimelines: {}
        )
        let model = DashboardModel(
            registry: registry,
            coordinator: coordinator,
            snapshotStore: store
        )
        await model.load()

        XCTAssertFalse(model.isReorderingAccounts)
        model.toggleAccountReordering()
        XCTAssertTrue(model.isReorderingAccounts)
        await model.moveAccount(second.id, by: -1)

        XCTAssertEqual(model.snapshot.accounts.map(\.accountID), [second.id, first.id])
        let stored = try await store.read()
        XCTAssertEqual(stored.accounts.map(\.accountID), [second.id, first.id])
    }

    @MainActor
    func testDashboardReorderControlsRenderInsideAccountCards() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashboard-controls-\(UUID().uuidString)", isDirectory: true)
        let store = SnapshotStore(containerURL: root)
        let vault = FixtureCredentialStore()
        let registry = AccountRegistry(vault: vault)
        try await FixtureData.install(registry: registry, snapshotStore: store)
        let coordinator = RefreshCoordinator(
            registry: registry,
            vault: vault,
            snapshotStore: store,
            providers: [:],
            client: URLSessionProviderHTTPClient(),
            reloadTimelines: {}
        )
        let model = DashboardModel(
            registry: registry,
            coordinator: coordinator,
            snapshotStore: store
        )
        await model.load()
        model.toggleAccountReordering()

        let hostingView = NSHostingView(rootView: MenuBarDashboardView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.frame = window.contentView?.bounds ?? .zero
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        XCTAssertNotNil(bitmap)
        if let bitmap {
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            let imageData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(imageData.count, 1_000)
            try imageData.write(to: URL(fileURLWithPath: "/tmp/llmusage-reorder-render.png"))
        }
        window.orderOut(nil)
    }

    func testEditDisableAndRemoveRemainIsolatedToSelectedConnection() async throws {
        let vault = MemoryCredentialVault()
        let registry = AccountRegistry(vault: vault)
        let firstCredential = OAuthCredential(
            accessToken: "first-oauth-token",
            refreshToken: "first-refresh-token"
        )
        let secondCredential = OAuthCredential(
            accessToken: "second-oauth-token",
            refreshToken: "second-refresh-token"
        )

        let first = try await registry.add(
            AccountDraft(provider: .openAI, surface: .consumerSubscription, label: "Primary"),
            credential: firstCredential
        )
        let second = try await registry.add(
            AccountDraft(provider: .openAI, surface: .consumerSubscription, label: "Secondary"),
            credential: secondCredential
        )

        let edited = try await registry.edit(
            id: first.id,
            label: "Renamed",
            surface: .consumerSubscription,
            identity: AccountIdentity(
                provider: .openAI,
                remotePrincipalID: "account-one",
                scope: .account("account-one")
            )
        )
        XCTAssertEqual(edited.credentialReference, first.credentialReference)
        XCTAssertEqual(edited.label, "Renamed")
        XCTAssertEqual(
            try OAuthCredential.decode(vault.credential(for: first.credentialReference)),
            firstCredential
        )
        XCTAssertEqual(
            try OAuthCredential.decode(vault.credential(for: second.credentialReference)),
            secondCredential
        )

        let disabled = try await registry.disable(id: first.id)
        let unaffectedAfterDisable = await registry.connection(id: second.id)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertTrue(try XCTUnwrap(unaffectedAfterDisable).isEnabled)

        try await registry.remove(id: first.id)
        let removedConnection = await registry.connection(id: first.id)
        let remainingConnection = await registry.connection(id: second.id)
        XCTAssertNil(removedConnection)
        XCTAssertNotNil(remainingConnection)
        XCTAssertThrowsError(try vault.credential(for: first.credentialReference))
        XCTAssertEqual(
            try OAuthCredential.decode(vault.credential(for: second.credentialReference)),
            secondCredential
        )
    }
}

final class CredentialVaultTests: XCTestCase {
    func testKeychainRoundTripAndDelete() throws {
        let service = "local.llmusage.tests.\(UUID().uuidString)"
        let vault = CredentialVault(service: service)
        defer { try? vault.removeAllCredentials() }
        let reference = CredentialReference()
        let credential = Data("keychain-round-trip-secret".utf8)

        try vault.store(credential, reference: reference)
        XCTAssertEqual(try vault.credential(for: reference), credential)

        try vault.delete(reference)
        XCTAssertThrowsError(try vault.credential(for: reference)) { error in
            XCTAssertEqual(error as? CredentialVaultError, .keychain(errSecItemNotFound))
        }
    }
}

final class SharedSnapshotTests: XCTestCase {
    func testMalformedAndUnsupportedVersionsAreRejected() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(SharedSnapshot.self, from: Data("not-json".utf8)))

        let unsupported = Data("{\"schemaVersion\":99}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SharedSnapshot.self, from: unsupported)) { error in
            XCTAssertEqual(error as? SharedSnapshotError, .unsupportedSchemaVersion(99))
        }
    }

    func testAtomicStoreWriteAndRead() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(containerURL: directory)
        let snapshot = makeSnapshot(label: "Stored")

        try await store.write(snapshot)
        let storedSnapshot = try await store.read()
        let fileURL = await store.fileURL

        XCTAssertEqual(storedSnapshot, snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSerializedSnapshotContainsNoCredentialBytesOrCredentialFields() async throws {
        let secret = "credential-oai-test-\(UUID().uuidString)"
        let registry = AccountRegistry(vault: MemoryCredentialVault())
        let connection = try await registry.add(
            AccountDraft(
                provider: .openAI,
                surface: .consumerSubscription,
                label: "Safe label",
                identity: AccountIdentity(
                    provider: .openAI,
                    remotePrincipalID: "principal-123",
                    scope: .organization("org-123")
                )
            ),
            credential: OAuthCredential(accessToken: secret)
        )
        let snapshot = SharedSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            accounts: [SharedAccountSnapshot(connection: connection)]
        )

        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertNil(encoded.range(of: Data(secret.utf8)))
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8)).lowercased()
        for forbiddenField in ["credential", "token", "cookie", "secret", "authorization"] {
            XCTAssertFalse(json.contains(forbiddenField), "Found forbidden serialized field: \(forbiddenField)")
        }
    }

    private func makeSnapshot(label: String) -> SharedSnapshot {
        SharedSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            accounts: [
                SharedAccountSnapshot(
                    accountID: AccountID(),
                    provider: .anthropic,
                    surface: .api,
                    label: label,
                    isEnabled: true
                )
            ]
        )
    }
}

private final class MemoryCredentialVault: CredentialStoring, @unchecked Sendable {
    private enum Error: Swift.Error { case missing }
    private let lock = NSLock()
    private var credentials: [CredentialReference: Data] = [:]

    func store(_ credential: Data, reference: CredentialReference) throws {
        lock.withLock { credentials[reference] = credential }
    }

    func credential(for reference: CredentialReference) throws -> Data {
        try lock.withLock {
            guard let credential = credentials[reference] else { throw Error.missing }
            return credential
        }
    }

    func delete(_ reference: CredentialReference) throws {
        _ = lock.withLock { credentials.removeValue(forKey: reference) }
    }
}

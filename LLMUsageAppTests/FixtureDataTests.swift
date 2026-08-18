import Foundation
import XCTest
@testable import LLMUsageApp

final class FixtureDataTests: XCTestCase {
    func testFixtureDataProducesFreshStaleAndCredentialFreeSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
        let store = SnapshotStore(containerURL: root)
        let registry = AccountRegistry(vault: FixtureCredentialStore())

        try await FixtureData.install(
            registry: registry,
            snapshotStore: store
        )

        let fileURL = await store.fileURL
        let data = try Data(contentsOf: fileURL)
        let snapshot = try await store.read()
        XCTAssertEqual(snapshot.accounts.count, 2)
        XCTAssertTrue(snapshot.accounts.contains { $0.usage?.freshness.state == .fresh })
        XCTAssertTrue(snapshot.accounts.contains { $0.usage?.freshness.state == .stale })
        XCTAssertNil(data.range(of: Data("fixture-openai-secret".utf8)))
        XCTAssertNil(data.range(of: Data("fixture-anthropic-secret".utf8)))
    }
}

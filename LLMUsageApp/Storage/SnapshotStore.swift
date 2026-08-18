import Foundation

/// Actor-isolated atomic storage for the App Group's sanitized snapshot file.
public actor SnapshotStore {
    public static let defaultFilename = "usage-snapshot.json"

    public let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        containerURL: URL,
        filename: String = SnapshotStore.defaultFilename,
        fileManager: FileManager = .default
    ) {
        self.fileURL = containerURL.appendingPathComponent(filename, isDirectory: false)
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
    }

    public init(
        appGroupIdentifier: String,
        filename: String = SnapshotStore.defaultFilename,
        fileManager: FileManager = .default
    ) throws {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw SharedSnapshotError.appGroupUnavailable(appGroupIdentifier)
        }
        self.fileURL = containerURL.appendingPathComponent(filename, isDirectory: false)
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func write(_ snapshot: SharedSnapshot) throws {
        let data = try encoder.encode(snapshot)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }

    public func read() throws -> SharedSnapshot {
        try decoder.decode(SharedSnapshot.self, from: Data(contentsOf: fileURL))
    }
}

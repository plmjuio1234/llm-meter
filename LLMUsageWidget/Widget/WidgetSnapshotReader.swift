import Foundation
import UsageCore

struct WidgetSnapshotReader {
    private let fileManager: FileManager
    private let filename = "usage-snapshot.json"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func read() -> SharedSnapshot? {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: "group.local.llmusage.shared"
        ) else {
            return nil
        }
        let url = container.appendingPathComponent(filename, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SharedSnapshot.self, from: data)
    }
}

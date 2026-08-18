import UsageCore

public typealias SharedSnapshot = UsageCore.SharedSnapshot
public typealias SharedAccountSnapshot = UsageCore.SharedAccountSnapshot
public typealias SharedSnapshotError = UsageCore.SharedSnapshotError

public extension SharedAccountSnapshot {
    init(connection: AccountConnection, usage: UsageSnapshot? = nil) {
        self.init(
            accountID: connection.id,
            provider: connection.provider,
            surface: connection.surface,
            label: connection.label,
            isEnabled: connection.isEnabled,
            identity: connection.identity,
            usage: usage
        )
    }
}

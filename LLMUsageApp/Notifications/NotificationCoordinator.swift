import Foundation
import UserNotifications
import UsageCore

public struct UsageNotification: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String

    public init(identifier: String, title: String, body: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
    }
}

public protocol NotificationDelivering: Sendable {
    func requestAuthorization() async throws
    func deliver(_ notification: UsageNotification) async throws
}

public struct UserNotificationDeliverer: NotificationDelivering, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func requestAuthorization() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    public func deliver(_ notification: UsageNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }
}

/// Emits only threshold transitions and auth failures from fresh provider data.
public actor NotificationCoordinator {
    private let deliverer: any NotificationDelivering
    private var priorThresholds: [String: Int] = [:]
    private var deliveredAuthFailures: Set<String> = []

    public init(deliverer: any NotificationDelivering) {
        self.deliverer = deliverer
    }

    public func requestAuthorization() async throws {
        try await deliverer.requestAuthorization()
    }

    @discardableResult
    public func process(_ snapshot: SharedSnapshot) async throws -> [UsageNotification] {
        var notifications: [UsageNotification] = []

        for account in snapshot.accounts where account.isEnabled {
            guard let usage = account.usage else { continue }
            let accountPrefix = account.accountID.rawValue.uuidString

            let authIdentifier = "\(accountPrefix)-auth-required"
            switch usage.failure {
            case .authRequired:
                if deliveredAuthFailures.insert(authIdentifier).inserted {
                    let notification = UsageNotification(
                        identifier: authIdentifier,
                        title: "\(account.label) needs authentication",
                        body: "Reconnect this API account to resume usage updates."
                    )
                    try await deliverer.deliver(notification)
                    notifications.append(notification)
                }
            default:
                deliveredAuthFailures.remove(authIdentifier)
            }

            guard usage.failure == nil, usage.freshness.state == .fresh else { continue }
            for metric in usage.metrics {
                guard metric.sourceQuality == .providerReported,
                      let utilization = metric.utilization else {
                    continue
                }

                let threshold: Int?
                if utilization >= Decimal(string: "0.95")! {
                    threshold = 95
                } else if utilization >= Decimal(string: "0.80")! {
                    threshold = 80
                } else {
                    threshold = nil
                }
                let key = "\(accountPrefix)-\(metric.key)-\(String(describing: metric.period))"
                let previous = priorThresholds[key] ?? 0
                priorThresholds[key] = threshold ?? 0
                guard let threshold, threshold > previous else { continue }

                let notification = UsageNotification(
                    identifier: "\(key)-\(threshold)",
                    title: "\(account.label) usage reached \(threshold)%",
                    body: "\(metric.key) crossed the provider-reported \(threshold)% threshold."
                )
                try await deliverer.deliver(notification)
                notifications.append(notification)
            }
        }

        return notifications
    }
}

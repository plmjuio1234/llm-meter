import Foundation
import SwiftUI
import UsageCore
import WidgetKit

@MainActor
final class AppContainer: ObservableObject {
    let vault: any CredentialStoring
    let registry: AccountRegistry
    let snapshotStore: SnapshotStore
    let coordinator: RefreshCoordinator
    let dashboard: DashboardModel
    let notificationCoordinator: NotificationCoordinator

    init() {
        let fixtureMode = CommandLine.arguments.contains("--fixture-data")
        let vault: any CredentialStoring = fixtureMode
            ? FixtureCredentialStore()
            : CredentialVault(service: "local.llmusage.credentials")
        let containerURL = Self.makeContainerURL()
        let snapshotContainerURL = fixtureMode
            ? containerURL.appendingPathComponent("Fixture", isDirectory: true)
            : containerURL
        let registry = AccountRegistry(
            vault: vault,
            persistenceURL: fixtureMode
                ? nil
                : containerURL.appendingPathComponent("accounts.json", isDirectory: false)
        )
        let snapshotStore = SnapshotStore(containerURL: snapshotContainerURL)
        let providers: [Provider: any UsageProvider] = [
            .openAI: OpenAIUsageProvider(),
            .anthropic: AnthropicUsageProvider(),
            .moonshot: MoonshotUsageProvider(),
            .moonshotChina: MoonshotUsageProvider(
                provider: .moonshotChina,
                baseURL: URL(string: "https://api.moonshot.cn")!
            ),
            .deepSeek: DeepSeekUsageProvider(),
            .openRouter: OpenRouterUsageProvider(),
            .zhipu: UnsupportedUsageProvider(provider: .zhipu),
            .miniMax: UnsupportedUsageProvider(provider: .miniMax),
            .qwen: UnsupportedUsageProvider(provider: .qwen)
        ]
        let notificationCoordinator = NotificationCoordinator(
            deliverer: UserNotificationDeliverer()
        )
        let coordinator = RefreshCoordinator(
            registry: registry,
            vault: vault,
            snapshotStore: snapshotStore,
            providers: providers,
            client: URLSessionProviderHTTPClient(),
            reloadTimelines: {
                Task { @MainActor in
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        )

        self.vault = vault
        self.registry = registry
        self.snapshotStore = snapshotStore
        self.coordinator = coordinator
        self.notificationCoordinator = notificationCoordinator
        self.dashboard = DashboardModel(
            registry: registry,
            coordinator: coordinator,
            snapshotStore: snapshotStore,
            notificationCoordinator: notificationCoordinator,
            fixtureMode: fixtureMode
        )

        Task { @MainActor in
            if fixtureMode {
                await dashboard.installFixtures()
            }
            do {
                try await notificationCoordinator.requestAuthorization()
            } catch {
                dashboard.recordError("Notification permission is unavailable.")
            }
        }
    }

    private static func makeContainerURL() -> URL {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.local.llmusage.shared"
        ) {
            return container
        }

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("LLMUsage", isDirectory: true)
    }
}

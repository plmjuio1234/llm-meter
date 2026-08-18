import SwiftUI

@main
struct LLMUsageApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        MenuBarExtra("LLM Usage", systemImage: "chart.bar") {
            MenuBarDashboardView(model: container.dashboard)
        }
        .menuBarExtraStyle(.window)
    }
}

import AppIntents
import Foundation
import SwiftUI
import UsageCore
import WidgetKit

struct WidgetAccountIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Account"
    static let description = IntentDescription("Choose one sanitized account snapshot.")

    @Parameter(title: "Account ID")
    var accountID: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$accountID)")
    }
}

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let selectedAccount: SharedAccountSnapshot?
    let hasSnapshot: Bool
}

struct UsageWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(date: .now, selectedAccount: nil, hasSnapshot: false)
    }

    func snapshot(
        for configuration: WidgetAccountIntent,
        in context: Context
    ) async -> UsageWidgetEntry {
        makeEntry(for: configuration)
    }

    func timeline(
        for configuration: WidgetAccountIntent,
        in context: Context
    ) async -> Timeline<UsageWidgetEntry> {
        let entry = makeEntry(for: configuration)
        return Timeline(
            entries: [entry],
            policy: .after(Date().addingTimeInterval(15 * 60))
        )
    }

    private func makeEntry(for configuration: WidgetAccountIntent) -> UsageWidgetEntry {
        let snapshot = WidgetSnapshotReader().read()
        let selected = configuration.accountID?.isEmpty != false
            ? nil
            : snapshot?.accounts.first {
                $0.accountID.rawValue.uuidString.lowercased() == configuration.accountID?.lowercased()
            }
        return UsageWidgetEntry(
            date: snapshot?.generatedAt ?? .now,
            selectedAccount: selected,
            hasSnapshot: snapshot != nil
        )
    }
}

struct UsageWidgetView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let account = entry.selectedAccount {
                if let usage = account.usage {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.label)
                                .font(.headline)
                                .lineLimit(1)
                            Text(providerLabel(account.provider))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(stateLabel(usage))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(usage.failure == nil ? .green : .orange)
                    }
                    if let metric = WidgetQuotaPresentation.primaryMetric(
                        for: usage,
                        provider: account.provider
                    ) {
                        WidgetQuotaGauge(
                            title: quotaTitle(for: account.provider),
                            metric: metric
                        )
                    } else {
                        Text("Primary quota unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(account.label)
                        .font(.headline)
                        .lineLimit(1)
                    Text("no_data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if entry.hasSnapshot {
                Text("Choose an account")
                    .font(.headline)
                Text("Edit the widget to select a sanitized account snapshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No usage snapshot")
                    .font(.headline)
                Text("Open the menu-bar app to connect an account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
            .padding()
            .containerBackground(.ultraThinMaterial, for: .widget)
    }

    private func providerLabel(_ provider: Provider) -> String {
        switch provider {
        case .openAI: return "GPT"
        case .anthropic: return "Claude"
        case .moonshot: return "Kimi"
        case .moonshotChina: return "Kimi China"
        case .deepSeek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        case .zhipu: return "GLM"
        case .miniMax: return "MiniMax"
        case .qwen: return "Qwen"
        case let .other(value): return value
        }
    }

    private func quotaTitle(for provider: Provider) -> String {
        switch provider {
        case .openAI: return "GPT quota"
        case .moonshot, .moonshotChina, .deepSeek: return "Balance"
        case .openRouter: return "API usage"
        default: return "Quota"
        }
    }

    private func stateLabel(_ usage: UsageSnapshot) -> String {
        if let failure = usage.failure {
            switch failure {
            case .authRequired:
                return "Sign in"
            case .permissionDenied:
                return "Denied"
            case .rateLimited:
                return "Limited"
            case .offline:
                return "Offline"
            case .providerError:
                return "Error"
            case .invalidResponse:
                return "Changed"
            case .unsupported:
                return "Unsupported"
            case .partial:
                return "Partial"
            case .noData:
                return "No data"
            }
        }
        return usage.freshness.state.rawValue
    }
}

private enum WidgetQuotaPresentation {
    static func primaryMetric(
        for usage: UsageSnapshot,
        provider: Provider
    ) -> UsageMetric? {
        switch provider {
        case .openAI:
            return usage.metrics.first { $0.key == "openai.oauth.rate_limit.primary" }
        case .anthropic:
            return usage.metrics.first { $0.key == "anthropic.oauth.rate_limit.five_hour" }
                ?? usage.metrics.first { $0.key == "anthropic.oauth.rate_limit.seven_day" }
        case .moonshot, .moonshotChina:
            return usage.metrics.first { $0.key == "moonshot.api.balance.available" }
        case .deepSeek:
            return usage.metrics.first { $0.key == "deepseek.api.balance.usd.total" }
                ?? usage.metrics.first { $0.key.hasSuffix(".total") }
        case .openRouter:
            return usage.metrics.first { $0.key == "openrouter.api.key.usage" }
        case .zhipu, .miniMax, .qwen:
            return nil
        case .other:
            return usage.metrics.first
        }
    }

    static func remainingFraction(for metric: UsageMetric) -> Double? {
        guard let utilization = metric.utilization else { return nil }
        let used = NSDecimalNumber(decimal: utilization).doubleValue
        guard used.isFinite else { return nil }
        return min(max(1 - used, 0), 1)
    }
}

private struct WidgetQuotaGauge: View {
    let title: String
    let metric: UsageMetric

    private var remainingFraction: Double? {
        WidgetQuotaPresentation.remainingFraction(for: metric)
    }

    private var remainingPercent: Int? {
        remainingFraction.map { Int(($0 * 100).rounded()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                if let remainingPercent {
                    Text("\(remainingPercent)%")
                        .font(.title3.weight(.bold).monospacedDigit())
                }
            }

            Group {
                if let remainingFraction {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.10))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: gaugeColors(for: remainingFraction),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(
                                    width: max(10, geometry.size.width * remainingFraction)
                                )
                        }
                    }
                    .frame(height: 8)
                } else if let displayValue {
                    Text(displayValue)
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
            }

            if case let .at(resetAt, _) = metric.reset {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("Resets")
                    Text(resetAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                "\(title), \(remainingPercent.map { "\($0) percent remaining" } ?? displayValue ?? "value unavailable")"
            )
        )
    }

    private var displayValue: String? {
        guard let value = metric.value.decimalString?.rawValue else { return nil }
        switch metric.unit {
        case let .currency(code):
            return "\(code) \(value)"
        case let .count(unit):
            return "\(value) \(unit)"
        case .ratio:
            return value
        }
    }

    private func gaugeColors(for remainingFraction: Double) -> [Color] {
        switch remainingFraction {
        case 0..<0.25:
            return [.orange, .red]
        case 0..<0.55:
            return [.yellow, .orange]
        default:
            return [.green, .mint]
        }
    }
}

struct LLMUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "LLMUsageWidget",
            intent: WidgetAccountIntent.self,
            provider: UsageWidgetProvider()
        ) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("LLM Usage")
        .description("Usage snapshots from connected API accounts.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct LLMUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        LLMUsageWidget()
    }
}

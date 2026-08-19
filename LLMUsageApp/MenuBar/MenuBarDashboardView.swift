import Foundation
import SwiftUI
import UsageCore

@MainActor
public final class DashboardModel: ObservableObject {
    @Published public private(set) var snapshot: SharedSnapshot
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var isReorderingAccounts = false

    public let registry: AccountRegistry
    public let coordinator: RefreshCoordinator
    private let snapshotStore: SnapshotStore
    private let notificationCoordinator: NotificationCoordinator?
    private let oauthLinker: OAuthAccountLinker
    public let fixtureMode: Bool
    private var fixtureInstalled = false

    public init(
        registry: AccountRegistry,
        coordinator: RefreshCoordinator,
        snapshotStore: SnapshotStore,
        notificationCoordinator: NotificationCoordinator? = nil,
        oauthLinker: OAuthAccountLinker = OAuthAccountLinker(),
        fixtureMode: Bool = false
    ) {
        self.registry = registry
        self.coordinator = coordinator
        self.snapshotStore = snapshotStore
        self.notificationCoordinator = notificationCoordinator
        self.oauthLinker = oauthLinker
        self.fixtureMode = fixtureMode
        self.snapshot = SharedSnapshot(generatedAt: .now, accounts: [])
    }

    public func recordError(_ message: String) {
        lastError = message
    }

    public func toggleAccountReordering() {
        isReorderingAccounts.toggle()
    }

    public func load() async {
        do {
            try await registry.load()
        } catch {
            lastError = "Saved account connections could not be loaded."
            return
        }
        do {
            snapshot = try await snapshotStore.read()
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            lastError = "The shared usage snapshot is invalid or unavailable."
        }
    }

    public func prepare() async {
        await load()
        await installFixtures()
        await load()
    }

    public func installFixtures() async {
        guard fixtureMode, !fixtureInstalled else { return }
        do {
            try await FixtureData.install(
                registry: registry,
                snapshotStore: snapshotStore
            )
            fixtureInstalled = true
            await load()
        } catch {
            lastError = "Fixture data could not be installed."
        }
    }

    public func refresh(trigger: RefreshTrigger = .manual) async {
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        if fixtureMode {
            await load()
            if let notificationCoordinator {
                do {
                    _ = try await notificationCoordinator.process(snapshot)
                } catch {
                    lastError = "Usage notifications could not be delivered."
                }
            }
            return
        }

        do {
            let end = Date()
            let period = DateInterval(
                start: end.addingTimeInterval(-7 * 24 * 60 * 60),
                end: end
            )
            _ = try await coordinator.refresh(period: period, trigger: trigger)
            await load()
            if let notificationCoordinator {
                do {
                    _ = try await notificationCoordinator.process(snapshot)
                } catch {
                    lastError = "Usage notifications could not be delivered."
                }
            }
        } catch {
            lastError = "Unable to write the shared usage snapshot."
        }
    }

    public func addOAuthAccount(provider: Provider, label: String?) async throws {
        let link = try await oauthLinker.link(provider: provider)
        let draft: AccountDraft
        if let label, !label.isEmpty {
            draft = AccountDraft(
                provider: link.draft.provider,
                surface: link.draft.surface,
                label: label,
                isEnabled: link.draft.isEnabled,
                identity: link.draft.identity
            )
        } else {
            draft = link.draft
        }
        _ = try await registry.add(draft, credential: link.credential)
        await refresh()
    }

    public func addAPIKeyAccount(
        provider: Provider,
        apiKey: String,
        label: String?
    ) async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AccountRegistryError.emptyCredential
        }
        let providerLabel = AccountDetailPresentation.providerLabel(provider)
        let requestedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = AccountDraft(
            provider: provider,
            surface: .api,
            label: requestedLabel.flatMap { $0.isEmpty ? nil : $0 } ?? providerLabel
        )
        _ = try await registry.add(
            draft,
            credential: OAuthCredential.apiKey(trimmedKey)
        )
        await refresh()
    }

    public func edit(
        connection: AccountConnection,
        label: String,
        surface: Surface,
        identity: AccountIdentity?
    ) async throws {
        _ = try await registry.edit(
            id: connection.id,
            label: label,
            surface: surface,
            identity: identity
        )
        await load()
    }

    public func setEnabled(_ enabled: Bool, for connection: AccountConnection) async throws {
        if enabled {
            _ = try await registry.enable(id: connection.id)
        } else {
            _ = try await registry.disable(id: connection.id)
        }
        await load()
    }

    public func remove(_ connection: AccountConnection) async throws {
        _ = try await registry.remove(id: connection.id)
        await load()
    }

    public func moveAccount(_ accountID: AccountID, by offset: Int) async {
        var accounts = snapshot.accounts
        guard let index = accounts.firstIndex(where: { $0.accountID == accountID }) else { return }
        let destination = index + offset
        guard accounts.indices.contains(destination) else { return }
        accounts.swapAt(index, destination)

        do {
            try await registry.reorder(ids: accounts.map(\.accountID))
            let reorderedSnapshot = SharedSnapshot(generatedAt: .now, accounts: accounts)
            try await snapshotStore.write(reorderedSnapshot)
            snapshot = reorderedSnapshot
        } catch {
            lastError = "Unable to change account order."
        }
    }

    public func aggregate(provider: Provider, metricKey: String) -> UsageAggregate? {
        let inputs = snapshot.accounts.compactMap { account -> AggregateInput? in
            guard account.provider == provider,
                  let usage = account.usage,
                  let metric = usage.metrics.first(where: { $0.key == metricKey }) else {
                return nil
            }
            return AggregateInput(
                accountID: account.accountID,
                provider: account.provider,
                metric: metric
            )
        }
        guard inputs.count > 1 else { return nil }
        return try? UsageAggregator.aggregate(inputs).get()
    }
}

public struct MenuBarDashboardView: View {
    @ObservedObject private var model: DashboardModel
    @State private var showingOnboarding = false
    @State private var editingAccount: SharedAccountSnapshot?
    @State private var detailAccount: SharedAccountSnapshot?

    public init(model: DashboardModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LLM Usage")
                    .font(.headline)
                Spacer()
                Button {
                    showingOnboarding = true
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                if model.snapshot.accounts.count > 1 {
                    Button {
                        model.toggleAccountReordering()
                    } label: {
                        Label(
                            model.isReorderingAccounts ? "Done" : "Reorder",
                            systemImage: model.isReorderingAccounts ? "checkmark" : "arrow.up.arrow.down"
                        )
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: model.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
            }
            HStack(spacing: 8) {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
                Text("Launch at login")
                    .font(.caption)
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { LaunchAtLoginController.isEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(DashboardPalette.border)
            }

            if !model.snapshot.accounts.isEmpty {
                DashboardQuickStatusView(
                    snapshot: model.snapshot,
                    isRefreshing: model.isRefreshing
                )
            }

            if model.snapshot.accounts.isEmpty {
                ContentUnavailableView(
                    "No accounts",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Connect an OAuth account to begin.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.snapshot.accounts.enumerated()), id: \.element.accountID) { index, account in
                            AccountSnapshotCard(
                                account: account,
                                isReordering: model.isReorderingAccounts,
                                canMoveUp: index > 0,
                                canMoveDown: index < model.snapshot.accounts.count - 1,
                                onMove: { offset in
                                    Task { await model.moveAccount(account.accountID, by: offset) }
                                },
                                onDetail: { detailAccount = account },
                                onEdit: { editingAccount = account },
                                onToggle: {
                                    Task {
                                        if let connection = await model.registry.connection(id: account.accountID) {
                                            do {
                                                try await model.setEnabled(!account.isEnabled, for: connection)
                                            } catch {
                                                model.recordError("Unable to change account state.")
                                            }
                                        }
                                    }
                                },
                                onRemove: {
                                    Task {
                                        if let connection = await model.registry.connection(id: account.accountID) {
                                            do {
                                                try await model.remove(connection)
                                            } catch {
                                                model.recordError("Unable to remove account.")
                                            }
                                        }
                                    }
                                }
                            )
                        }
                    }
                }
            }

            if let lastError = model.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 260)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        }
        .task {
            await model.prepare()
            if !model.fixtureMode {
                await model.refresh(trigger: .launch)
            }
        }
        .sheet(item: $detailAccount) { account in
            AccountDetailView(account: account)
        }
        .overlay {
            if showingOnboarding {
                AccountOnboardingView(
                    onCancel: { showingOnboarding = false }
                ) { provider, label in
                    try await model.addOAuthAccount(provider: provider, label: label)
                    showingOnboarding = false
                } apiKeyAction: { provider, apiKey, label in
                    try await model.addAPIKeyAccount(
                        provider: provider,
                        apiKey: apiKey,
                        label: label
                    )
                    showingOnboarding = false
                }
                .padding()
                .frame(width: 360)
                .frame(minHeight: 240)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 12)
            } else if let account = editingAccount {
                AccountEditView(
                    account: account,
                    onCancel: { editingAccount = nil }
                ) { label in
                    if let connection = await model.registry.connection(id: account.accountID) {
                        try await model.edit(
                            connection: connection,
                            label: label,
                            surface: connection.surface,
                            identity: connection.identity
                        )
                    }
                    editingAccount = nil
                }
                .padding()
                .frame(width: 320)
                .frame(minHeight: 160)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 12)
            }
        }
    }

}

private extension DashboardModel {
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginController.setEnabled(enabled)
        } catch {
            recordError("Unable to change launch-at-login setting.")
        }
    }
}

private enum DashboardPalette {
    static let border = Color.white.opacity(0.24)
    static let track = Color.primary.opacity(0.10)
}

enum DashboardQuickStatusState: Equatable {
    case empty
    case noActiveAccounts
    case healthy
    case attention
}

struct DashboardQuickStatus: Equatable {
    let totalAccounts: Int
    let activeAccounts: Int
    let healthyAccounts: Int
    let attentionAccounts: Int
    let disabledAccounts: Int

    init(snapshot: SharedSnapshot) {
        totalAccounts = snapshot.accounts.count
        activeAccounts = snapshot.accounts.filter(\.isEnabled).count
        disabledAccounts = snapshot.accounts.filter { !$0.isEnabled }.count
        healthyAccounts = snapshot.accounts.filter { account in
            guard account.isEnabled, let usage = account.usage else { return false }
            return usage.failure == nil && usage.freshness.state == .fresh
        }.count
        attentionAccounts = activeAccounts - healthyAccounts
    }

    var state: DashboardQuickStatusState {
        if totalAccounts == 0 { return .empty }
        if activeAccounts == 0 { return .noActiveAccounts }
        return attentionAccounts == 0 ? .healthy : .attention
    }

    var title: String {
        switch state {
        case .empty:
            return "No accounts"
        case .noActiveAccounts:
            return "No active accounts"
        case .healthy:
            return "All active accounts ready"
        case .attention:
            let plural = attentionAccounts == 1 ? "" : "s"
            let verb = attentionAccounts == 1 ? "needs" : "need"
            return "\(attentionAccounts) account\(plural) \(verb) attention"
        }
    }

    var detail: String {
        var parts = ["\(healthyAccounts) ready", "\(activeAccounts) active"]
        if disabledAccounts > 0 {
            parts.append("\(disabledAccounts) disabled")
        }
        return parts.joined(separator: " · ")
    }

    var symbolName: String {
        switch state {
        case .empty, .noActiveAccounts:
            return "circle.dashed"
        case .healthy:
            return "checkmark.circle.fill"
        case .attention:
            return "exclamationmark.triangle.fill"
        }
    }
}

private struct DashboardQuickStatusView: View {
    let snapshot: SharedSnapshot
    let isRefreshing: Bool

    private var status: DashboardQuickStatus {
        DashboardQuickStatus(snapshot: snapshot)
    }

    private var tint: Color {
        switch status.state {
        case .empty, .noActiveAccounts:
            return .secondary
        case .healthy:
            return .green
        case .attention:
            return .orange
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.symbolName)
                .foregroundStyle(tint)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    Text(status.detail)
                    Text("·")
                    Text(snapshot.generatedAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.35))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.title). \(status.detail)")
    }
}

enum AccountDetailPresentation {
    static func isEnabled(_ account: SharedAccountSnapshot) -> Bool {
        account.isEnabled
    }

    static func remoteAccountID(_ account: SharedAccountSnapshot) -> String? {
        account.identity?.remotePrincipalID
    }

    static func lastRefresh(_ account: SharedAccountSnapshot) -> Date? {
        account.usage?.freshness.fetchedAt
    }

    static func providerLabel(_ provider: Provider) -> String {
        switch provider {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .moonshot: return "Kimi / Moonshot"
        case .moonshotChina: return "Kimi / Moonshot China"
        case .deepSeek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        case .zhipu: return "GLM / Zhipu"
        case .miniMax: return "MiniMax"
        case .qwen: return "Qwen"
        case let .other(value): return value
        }
    }

    static func surfaceLabel(_ surface: Surface) -> String {
        switch surface {
        case .api: return "API"
        case .consumerSubscription: return "Consumer subscription"
        case let .other(value): return value
        }
    }

    static func scopeLabel(_ scope: UsageScope) -> String {
        switch scope {
        case let .organization(value): return "Organization · \(value)"
        case let .workspace(value): return "Workspace · \(value)"
        case let .project(value): return "Project · \(value)"
        case let .account(value): return "Account · \(value)"
        case let .providerDefined(kind, identifier): return "\(kind) · \(identifier)"
        case .unknown: return "Unknown"
        }
    }

    static func stateLabel(_ usage: UsageSnapshot) -> String {
        if let failure = usage.failure {
            switch failure {
            case .authRequired:
                return "Sign in again"
            case .permissionDenied:
                return "Permission denied"
            case .rateLimited:
                return "Rate limited"
            case .offline:
                return "Offline"
            case .providerError:
                return "Provider error"
            case .invalidResponse:
                return "Provider response changed"
            case .unsupported:
                return "Unsupported"
            case .partial:
                return "Partial data"
            case .noData:
                return "No data"
            }
        }
        switch usage.freshness.state {
        case .fresh: return "Fresh"
        case .stale: return "Stale"
        case .noData: return "No data"
        }
    }

    static func stateColor(_ usage: UsageSnapshot) -> Color {
        usage.failure == nil && usage.freshness.state == .fresh ? .green : .orange
    }
}

enum QuotaPresentation {
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

private struct QuotaGaugeView: View {
    let title: String
    let metric: UsageMetric

    private var remainingFraction: Double? {
        QuotaPresentation.remainingFraction(for: metric)
    }

    private var remainingPercent: Int? {
        remainingFraction.map { Int(($0 * 100).rounded()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: "gauge.with.dots.needle.67percent")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let remainingPercent {
                    Text("\(remainingPercent)% remaining")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                if let remainingFraction {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(DashboardPalette.track)
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: gaugeColors(for: remainingFraction),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(
                                    width: max(12, geometry.size.width * remainingFraction)
                                )
                        }
                    }
                    .frame(height: 10)
                } else if let displayValue {
                    Text(displayValue)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(
                    "\(title), \(remainingPercent.map { "\($0) percent remaining" } ?? displayValue ?? "value unavailable")"
                )
            )

            if case let .at(resetAt, _) = metric.reset {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                    Text("Resets")
                    Text(resetAt, style: .relative)
                    Spacer()
                    Text(resetAt, style: .time)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
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

private struct AccountSnapshotCard: View {
    let account: SharedAccountSnapshot
    let isReordering: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Int) -> Void
    let onDetail: () -> Void
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if isReordering {
                    VStack(spacing: 4) {
                        Button {
                            onMove(-1)
                        } label: {
                            Image(systemName: "arrow.up")
                                .frame(width: 24, height: 20)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Move account up")
                        .accessibilityLabel("Move account up")
                        .accessibilityIdentifier("move-account-up")
                        .disabled(!canMoveUp)

                        Button {
                            onMove(1)
                        } label: {
                            Image(systemName: "arrow.down")
                                .frame(width: 24, height: 20)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Move account down")
                        .accessibilityLabel("Move account down")
                        .accessibilityIdentifier("move-account-down")
                        .disabled(!canMoveDown)
                    }
                    .fixedSize()
                }
                Text(account.label)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(AccountDetailPresentation.providerLabel(account.provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Detail", action: onDetail)
                    Divider()
                    Button("Rename account", action: onEdit)
                    Button(account.isEnabled ? "Disable" : "Enable", action: onToggle)
                    Divider()
                    Button("Remove", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }

            if let usage = account.usage {
                if let metric = QuotaPresentation.primaryMetric(
                    for: usage,
                    provider: account.provider
                ) {
                    QuotaGaugeView(
                        title: quotaTitle(for: account.provider),
                        metric: metric
                    )
                } else {
                    Text("Primary quota is unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("no_data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(DashboardPalette.border)
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
}

private struct AccountDetailView: View {
    let account: SharedAccountSnapshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Account detail")
                        .font(.headline)
                    Text(account.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: 10) {
                AccountDetailRow(label: "Provider", value: AccountDetailPresentation.providerLabel(account.provider))
                AccountDetailRow(label: "Account", value: AccountDetailPresentation.remoteAccountID(account) ?? "Not reported")
                if let identity = account.identity {
                    AccountDetailRow(label: "Scope", value: AccountDetailPresentation.scopeLabel(identity.scope))
                }
                AccountDetailRow(
                    label: "Connection",
                    value: AccountDetailPresentation.isEnabled(account) ? "Enabled" : "Disabled",
                    valueColor: AccountDetailPresentation.isEnabled(account) ? .green : .secondary
                )
                AccountDetailRow(label: "Surface", value: AccountDetailPresentation.surfaceLabel(account.surface))

                if let usage = account.usage {
                    AccountDetailRow(
                        label: "Status",
                        value: AccountDetailPresentation.stateLabel(usage),
                        valueColor: AccountDetailPresentation.stateColor(usage)
                    )
                    AccountDetailRow(
                        label: "Last refreshed",
                        value: AccountDetailPresentation.lastRefresh(account)?
                            .formatted(date: .abbreviated, time: .shortened) ?? "Not available"
                    )
                } else {
                    AccountDetailRow(label: "Status", value: "No snapshot", valueColor: .orange)
                    AccountDetailRow(label: "Last refreshed", value: "Not available")
                }
            }

            HStack {
                Spacer()
                Button("Done", action: dismiss.callAsFunction)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .background(.regularMaterial)
    }
}

private struct AccountDetailRow: View {
    let label: String
    let value: String
    var valueColor: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Group {
                if let valueColor {
                    Text(value)
                        .foregroundStyle(valueColor)
                } else {
                    Text(value)
                }
            }
            .font(.body.weight(.medium))
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
        }
    }
}

private struct AccountEditView: View {
    let account: SharedAccountSnapshot
    let onCancel: () -> Void
    let onSave: (String) async throws -> Void
    @State private var label: String
    @State private var errorMessage: String?

    init(
        account: SharedAccountSnapshot,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) async throws -> Void
    ) {
        self.account = account
        self.onCancel = onCancel
        self.onSave = onSave
        _label = State(initialValue: account.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename account").font(.headline)
            TextField("Custom account name", text: $label)
                .textFieldStyle(.roundedBorder)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save") {
                    Task {
                        do {
                            let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else {
                                errorMessage = "Enter a custom account name."
                                return
                            }
                            try await onSave(name)
                        } catch {
                            errorMessage = "Unable to save account changes."
                        }
                    }
                }
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

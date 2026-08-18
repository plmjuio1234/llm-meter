import SwiftUI
import UsageCore

/// Starts a provider-owned OAuth consent flow. No token or API key is typed
/// into this view.
public struct AccountOnboardingView: View {
    public typealias LinkAction = @MainActor @Sendable (Provider, String?) async throws -> Void
    public typealias APIKeyAction = @MainActor @Sendable (Provider, String, String?) async throws -> Void
    public typealias CancelAction = @MainActor @Sendable () -> Void

    private enum ProviderChoice: String, CaseIterable, Identifiable {
        case openAI = "OpenAI / ChatGPT"
        case anthropic = "Anthropic / Claude"
        case moonshot = "Kimi / Moonshot (International)"
        case moonshotChina = "Kimi / Moonshot (China)"
        case deepSeek = "DeepSeek"
        case openRouter = "OpenRouter"
        case zhipu = "GLM / Zhipu Coding Plan"
        case miniMax = "MiniMax Coding Plan"
        case qwen = "Qwen Coding Plan"

        var id: Self { self }
        var provider: Provider {
            switch self {
            case .openAI: return .openAI
            case .anthropic: return .anthropic
            case .moonshot: return .moonshot
            case .moonshotChina: return .moonshotChina
            case .deepSeek: return .deepSeek
            case .openRouter: return .openRouter
            case .zhipu: return .zhipu
            case .miniMax: return .miniMax
            case .qwen: return .qwen
            }
        }

        var usesAPIKey: Bool {
            self != .openAI && self != .anthropic
        }

        var reportsAccountUsage: Bool {
            switch self {
            case .openAI, .anthropic, .moonshot, .moonshotChina, .deepSeek, .openRouter:
                return true
            case .zhipu, .miniMax, .qwen:
                return false
            }
        }
    }

    private let linkAction: LinkAction
    private let apiKeyAction: APIKeyAction?
    private let onCancel: CancelAction
    @State private var label = ""
    @State private var apiKey = ""
    @State private var providerChoice = ProviderChoice.openAI
    @State private var isSubmitting = false
    @State private var showsFailure = false

    public init(
        onCancel: @escaping CancelAction = {},
        linkAction: @escaping LinkAction,
        apiKeyAction: APIKeyAction? = nil
    ) {
        self.onCancel = onCancel
        self.linkAction = linkAction
        self.apiKeyAction = apiKeyAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an account")
                .font(.headline)
            Text(
                providerChoice.usesAPIKey
                    ? "Enter a provider API key. The app stores it only in Keychain."
                    : "Sign in in your browser. The app stores only the OAuth token in Keychain."
            )
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Provider", selection: $providerChoice) {
                ForEach(ProviderChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }

            TextField("Custom account name (optional)", text: $label)
                .textFieldStyle(.roundedBorder)

            if providerChoice.usesAPIKey {
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text(
                    providerChoice.reportsAccountUsage
                        ? "The key is stored only in the macOS Keychain."
                        : "The key is stored only in Keychain. This provider does not publish an account-wide usage API, so the connection will show Unsupported."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button(
                    providerChoice.usesAPIKey
                        ? (providerChoice.reportsAccountUsage ? "Connect API key" : "Save connection")
                        : "Continue in browser",
                    action: submit
                )
                    .disabled(isSubmitting)
            }

            if isSubmitting {
                ProgressView("Waiting for sign-in...")
                    .controlSize(.small)
            }
            if showsFailure {
                Text("The OAuth account could not be connected.")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding()
    }

    private func submit() {
        isSubmitting = true
        showsFailure = false
        let selectedProvider = providerChoice.provider
        let requestedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                if providerChoice.usesAPIKey {
                    guard !requestedKey.isEmpty, let apiKeyAction else {
                        throw OAuthLinkingError.unsupportedProvider
                    }
                    try await apiKeyAction(
                        selectedProvider,
                        requestedKey,
                        requestedLabel.isEmpty ? nil : requestedLabel
                    )
                } else {
                    try await linkAction(
                        selectedProvider,
                        requestedLabel.isEmpty ? nil : requestedLabel
                    )
                }
            } catch {
                showsFailure = true
            }
        }
    }
}

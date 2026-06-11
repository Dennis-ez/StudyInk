import SwiftUI

/// App settings: appearance override, backup, and the AI tutor's provider,
/// API keys (pasted in-app, stored in the Keychain), and model.
struct SettingsView: View {
    @AppStorage("settings.appearance") private var appearance = "system"
    @AppStorage("settings.autoBackup") private var autoBackup = true
    @AppStorage("settings.iCloudSync") private var iCloudSync = false
    @AppStorage("settings.ai.provider") private var providerRaw = AIProvider.claude.rawValue
    @AppStorage("settings.defaultTemplate") private var defaultTemplate = "blank"
    @Environment(\.dismiss) private var dismiss

    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var customModel = ""
    @State private var keyInput = ""
    @State private var keyConfigured = false

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .claude }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Label("settings.appearance", systemImage: "circle.lefthalf.filled")) {
                    Picker("settings.appearance", selection: $appearance) {
                        Text("settings.appearance.system").tag("system")
                        Text("settings.appearance.light").tag("light")
                        Text("settings.appearance.dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section(header: Label("settings.backup", systemImage: "icloud")) {
                    Toggle("settings.autoBackup", isOn: $autoBackup)
                    Toggle("settings.iCloudSync", isOn: $iCloudSync)
                    Text("settings.iCloudSync.footnote")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section(header: Label("settings.notes", systemImage: "book.closed")) {
                    Picker("settings.defaultTemplate", selection: $defaultTemplate) {
                        ForEach(PageTemplate.allCases.filter { $0 != .customPDF }) { template in
                            Text(template.labelKey).tag(template.rawValue)
                        }
                    }
                }
                aiKeySection
                aiModelSection
            }
            .navigationTitle(Text("settings.title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
            .onChange(of: providerRaw) { refreshProviderState() }
            .onAppear { refreshProviderState() }
        }
    }

    // MARK: - API key

    @ViewBuilder
    private var aiKeySection: some View {
        Section(header: Label("settings.ai", systemImage: "sparkles")) {
            Picker("settings.ai.provider", selection: $providerRaw) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }

            LabeledContent("settings.ai.status") {
                Text(keyConfigured ? "settings.ai.configured" : "settings.ai.missingKey")
                    .foregroundStyle(keyConfigured ? .green : .orange)
            }

            HStack {
                SecureField("settings.ai.pasteKey", text: $keyInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("settings.ai.saveKey") {
                    let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    AIConfig.setAPIKey(trimmed, for: provider)
                    keyInput = ""
                    refreshProviderState()
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if AIConfig.hasStoredKey(for: provider) {
                Button(role: .destructive) {
                    AIConfig.setAPIKey(nil, for: provider)
                    refreshProviderState()
                } label: {
                    Label("settings.ai.removeKey", systemImage: "key.slash")
                }
            }

            Text(provider == .claude ? "settings.ai.keyHelp" : "settings.ai.keyHelp.gemini")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Model

    @ViewBuilder
    private var aiModelSection: some View {
        Section(header: Label("settings.ai.model", systemImage: "cpu")) {
            Picker("settings.ai.model", selection: modelBinding) {
                ForEach(models, id: \.self) { model in
                    Text(verbatim: model).tag(model)
                }
                // Keep an off-list selection (custom model) visible in the picker.
                if !models.contains(AIConfig.model(for: provider)) {
                    Text(verbatim: AIConfig.model(for: provider)).tag(AIConfig.model(for: provider))
                }
            }

            Button {
                loadModels()
            } label: {
                HStack {
                    Label("settings.ai.loadModels", systemImage: "arrow.clockwise")
                    if loadingModels { Spacer(); ProgressView().controlSize(.small) }
                }
            }
            .disabled(loadingModels || !keyConfigured)

            HStack {
                TextField("settings.ai.customModel", text: $customModel)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("action.done") {
                    let trimmed = customModel.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    AIConfig.setModel(trimmed, for: provider)
                    customModel = ""
                }
                .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { AIConfig.model(for: provider) },
            set: { AIConfig.setModel($0, for: provider) }
        )
    }

    private func refreshProviderState() {
        keyConfigured = AIConfig.isConfigured(for: provider)
        keyInput = ""
        models = provider.defaultModels
        if keyConfigured { loadModels() }
    }

    private func loadModels() {
        loadingModels = true
        let target = provider
        Task {
            let fetched = await AIService.availableModels(for: target)
            await MainActor.run {
                if target == provider { models = fetched }
                loadingModels = false
            }
        }
    }
}

/// Provider configuration. API keys are pasted in Settings and stored in the
/// Keychain; the gitignored Config.plist remains a development-only fallback.
/// The active provider and per-provider model choice live in UserDefaults.
enum AIConfig {
    private static func keychainAccount(for provider: AIProvider) -> String {
        "\(provider.rawValue)_api_key"
    }

    private static var plist: [String: Any] {
        guard let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return values
    }

    private static func plistString(_ key: String) -> String? {
        guard let value = plist[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    static func apiKey(for provider: AIProvider) -> String? {
        if let stored = KeychainStore.get(keychainAccount(for: provider)) {
            return stored
        }
        // Development fallback: gitignored Config.plist.
        switch provider {
        case .claude: return plistString("ANTHROPIC_API_KEY")
        case .gemini: return plistString("GEMINI_API_KEY")
        }
    }

    /// nil removes the stored key (the plist fallback, if any, applies again).
    static func setAPIKey(_ key: String?, for provider: AIProvider) {
        let account = keychainAccount(for: provider)
        if let key, !key.isEmpty {
            KeychainStore.set(key, account: account)
        } else {
            KeychainStore.delete(account)
        }
    }

    /// True only when a key was pasted in-app (drives the "Remove Key" button).
    static func hasStoredKey(for provider: AIProvider) -> Bool {
        KeychainStore.get(keychainAccount(for: provider)) != nil
    }

    static var claudeKey: String? { apiKey(for: .claude) }
    static var geminiKey: String? { apiKey(for: .gemini) }

    static var provider: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: "settings.ai.provider") ?? "") ?? .claude
    }

    static func model(for provider: AIProvider) -> String {
        if let chosen = UserDefaults.standard.string(forKey: "settings.ai.model.\(provider.rawValue)"), !chosen.isEmpty {
            return chosen
        }
        if provider == .claude, let plistModel = plistString("ANTHROPIC_MODEL") {
            return plistModel
        }
        return provider.defaultModel
    }

    static func setModel(_ model: String, for provider: AIProvider) {
        UserDefaults.standard.set(model, forKey: "settings.ai.model.\(provider.rawValue)")
    }

    static func isConfigured(for provider: AIProvider) -> Bool {
        apiKey(for: provider) != nil
    }

    /// True when the currently selected provider has a key.
    static var isConfigured: Bool { isConfigured(for: provider) }
}

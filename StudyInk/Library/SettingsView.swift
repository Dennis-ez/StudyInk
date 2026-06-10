import SwiftUI

/// App settings: appearance override, backup, and the AI tutor's provider + model.
struct SettingsView: View {
    @AppStorage("settings.appearance") private var appearance = "system"
    @AppStorage("settings.autoBackup") private var autoBackup = true
    @AppStorage("settings.iCloudSync") private var iCloudSync = false
    @AppStorage("settings.ai.provider") private var providerRaw = AIProvider.claude.rawValue
    @Environment(\.dismiss) private var dismiss

    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var customModel = ""

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .claude }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("settings.appearance")) {
                    Picker("settings.appearance", selection: $appearance) {
                        Text("settings.appearance.system").tag("system")
                        Text("settings.appearance.light").tag("light")
                        Text("settings.appearance.dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section(header: Text("settings.backup")) {
                    Toggle("settings.autoBackup", isOn: $autoBackup)
                    Toggle("settings.iCloudSync", isOn: $iCloudSync)
                    Text("settings.iCloudSync.footnote")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                aiSection
            }
            .navigationTitle(Text("settings.title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
            .onChange(of: providerRaw) { resetModelList() }
            .onAppear { resetModelList() }
        }
    }

    // MARK: - AI provider & model

    @ViewBuilder
    private var aiSection: some View {
        Section(header: Text("settings.ai")) {
            Picker("settings.ai.provider", selection: $providerRaw) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }

            LabeledContent("settings.ai.status") {
                Text(AIConfig.isConfigured(for: provider) ? "settings.ai.configured" : "settings.ai.missingKey")
                    .foregroundStyle(AIConfig.isConfigured(for: provider) ? .green : .orange)
            }

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
            .disabled(loadingModels || !AIConfig.isConfigured(for: provider))

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

            Text(provider == .claude ? "settings.ai.keyHelp" : "settings.ai.keyHelp.gemini")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { AIConfig.model(for: provider) },
            set: { AIConfig.setModel($0, for: provider) }
        )
    }

    private func resetModelList() {
        models = provider.defaultModels
        if AIConfig.isConfigured(for: provider) { loadModels() }
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

/// Provider configuration: API keys come from the gitignored Config.plist;
/// the active provider and per-provider model choice live in UserDefaults
/// (set from Settings, overriding the plist default).
enum AIConfig {
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

    static var claudeKey: String? { plistString("ANTHROPIC_API_KEY") }
    static var geminiKey: String? { plistString("GEMINI_API_KEY") }

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
        switch provider {
        case .claude: return claudeKey != nil
        case .gemini: return geminiKey != nil
        }
    }

    /// True when the currently selected provider has a key.
    static var isConfigured: Bool { isConfigured(for: provider) }
}

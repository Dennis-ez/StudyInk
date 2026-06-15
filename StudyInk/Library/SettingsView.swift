import SwiftUI

/// App settings: appearance override, backup, and the AI tutor's provider,
/// API keys (pasted in-app, stored in the Keychain), and model.
struct SettingsView: View {
    @AppStorage("settings.appearance") private var appearance = "system"
    @AppStorage("settings.theme") private var themeRaw = AppTheme.paperInk.rawValue
    @AppStorage("settings.autoBackup") private var autoBackup = true
    @AppStorage("settings.iCloudSync") private var iCloudSync = false
    @AppStorage("settings.ai.provider") private var providerRaw = AIProvider.claude.rawValue
    @AppStorage("settings.defaultTemplate") private var defaultTemplate = "wideRuled"
    @AppStorage("settings.defaultTemplateSpacing") private var defaultSpacing = 1.0
    @Environment(\.dismiss) private var dismiss

    /// Wide-ruled first; PDF excluded (it needs a file, not a default).
    private let templateOrder: [PageTemplate] = [
        .wideRuled, .collegeRuled, .narrowRuled, .blank,
        .dotGrid, .squareGrid, .isometricGrid, .cornell, .musicStaff,
    ]

    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var customModel = ""
    @State private var keyInput = ""
    @State private var keyConfigured = false
    @State private var customBaseURL = AIConfig.customBaseURL

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .claude }

    private var keyHelp: LocalizedStringKey {
        switch provider {
        case .claude: return "settings.ai.keyHelp"
        case .gemini: return "settings.ai.keyHelp.gemini"
        case .custom: return "settings.ai.keyHelp.custom"
        }
    }

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

                    VStack(alignment: .leading, spacing: 10) {
                        Text("settings.theme")
                        // Each theme: the "you" accent + the "AI" accent, plus
                        // its name. Picking one also swaps the app icon.
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(AppTheme.allCases) { theme in
                                let selected = themeRaw == theme.rawValue
                                Button {
                                    themeRaw = theme.rawValue
                                } label: {
                                    HStack(spacing: 10) {
                                        ZStack {
                                            Circle().fill(theme.accent).frame(width: 26, height: 26)
                                            Circle().fill(theme.aiAccent).frame(width: 26, height: 26)
                                                .mask(Rectangle().offset(x: 13))
                                            Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1).frame(width: 26, height: 26)
                                        }
                                        Text(theme.labelKey)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Spacer(minLength: 0)
                                        if selected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(theme.accent)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(selected ? theme.accent.opacity(0.12) : Color(.secondarySystemBackground))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(selected ? theme.accent : .clear, lineWidth: 1.5)
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(theme.labelKey))
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section(header: Label("settings.backup", systemImage: "icloud")) {
                    Toggle("settings.autoBackup", isOn: $autoBackup)
                    Toggle("settings.iCloudSync", isOn: $iCloudSync)
                    Text("settings.iCloudSync.footnote")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section(header: Label("settings.notes", systemImage: "book.closed")) {
                    Text("settings.defaultTemplate")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 14)], spacing: 14) {
                        ForEach(templateOrder) { template in
                            templatePreview(template)
                        }
                    }
                    .padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("page.spacing").font(.subheadline)
                            Spacer()
                            Text(verbatim: String(format: "%.2f×", defaultSpacing))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $defaultSpacing, in: 0.6...1.8)
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

    /// Selectable live template preview — paints the actual template at the
    /// current default spacing, so the picker shows what new notes will look like.
    private func templatePreview(_ template: PageTemplate) -> some View {
        let isSelected = defaultTemplate == template.rawValue
        return Button {
            defaultTemplate = template.rawValue
        } label: {
            VStack(spacing: 5) {
                Canvas { ctx, size in
                    ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7),
                             with: .color(Color("canvasBackground")))
                    template.draw(
                        in: &ctx,
                        rect: CGRect(origin: .zero, size: size),
                        scale: 0.24,
                        lineColor: Color("templateLine"),
                        accentColor: Color("accentBlue"),
                        spacing: defaultSpacing
                    )
                }
                .frame(width: 92, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                      lineWidth: isSelected ? 2 : 1)
                )
                Text(template.labelKey)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
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

            if provider == .custom {
                // Any OpenAI-compatible server: Groq, OpenAI, Together, local.
                TextField("settings.ai.baseURL", text: $customBaseURL, prompt: Text(verbatim: "https://api.groq.com/openai/v1"))
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: customBaseURL) { _, newValue in
                        AIConfig.customBaseURL = newValue.trimmingCharacters(in: .whitespaces)
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

            Text(keyHelp)
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
        case .custom: return plistString("CUSTOM_API_KEY")
        }
    }

    /// Base URL of the custom OpenAI-compatible provider (default: Groq).
    static var customBaseURL: String {
        get {
            UserDefaults.standard.string(forKey: "settings.ai.customBaseURL").flatMap { $0.isEmpty ? nil : $0 }
                ?? "https://api.groq.com/openai/v1"
        }
        set { UserDefaults.standard.set(newValue, forKey: "settings.ai.customBaseURL") }
    }

    /// `path` appended to the configured base URL, tolerating trailing slashes.
    static func customEndpoint(path: String) -> URL {
        let base = customBaseURL.hasSuffix("/") ? String(customBaseURL.dropLast()) : customBaseURL
        return URL(string: "\(base)/\(path)") ?? URL(string: "https://api.groq.com/openai/v1/\(path)")!
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
        let selected = AIProvider(rawValue: UserDefaults.standard.string(forKey: "settings.ai.provider") ?? "") ?? .claude
        // A single configured key should just work: if the selected provider
        // has no key but another does, use the one that's actually set up.
        if isConfigured(for: selected) { return selected }
        return AIProvider.allCases.first(where: { isConfigured(for: $0) }) ?? selected
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

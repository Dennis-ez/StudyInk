import SwiftUI

/// App settings: appearance override, backup, and the AI tutor's provider,
/// API keys (pasted in-app, stored in the Keychain), and model.
struct SettingsView: View {
    @Environment(\.themePaper) private var themePaper
    @Environment(\.themeDesk) private var themeDesk
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
                Section {
                    appearanceModeRow
                } header: {
                    sectionHeader("settings.appearance")
                }

                Section {
                    themePickerCard
                } header: {
                    sectionHeader("settings.theme")
                }
                Section(header: Label("settings.backup", systemImage: "icloud")) {
                    Toggle("settings.autoBackup", isOn: $autoBackup)
                    Toggle("settings.iCloudSync", isOn: $iCloudSync)
                    Text("settings.iCloudSync.footnote")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text("settings.defaultTemplate")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 14)], spacing: 14) {
                        ForEach(templateOrder) { template in
                            templatePreview(template)
                        }
                    }
                    .padding(.vertical, DS.Space.xs)
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        HStack {
                            Text("page.spacing").font(.subheadline)
                            Spacer()
                            Text(verbatim: String(format: "%.2f×", defaultSpacing))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        // Slider painted in the active "you" accent per spec.
                        Slider(value: $defaultSpacing, in: 0.6...1.8)
                            .tint(activeTheme.accent)
                    }
                } header: {
                    sectionHeader("settings.notes")
                }
                aiKeySection
                aiModelSection
            }
            .scrollContentBackground(.hidden)
            .background(themePaper.ignoresSafeArea())
            .navigationTitle(Text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // H1 in the brand serif (the spec's Fraunces title voice).
                ToolbarItem(placement: .principal) {
                    Text("settings.title")
                        .font(.fraunces(20, weight: .semibold, relativeTo: .headline))
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
            .onChange(of: providerRaw) { refreshProviderState() }
            .onAppear { refreshProviderState() }
        }
    }

    // MARK: - Appearance & theme

    /// The currently selected theme, resolved from storage so chips and tints
    /// react the moment a new theme is picked.
    private var activeTheme: AppTheme {
        AppTheme(rawValue: themeRaw) ?? .paperInk
    }

    /// A section header rendered in the brand serif (the spec's Fraunces voice)
    /// rather than the default uppercase Form caption.
    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.fraunces(20, weight: .semibold, relativeTo: .title3))
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.bottom, DS.Space.xs)
    }

    /// MODE — segmented Light / Dark / System sitting on the theme "desk" track,
    /// per the spec's `editorDesk` track styling.
    private var appearanceModeRow: some View {
        Picker("settings.appearance", selection: $appearance) {
            Text("settings.appearance.light").tag("light")
            Text("settings.appearance.dark").tag("dark")
            Text("settings.appearance.system").tag("system")
        }
        .pickerStyle(.segmented)
        .padding(DS.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(themeDesk)
        )
        .tint(activeTheme.accent)
        .padding(.vertical, DS.Space.xs)
    }

    /// THEME — caption + a wrapping grid of theme chips. Each chip paints its
    /// OWN theme's accents (not the active tint) so the palette is legible.
    private var themePickerCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            // Spec caption. Kept verbatim because no localization key exists yet
            // and this file is the only one in scope to edit.
            Text(verbatim: "pairs your ink with your tutor's color")
                .font(.footnote)
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: DS.Space.md)],
                spacing: DS.Space.md
            ) {
                ForEach(AppTheme.allCases) { theme in
                    themeChip(theme)
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    /// One ~104pt theme cell: a 60pt app-mark preview tinted to the theme's
    /// "you" accent, the theme name (13.5/600), and two 13pt dots (you, ai).
    /// Selected = light paper card, 2pt accent border, check badge top-right.
    private func themeChip(_ theme: AppTheme) -> some View {
        let selected = themeRaw == theme.rawValue
        return Button {
            themeRaw = theme.rawValue
        } label: {
            VStack(spacing: DS.Space.sm) {
                // 60pt preview — an inline BrandMark in the theme's own accent
                // (BrandMark itself only reads Color.accentColor, so we draw it
                // here to force each chip into its own theme colours).
                RoundedRectangle(cornerRadius: 60 * 0.36, style: .continuous)
                    .fill(theme.accent)
                    .frame(width: 60, height: 60)
                    .overlay(
                        Circle()
                            .fill(Color(red: 1.0, green: 0.839, blue: 0.039)) // #FFD60A gold dot
                            .frame(width: 60 * 0.46, height: 60 * 0.46)
                    )

                Text(theme.labelKey)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                HStack(spacing: DS.Space.sm) {
                    Circle().fill(theme.accent).frame(width: 13, height: 13)
                    Circle().fill(theme.aiAccent).frame(width: 13, height: 13)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.md)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? SemanticColor.paperBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        selected ? theme.accent : SemanticColor.cardEdge,
                        lineWidth: selected ? DS.Stroke.regular : DS.Stroke.hairline
                    )
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, theme.accent)
                        .padding(DS.Space.sm)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(DS.Motion.selection, value: selected)
        .accessibilityLabel(Text(theme.labelKey))
        .accessibilityAddTraits(selected ? .isSelected : [])
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

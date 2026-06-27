import SwiftUI

/// App settings, rebuilt for the Foolscap redesign as a `NavigationSplitView`
/// presented inside the settings sheet. The sidebar lists Appearance · AI Tutor
/// · Notes & Sync · Export · About; the content pane renders grouped iOS-style
/// cards on the warm `themePaper` chrome.
///
/// All existing functionality is preserved — the appearance/theme bindings, the
/// backup toggles, the default template + spacing controls, and the AI
/// provider/key/model sections — relocated into the new structure.
struct SettingsView: View {
    @Environment(\.themePaper) private var themePaper
    @Environment(\.themeSidebar) private var themeSidebar
    @Environment(\.themeDesk) private var themeDesk
    @AppStorage("settings.appearance") private var appearance = "system"
    @AppStorage("settings.theme") private var themeRaw = AppTheme.foolscap.rawValue
    @AppStorage("settings.autoBackup") private var autoBackup = true
    @AppStorage("settings.iCloudSync") private var iCloudSync = false
    @AppStorage("settings.ai.provider") private var providerRaw = AIProvider.claude.rawValue
    @AppStorage("settings.ai.replyLanguage") private var replyLanguageRaw = AIReplyLanguage.device.rawValue
    @AppStorage("settings.defaultTemplate") private var defaultTemplate = "wideRuled"
    @AppStorage("settings.defaultTemplateSpacing") private var defaultSpacing = 1.0
    @AppStorage("debug.penTracker") private var penTrackerDebug = false
    @Environment(\.dismiss) private var dismiss

    /// Which sidebar section is showing in the content pane.
    @State private var pane: SettingsPane = .appearance

    /// Wide-ruled first; PDF excluded (it needs a file, not a default).
    private let templateOrder: [PageTemplate] = [
        .wideRuled, .collegeRuled, .narrowRuled, .blank,
        .dotGrid, .squareGrid, .isometricGrid, .cornell, .musicStaff,
    ]

    @State private var showAIDebug = false
    @State private var showPerfMonitor = false
    @State private var showNativeZoomLab = false
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

    // MARK: - Sidebar model

    /// The five sidebar destinations, in spec order.
    private enum SettingsPane: String, CaseIterable, Identifiable {
        case appearance, aiTutor, notesSync, export, about
        var id: String { rawValue }

        /// English titles for sidebar + the Fraunces H1. Export and About have
        /// no localization keys, so the section uses verbatim strings throughout
        /// for consistency rather than mixing localized and raw labels.
        var titleText: String {
            switch self {
            case .appearance: return "Appearance"
            case .aiTutor:    return "AI Tutor"
            case .notesSync:  return "Notes & Sync"
            case .export:     return "Export"
            case .about:      return "About"
            }
        }

        var systemImage: String {
            switch self {
            case .appearance: return "paintpalette"
            case .aiTutor:    return "sparkles"
            case .notesSync:  return "icloud"
            case .export:     return "square.and.arrow.up"
            case .about:      return "info.circle"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        // Same shell as the main library screen: a fixed, full-bleed sidebar
        // column flush at the leading edge (NOT NavigationSplitView's floating
        // glass column), a hairline divider, then the content pane.
        HStack(spacing: 0) {
            sidebar
                .frame(width: 264)
                .clipped()
            Rectangle()
                .fill(SemanticColor.separator)
                .frame(width: 1)
                .ignoresSafeArea()
            NavigationStack { detail }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(alignment: .leading) {
            themeSidebar.frame(width: 264).ignoresSafeArea()
        }
        .background(themePaper.ignoresSafeArea())
        .tint(activeTheme.accent)
        // Settings is a fullScreenCover — a separate presentation layer that does
        // NOT inherit the app root's .preferredColorScheme. Without this, changing
        // the appearance here only took effect once you dismissed back to the root.
        .preferredColorScheme(settingsScheme)
        .onChange(of: providerRaw) { refreshProviderState() }
        .onAppear { refreshProviderState() }
    }

    /// Mirrors the app root's scheme so the appearance switch applies live in the
    /// cover. nil = follow the system.
    private var settingsScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        // Opaque warm spine behind the rows — mirrors the library sidebar.
        ZStack {
            themeSidebar.ignoresSafeArea()
            List {
                // Big serif title in the content, matching the library spine.
                Text("settings.title")
                    .font(.fraunces(28, weight: .semibold, relativeTo: .largeTitle))
                    .foregroundStyle(.primary)
                    .padding(.top, DS.Space.sm)
                    .padding(.bottom, DS.Space.xs)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                ForEach(SettingsPane.allCases) { item in
                    sidebarRow(item)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    /// One sidebar destination — mirrors the LIBRARY sidebar's `sectionRow`:
    /// SF Symbol + callout label, selected = subtle `fillSelected` + a 3pt
    /// leading accent capsule.
    private func sidebarRow(_ item: SettingsPane) -> some View {
        let selected = pane == item
        return Button {
            pane = item
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 19))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 24)
                Text(verbatim: item.titleText)
                    .font(.callout.weight(selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 40)
            // The whole row is tappable, not just the icon/word (the Spacer is
            // transparent and otherwise wouldn't hit-test).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Selected = subtle fill + a 3pt accent bar inset at the leading edge.
        .listRowBackground(
            roundedRowBackground(selected ? SemanticColor.fillSelected : .clear)
                .overlay(alignment: .leading) {
                    if selected {
                        Rectangle().fill(Color.accentColor)
                            .frame(width: 3)
                    }
                }
        )
        .listRowSeparator(.hidden)
        .animation(DS.Motion.selection, value: selected)
        .accessibilityLabel(Text(item.titleText))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func roundedRowBackground(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
    }

    // MARK: - Detail pane

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                // H1 in the brand serif, matching the selected sidebar item.
                Text(pane.titleText)
                    .font(.fraunces(30, weight: .semibold, relativeTo: .largeTitle))
                    .foregroundStyle(.primary)
                    .padding(.top, DS.Space.sm)

                switch pane {
                case .appearance: appearancePane
                case .aiTutor:    aiTutorPane
                case .notesSync:  notesSyncPane
                case .export:     exportPane
                case .about:      aboutPane
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.xxl)
        }
        .scrollContentBackground(.hidden)
        .background(themePaper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("action.done") { dismiss() }
            }
        }
    }

    // MARK: - Grouped card chrome

    /// A grouped iOS-style card: `paperBackground` chrome fill, 1pt `cardEdge`
    /// border, radius 14, `e1` elevation. Rows inside are divided by 1pt
    /// separators via `cardRows`.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SemanticColor.paperBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(SemanticColor.cardEdge, lineWidth: DS.Stroke.hairline)
        )
        .elevation(.e1)
    }

    /// A short caption above a card, in the spec's secondary voice.
    private func cardCaption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.xs)
    }

    /// A 1pt in-card separator between rows.
    private var rowDivider: some View {
        Rectangle()
            .fill(SemanticColor.separator)
            .frame(height: DS.Stroke.hairline)
            .padding(.vertical, DS.Space.sm)
    }

    // MARK: - Appearance pane

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            // MODE — segmented Light / Dark / System on the theme "desk" track.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                cardCaption(String(localized: "settings.appearance"))
                card { appearanceModeRow }
            }

            // THEME — caption + the wrapping theme-chip grid.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                cardCaption("pairs your ink with your tutor's color")
                card { themePickerGrid }
            }

            // CANVAS — template line intensity (active accent tint). "Toolbar
            // position" is omitted: no such binding exists in the app yet.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                cardCaption("Canvas")
                card { templateIntensityRow }
            }
        }
    }

    /// The currently selected theme, resolved from storage so chips and tints
    /// react the moment a new theme is picked.
    private var activeTheme: AppTheme {
        AppTheme(rawValue: themeRaw) ?? .foolscap
    }

    /// MODE — segmented Light / Dark / System sitting on the theme "desk" track.
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
    }

    /// THEME — a wrapping grid of theme chips. Each chip paints its OWN theme's
    /// accents (not the active tint) so the palette is legible.
    private var themePickerGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 104), spacing: DS.Space.md)],
            spacing: DS.Space.md
        ) {
            ForEach(AppTheme.allCases) { theme in
                themeChip(theme)
            }
        }
    }

    /// CANVAS — "Template line intensity" slider tinted in the active theme accent.
    private var templateIntensityRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text(verbatim: "Template line intensity").font(.subheadline)
                Spacer()
                Text(verbatim: String(format: "%.2f×", defaultSpacing))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // Slider painted in the active "you" accent per spec.
            Slider(value: $defaultSpacing, in: 0.6...1.8)
                .tint(activeTheme.accent)
        }
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
                // 60pt preview — an inline mark in the theme's own accent
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

    // MARK: - AI Tutor pane

    private var aiTutorPane: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            // Provider + API key, restyled into a grouped card.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                cardCaption(String(localized: "settings.ai"))
                card { aiKeyContent }
            }

            // Model selection, restyled into a grouped card.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                cardCaption(String(localized: "settings.ai.model"))
                card { aiModelContent }
            }

            // Which language the AI answers in.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                cardCaption(String(localized: "settings.ai.lang"))
                card {
                    Picker("settings.ai.lang", selection: $replyLanguageRaw) {
                        ForEach(AIReplyLanguage.allCases) { lang in
                            Text(lang.labelKey).tag(lang.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            // Developer: inspect the real prompts / OCR / responses. Presented as a
            // sheet (its own NavigationStack) so Back/Done always work — a push in
            // the split-view detail column was leaving it with no way out.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                cardCaption("Developer")
                card {
                    Button {
                        showAIDebug = true
                    } label: {
                        HStack {
                            Label(title: { Text(verbatim: "AI debug log") },
                                  icon: { Image(systemName: "ladybug") })
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                    Button {
                        showPerfMonitor = true
                    } label: {
                        HStack {
                            Label(title: { Text(verbatim: "Performance") },
                                  icon: { Image(systemName: "gauge.with.dots.needle.bottom.50percent") })
                            Spacer()
                            if PerfMonitor.shared.isCapturing {
                                Image(systemName: "record.circle").foregroundStyle(.red)
                            }
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                    Button {
                        showNativeZoomLab = true
                    } label: {
                        HStack {
                            Label(title: { Text(verbatim: "Native zoom (preview)") },
                                  icon: { Image(systemName: "arrow.up.left.and.arrow.down.right.magnifyingglass") })
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text(verbatim: "Prototype: write, then pinch to zoom. Tests whether PencilKit-native zoom keeps ink crisp (vs the current transform-zoom blur).")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle(isOn: $penTrackerDebug) {
                        Label(title: { Text(verbatim: "Pen tracker (debug)") },
                              icon: { Image(systemName: "pencil.tip.crop.circle") })
                    }
                    Text(verbatim: "Shows a red dot at the pen tip while writing, so a screen recording reveals any gap between the pen and the ink.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showAIDebug) {
                NavigationStack { AIDebugView() }
            }
            .sheet(isPresented: $showPerfMonitor) {
                NavigationStack { PerfMonitorView() }
            }
            .fullScreenCover(isPresented: $showNativeZoomLab) {
                NativeZoomLabView()
            }
        }
    }

    /// Provider picker + API key paste/remove + status. Preserves the original
    /// Keychain-backed behaviour, restyled out of `Form` into a grouped card.
    @ViewBuilder
    private var aiKeyContent: some View {
        Picker("settings.ai.provider", selection: $providerRaw) {
            ForEach(AIProvider.allCases) { provider in
                Text(provider.displayName).tag(provider.rawValue)
            }
        }
        .pickerStyle(.menu)

        if provider == .custom {
            rowDivider
            // Any OpenAI-compatible server: Groq, OpenAI, Together, local.
            TextField("settings.ai.baseURL", text: $customBaseURL, prompt: Text(verbatim: "https://api.groq.com/openai/v1"))
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: customBaseURL) { _, newValue in
                    AIConfig.customBaseURL = newValue.trimmingCharacters(in: .whitespaces)
                }
        }

        rowDivider

        LabeledContent("settings.ai.status") {
            Text(keyConfigured ? "settings.ai.configured" : "settings.ai.missingKey")
                .foregroundStyle(keyConfigured ? .green : .orange)
        }

        rowDivider

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
            rowDivider
            Button(role: .destructive) {
                AIConfig.setAPIKey(nil, for: provider)
                refreshProviderState()
            } label: {
                Label("settings.ai.removeKey", systemImage: "key.slash")
            }
        }

        rowDivider

        Text(keyHelp)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// Model picker + live model refresh + custom-model entry. Preserves the
    /// original behaviour, restyled out of `Form` into a grouped card.
    @ViewBuilder
    private var aiModelContent: some View {
        Picker("settings.ai.model", selection: modelBinding) {
            ForEach(models, id: \.self) { model in
                Text(verbatim: model).tag(model)
            }
            // Keep an off-list selection (custom model) visible in the picker.
            if !models.contains(AIConfig.model(for: provider)) {
                Text(verbatim: AIConfig.model(for: provider)).tag(AIConfig.model(for: provider))
            }
        }
        .pickerStyle(.menu)

        rowDivider

        Button {
            loadModels()
        } label: {
            HStack {
                Label("settings.ai.loadModels", systemImage: "arrow.clockwise")
                if loadingModels { Spacer(); ProgressView().controlSize(.small) }
            }
        }
        .disabled(loadingModels || !keyConfigured)

        rowDivider

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

    private var modelBinding: Binding<String> {
        Binding(
            get: { AIConfig.model(for: provider) },
            set: { AIConfig.setModel($0, for: provider) }
        )
    }

    // MARK: - Notes & Sync pane

    private var notesSyncPane: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            // Backup / iCloud toggles.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                cardCaption(String(localized: "settings.backup"))
                card {
                    Toggle("settings.autoBackup", isOn: $autoBackup)
                    rowDivider
                    Toggle("settings.iCloudSync", isOn: $iCloudSync)
                    rowDivider
                    Text("settings.iCloudSync.footnote")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .tint(activeTheme.accent)
            }

            // Default template + spacing.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                cardCaption(String(localized: "settings.defaultTemplate"))
                card {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 14)], spacing: 14) {
                        ForEach(templateOrder) { template in
                            templatePreview(template)
                        }
                    }
                    rowDivider
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
                }
            }
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

    // MARK: - Export pane

    /// No export settings are wired yet, so this is a placeholder card rather
    /// than fake bindings (per the rebuild rules).
    private var exportPane: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            card {
                HStack(spacing: DS.Space.md) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text(verbatim: "Export options coming soon.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - About pane

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            card {
                LabeledContent {
                    Text(verbatim: appVersionString)
                        .foregroundStyle(.secondary)
                } label: {
                    Text(verbatim: "Version")
                }

                rowDivider

                Link(destination: URL(string: "https://github.com/Dennis-ez/StudyInk")!) {
                    HStack {
                        Label(title: { Text(verbatim: "GitHub") },
                              icon: { Image(systemName: "link") })
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(activeTheme.accent)

                rowDivider

                Text(verbatim: "Your notes and API keys stay on your device. Keys are stored in the iOS Keychain and are sent only to the AI provider you choose.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// App marketing version from the bundle (CFBundleShortVersionString).
    private var appVersionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let build, !build.isEmpty { return "\(short) (\(build))" }
        return short
    }

    // MARK: - Provider / model state

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

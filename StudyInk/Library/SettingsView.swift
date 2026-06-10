import SwiftUI

/// App settings: appearance override (fully wired in phase 4), backup, and AI status.
struct SettingsView: View {
    @AppStorage("settings.appearance") private var appearance = "system"
    @AppStorage("settings.autoBackup") private var autoBackup = true
    @AppStorage("settings.iCloudSync") private var iCloudSync = false
    @Environment(\.dismiss) private var dismiss

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
                Section(header: Text("settings.ai")) {
                    LabeledContent("settings.ai.status") {
                        Text(AIConfig.isConfigured ? "settings.ai.configured" : "settings.ai.missingKey")
                            .foregroundStyle(AIConfig.isConfigured ? .green : .orange)
                    }
                    Text("settings.ai.keyHelp")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(Text("settings.title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
        }
    }
}

/// Reads the Anthropic API key from Config.plist (gitignored; see README).
enum AIConfig {
    static var apiKey: String? {
        guard let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = plist["ANTHROPIC_API_KEY"] as? String,
              !key.isEmpty else { return nil }
        return key
    }

    static var model: String {
        guard let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let model = plist["ANTHROPIC_MODEL"] as? String,
              !model.isEmpty else { return "claude-fable-5" }
        return model
    }

    static var isConfigured: Bool { apiKey != nil }
}

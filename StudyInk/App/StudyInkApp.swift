import SwiftUI
import UIKit

@main
struct StudyInkApp: App {
    let persistence = PersistenceController.shared
    @AppStorage("settings.appearance") private var appearance = "system"
    @AppStorage("settings.theme") private var themeRaw = AppTheme.paperInk.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistence.viewContext)
                // nil falls back to the system appearance; setting the scheme on the
                // root view switches instantly with no relaunch or flash.
                .preferredColorScheme(preferredScheme)
                // Both modifiers on purpose: .tint drives system controls, the
                // (deprecated) .accentColor keeps every explicit
                // Color.accentColor call site on-theme.
                .tint(theme.accent)
                .accentColor(theme.accent)
                // Each theme carries its own app icon.
                .onChange(of: themeRaw) { _, _ in applyAppIcon() }
                .task { applyAppIcon() }
        }
    }

    /// Swap the home-screen icon to match the active theme (no-op if already set).
    private func applyAppIcon() {
        let desired = theme.iconName
        guard UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != desired else { return }
        UIApplication.shared.setAlternateIconName(desired)
    }

    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .paperInk }

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

/// App-wide design themes, picked in Settings. Each pairs a "you" accent (the
/// UI tint + your ink) with an "AI" accent (only ever marks the study partner),
/// and swaps the app icon. The base look (warm Paper & Ink) is shared; themes
/// change the two accents. `paperInk` (indigo · teal) is the default.
enum AppTheme: String, CaseIterable, Identifiable {
    case paperInk, bright, editorial, grounded, minimal, notebook

    var id: String { rawValue }

    /// The "you" accent — UI tint, your ink, selection.
    var accent: Color {
        switch self {
        case .paperInk:  return Color(red: 0.357, green: 0.341, blue: 0.910)  // ink indigo
        case .bright:    return Color(red: 0.176, green: 0.357, blue: 1.000)  // cobalt
        case .editorial: return Color(red: 0.420, green: 0.247, blue: 0.627)  // plum
        case .grounded:  return Color(red: 0.184, green: 0.490, blue: 0.329)  // forest
        case .minimal:   return Color(red: 0.200, green: 0.216, blue: 0.239)  // graphite
        case .notebook:  return Color(red: 0.698, green: 0.227, blue: 0.282)  // crimson
        }
    }

    /// The "AI" accent — the study partner's colour.
    var aiAccent: Color {
        switch self {
        case .paperInk:  return Color(red: 0.094, green: 0.722, blue: 0.651)  // teal
        case .bright:    return Color(red: 1.000, green: 0.435, blue: 0.380)  // coral
        case .editorial: return Color(red: 0.851, green: 0.643, blue: 0.255)  // gold
        case .grounded:  return Color(red: 0.824, green: 0.451, blue: 0.290)  // clay
        case .minimal:   return Color(red: 0.169, green: 0.659, blue: 0.871)  // sky
        case .notebook:  return Color(red: 0.518, green: 0.663, blue: 0.549)  // sage
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .paperInk:  return "theme.paperInk"
        case .bright:    return "theme.bright"
        case .editorial: return "theme.editorial"
        case .grounded:  return "theme.grounded"
        case .minimal:   return "theme.minimal"
        case .notebook:  return "theme.notebook"
        }
    }

    /// Alternate app-icon name for this theme; nil = the primary (default) icon.
    var iconName: String? { self == .paperInk ? nil : "AppIcon-\(rawValue)" }

    /// Current theme from storage — for non-SwiftUI / static read sites (the
    /// AI accent). SwiftUI views should prefer @AppStorage for reactivity.
    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "settings.theme") ?? "") ?? .paperInk
    }
}

/// Typed accessors for the semantic palette so call sites can't typo a token name.
enum SemanticColor {
    static let paperBackground = Color("paperBackground")
    static let canvasBackground = Color("canvasBackground")
    static let templateLine = Color("templateLine")
    static let toolbarBackground = Color("toolbarBackground")
    static let toolbarBorder = Color("toolbarBorder")
    static let sidebarBackground = Color("sidebarBackground")
    static let primaryText = Color("primaryText")
    static let secondaryText = Color("secondaryText")
    static let aiPanelBackground = Color("aiPanelBackground")
    static let aiMessageBubble = Color("aiMessageBubble")
    static let userMessageBubble = Color("userMessageBubble")
    static let accentBlue = Color("accentBlue")
    static let aiBubbleBorder = Color("aiBubbleBorder")
    static let aiHighlightYellow = Color("aiHighlightYellow")
    static let aiHighlightBlue = Color("aiHighlightBlue")
    static let aiCircleStroke = Color("aiCircleStroke")
    static let aiArrow = Color("aiArrow")
}

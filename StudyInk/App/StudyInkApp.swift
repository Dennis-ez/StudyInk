import SwiftUI

@main
struct StudyInkApp: App {
    let persistence = PersistenceController.shared
    @AppStorage("settings.appearance") private var appearance = "system"
    @AppStorage("settings.theme") private var themeRaw = AppTheme.classic.rawValue

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
        }
    }

    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .classic }

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

/// App-wide accent themes, picked in Settings.
enum AppTheme: String, CaseIterable, Identifiable {
    case classic, violet, forest, sunset, rose, graphite

    var id: String { rawValue }

    var accent: Color {
        switch self {
        case .classic: return Color(red: 0.04, green: 0.52, blue: 1.0)      // iOS blue
        case .violet: return Color(red: 0.48, green: 0.36, blue: 0.95)
        case .forest: return Color(red: 0.13, green: 0.62, blue: 0.42)
        case .sunset: return Color(red: 0.95, green: 0.52, blue: 0.18)
        case .rose: return Color(red: 0.91, green: 0.31, blue: 0.51)
        case .graphite: return Color(red: 0.45, green: 0.47, blue: 0.50)
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .classic: return "theme.classic"
        case .violet: return "theme.violet"
        case .forest: return "theme.forest"
        case .sunset: return "theme.sunset"
        case .rose: return "theme.rose"
        case .graphite: return "theme.graphite"
        }
    }
}

/// Typed accessors for the semantic palette so call sites can't typo a token name.
enum SemanticColor {
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

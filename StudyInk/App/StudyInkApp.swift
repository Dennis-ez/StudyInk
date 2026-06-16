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
                // AI surfaces use the theme's dedicated AI accent (the tutor's
                // colour), flowing down reactively so they update the instant
                // the theme changes.
                .environment(\.aiAccent, theme.aiAccent)
                .environment(\.themePaper, theme.paper)
                .environment(\.themeSidebar, theme.sidebar)
                .environment(\.themeDesk, theme.desk)
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

/// App-wide design themes (the "Foolscap" system), picked in Settings. Each
/// pairs a "you" accent (UI tint + your ink) with an "AI" accent (the tutor's
/// colour) and tints the chrome — content background, sidebar, editor desk.
/// The writing page and thumbnails are never themed. Dark chrome is shared
/// (warm charcoal); only the accents shift in dark. `paperInk` (Foolscap —
/// slate-blue · ochre) is the default.
///
/// `rawValue`s are stable storage ids kept from the previous theme set; the
/// display names are the Foolscap palette (Foolscap, Botanica, Plum, Marine,
/// Slate, Ember).
enum AppTheme: String, CaseIterable, Identifiable {
    case paperInk, bright, editorial, grounded, minimal, notebook

    var id: String { rawValue }

    /// Per-theme hex palette: light/dark accents + the three light chrome tints.
    private var hex: (youL: String, youD: String, aiL: String, aiD: String,
                      chrome: String, sidebar: String, desk: String) {
        switch self {
        case .paperInk:  return ("#2E4057", "#7FB0E8", "#B5762A", "#D9A24E", "#F6F0E4", "#EFE7D7", "#E7DECB") // Foolscap
        case .bright:    return ("#2F6048", "#7CC79E", "#C2683D", "#E08A5E", "#F1F4ED", "#E7EEE2", "#DCE6D6") // Botanica
        case .editorial: return ("#5B3A6B", "#C79BD6", "#B08328", "#D9A94E", "#F4EFF3", "#ECE3EC", "#E4D6E2") // Plum
        case .grounded:  return ("#1F5E63", "#6FC2C7", "#C45B45", "#E0846B", "#ECF3F2", "#E2EDEC", "#D5E6E4") // Marine
        case .minimal:   return ("#3C4149", "#9AA0AA", "#9A7B45", "#C5A36A", "#F1F1F2", "#E8E8EA", "#DEDEE1") // Slate
        case .notebook:  return ("#8A3B33", "#E08077", "#B5762A", "#D9A24E", "#F7EFEA", "#F1E4DD", "#ECD9CF") // Ember
        }
    }

    // Shared dark chrome (Foolscap dark set) for every theme.
    private static let darkChrome  = "#232019"
    private static let darkSidebar = "#1E1B15"
    private static let darkDesk    = "#15130F"

    private static func dynamicUI(_ light: String, _ dark: String) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark
            ? (UIColor(hex: dark) ?? .black)
            : (UIColor(hex: light) ?? .white) }
    }
    private static func dynamic(_ light: String, _ dark: String) -> Color {
        Color(uiColor: dynamicUI(light, dark))
    }

    /// The "you" accent — UI tint, your ink, selection.
    var accent: Color { Self.dynamic(hex.youL, hex.youD) }
    /// The "AI" accent — the tutor's colour.
    var aiAccent: Color { Self.dynamic(hex.aiL, hex.aiD) }
    /// Library/editor content background (chromePaper).
    var paper: Color { Self.dynamic(hex.chrome, Self.darkChrome) }
    /// The sidebar — a half-step into the theme.
    var sidebar: Color { Self.dynamic(hex.sidebar, Self.darkSidebar) }
    /// The editor "desk" behind the page / under floating panels. Exposed as
    /// UIColor too for the UIKit scroll view that draws the canvas backdrop.
    var deskUIColor: UIColor { Self.dynamicUI(hex.desk, Self.darkDesk) }
    var desk: Color { Color(uiColor: deskUIColor) }
    /// Hairlines / borders.
    var separator: Color { Self.dynamic("#DED3BE", "#34302A") }

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

    /// Alternate app-icon name for this theme. Per-theme icons are regenerated
    /// in a later phase of the Foolscap redesign; until then every theme uses
    /// the primary icon.
    var iconName: String? { nil }

    /// Current theme from storage — for non-SwiftUI / static read sites.
    /// SwiftUI views should prefer @AppStorage / the environment for reactivity.
    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "settings.theme") ?? "") ?? .paperInk
    }
}

/// The current theme's AI accent, propagated through the environment so AI
/// views re-render the moment the theme changes.
private struct AIAccentKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.paperInk.aiAccent
}
private struct ThemePaperKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.paperInk.paper
}
private struct ThemeSidebarKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.paperInk.sidebar
}
private struct ThemeDeskKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.paperInk.desk
}
extension EnvironmentValues {
    var aiAccent: Color {
        get { self[AIAccentKey.self] }
        set { self[AIAccentKey.self] = newValue }
    }
    var themePaper: Color {
        get { self[ThemePaperKey.self] }
        set { self[ThemePaperKey.self] = newValue }
    }
    var themeSidebar: Color {
        get { self[ThemeSidebarKey.self] }
        set { self[ThemeSidebarKey.self] = newValue }
    }
    var themeDesk: Color {
        get { self[ThemeDeskKey.self] }
        set { self[ThemeDeskKey.self] = newValue }
    }
}

/// Typed accessors for the semantic palette so call sites can't typo a token name.
///
/// Chrome tokens (panels, bubbles, borders) are *computed* from the active
/// theme so every surface in the app follows the theme with no per-call-site
/// wiring — they refresh whenever their view re-renders on a theme change.
/// Page-content tokens (`canvasBackground`, `templateLine`, the AI annotation
/// colours drawn onto the page) stay fixed assets so pages/thumbnails keep
/// their default look.
enum SemanticColor {
    // Page content — fixed, never themed.
    static let canvasBackground = Color("canvasBackground")
    static let templateLine = Color("templateLine")
    static let primaryText = Color("primaryText")
    static let secondaryText = Color("secondaryText")
    static let aiHighlightYellow = Color("aiHighlightYellow")
    static let aiHighlightBlue = Color("aiHighlightBlue")
    static let aiCircleStroke = Color("aiCircleStroke")
    static let aiArrow = Color("aiArrow")
    static let accentBlue = Color("accentBlue")

    // Chrome — follows the active theme.
    static var paperBackground: Color { AppTheme.current.paper }
    static var sidebarBackground: Color { AppTheme.current.sidebar }
    static var toolbarBackground: Color { AppTheme.current.sidebar }
    static var aiPanelBackground: Color { AppTheme.current.sidebar }
    /// AI's message card — the light paper tone so it reads as a card on the
    /// (sidebar-toned) panel.
    static var aiMessageBubble: Color { AppTheme.current.paper }
    /// Your message — the theme accent (used at low opacity at call sites).
    static var userMessageBubble: Color { AppTheme.current.accent }
    /// Warm hairlines / borders (Foolscap `separator`).
    static var separator: Color { AppTheme.current.separator }
    static var cardEdge: Color { AppTheme.current.separator }
    static var toolbarBorder: Color { AppTheme.current.separator }
    static var aiBubbleBorder: Color { AppTheme.current.separator }
}

import SwiftUI
import UIKit

@main
struct StudyInkApp: App {
    let persistence = PersistenceController.shared
    @AppStorage("settings.appearance") private var appearance = "system"
    @AppStorage("settings.theme") private var themeRaw = AppTheme.foolscap.rawValue

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

    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .foolscap }

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

/// App-wide design skins (v2 handoff): four distinct themes — **Foolscap**
/// (warm paper, navy ink, amber tutor), **Neon** (cyberpunk, dark-native),
/// **Daylight** (crisp white, indigo), **Graphite** (e-ink monochrome). One
/// token contract; each skin rebinds every semantic token (light + dark) and
/// tunes the card radius. The writing page (`paper`) and thumbnails are never
/// re-tinted by chrome. `foolscap` is the default.
enum AppTheme: String, CaseIterable, Identifiable {
    case foolscap, neon, daylight, graphite

    var id: String { rawValue }

    /// Every semantic token as (light, dark) hex, plus per-skin card radius and
    /// the AI-highlight alpha.
    struct Tokens {
        let primary, secondary: (String, String)
        let bgDesk, bgSidebar, bgChrome, surface, surface2, paper: (String, String)
        let border, borderStrong: (String, String)
        let text, textMuted, textRadiant: (String, String)
        let primarySoft, secondarySoft: (String, String)
        let success, destructive: (String, String)
        let aiCircle, aiArrow, aiUnderline, aiHi: (String, String)
        let aiHiAlpha: Double
        let radiusCard: CGFloat
    }

    var tokens: Tokens {
        switch self {
        case .foolscap:
            return Tokens(
                primary: ("#2E4057", "#7FB0E8"), secondary: ("#B5762A", "#D9A24E"),
                bgDesk: ("#E7DECB", "#15130F"), bgSidebar: ("#EFE7D7", "#1E1B15"),
                bgChrome: ("#F6F0E4", "#232019"), surface: ("#FCFAF5", "#2A261E"),
                surface2: ("#F0E8D8", "#322D24"), paper: ("#FCFAF5", "#1A1814"),
                border: ("#E0D6C2", "#38332B"), borderStrong: ("#D2C5AC", "#4A443A"),
                text: ("#2B2722", "#F2ECE0"), textMuted: ("#8A8073", "#9A9082"),
                textRadiant: ("#14110D", "#FFFFFF"),
                primarySoft: ("#DDE2E9", "#26303B"), secondarySoft: ("#EFE2CC", "#37301F"),
                success: ("#6B8E4E", "#8FBF6A"), destructive: ("#C0392B", "#FF6A5A"),
                aiCircle: ("#FF9F0A", "#FF9F0A"), aiArrow: ("#6B8E4E", "#30D158"),
                aiUnderline: ("#2E4057", "#7FB0E8"), aiHi: ("#FFD60A", "#FFD60A"),
                aiHiAlpha: 0.38, radiusCard: 14)
        case .neon:
            return Tokens(
                primary: ("#0E97B0", "#22D3EE"), secondary: ("#B0249E", "#F062E8"),
                bgDesk: ("#EAECF4", "#07070C"), bgSidebar: ("#F4F5FA", "#0B0B12"),
                bgChrome: ("#FFFFFF", "#0E0E17"), surface: ("#FFFFFF", "#14141F"),
                surface2: ("#F1F2F8", "#1B1B29"), paper: ("#FFFFFF", "#101019"),
                border: ("#E2E3EE", "#232338"), borderStrong: ("#CDCFE0", "#34344F"),
                text: ("#15151F", "#E6E8F2"), textMuted: ("#6A6D86", "#7C7F9E"),
                textRadiant: ("#000000", "#FFFFFF"),
                primarySoft: ("#D6F3F8", "#0E2733"), secondarySoft: ("#F6D9F2", "#2A0E28"),
                success: ("#0E9C6B", "#2BF5A0"), destructive: ("#D6224E", "#FF3B6B"),
                aiCircle: ("#D6224E", "#FF7AC6"), aiArrow: ("#0E9C6B", "#2BF5A0"),
                aiUnderline: ("#0E97B0", "#22D3EE"), aiHi: ("#F5F021", "#F5F021"),
                aiHiAlpha: 0.28, radiusCard: 10)
        case .daylight:
            return Tokens(
                primary: ("#3B5BFF", "#6488FF"), secondary: ("#7C3AED", "#A78BFA"),
                bgDesk: ("#EEF0F4", "#0B0D12"), bgSidebar: ("#F7F8FA", "#0F1219"),
                bgChrome: ("#FFFFFF", "#11141B"), surface: ("#FFFFFF", "#161A22"),
                surface2: ("#F2F4F7", "#1E232D"), paper: ("#FFFFFF", "#14171E"),
                border: ("#E3E6EC", "#232A35"), borderStrong: ("#CDD2DB", "#323B48"),
                text: ("#0F172A", "#E7EAF0"), textMuted: ("#64748B", "#8B95A7"),
                textRadiant: ("#000000", "#FFFFFF"),
                primarySoft: ("#E3E8FF", "#1A2440"), secondarySoft: ("#EFE6FE", "#241A3D"),
                success: ("#16A34A", "#34D17A"), destructive: ("#E11D48", "#FB4E72"),
                aiCircle: ("#F59E0B", "#F59E0B"), aiArrow: ("#16A34A", "#34D17A"),
                aiUnderline: ("#3B5BFF", "#6488FF"), aiHi: ("#FFE45C", "#FFE45C"),
                aiHiAlpha: 0.45, radiusCard: 10)
        case .graphite:
            return Tokens(
                primary: ("#1A1A1A", "#EDEDED"), secondary: ("#5A5A52", "#ABABAB"),
                bgDesk: ("#E8E8E4", "#161616"), bgSidebar: ("#F2F2EE", "#1C1C1C"),
                bgChrome: ("#FAFAF7", "#202020"), surface: ("#FFFFFF", "#262626"),
                surface2: ("#F0F0EC", "#2E2E2E"), paper: ("#FCFCFA", "#1B1B1B"),
                border: ("#D8D8D2", "#353535"), borderStrong: ("#B8B8B2", "#4A4A4A"),
                text: ("#141414", "#ECECEC"), textMuted: ("#76766E", "#9A9A9A"),
                textRadiant: ("#000000", "#FFFFFF"),
                primarySoft: ("#E2E2DE", "#2E2E2E"), secondarySoft: ("#E6E6E0", "#333333"),
                success: ("#141414", "#ECECEC"), destructive: ("#141414", "#ECECEC"),
                aiCircle: ("#1A1A1A", "#EDEDED"), aiArrow: ("#1A1A1A", "#EDEDED"),
                aiUnderline: ("#1A1A1A", "#EDEDED"), aiHi: ("#000000", "#FFFFFF"),
                aiHiAlpha: 0.09, radiusCard: 6)
        }
    }

    private static func dynamicUI(_ pair: (String, String)) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark
            ? (UIColor(hex: pair.1) ?? .black)
            : (UIColor(hex: pair.0) ?? .white) }
    }
    private static func dynamic(_ pair: (String, String)) -> Color {
        Color(uiColor: dynamicUI(pair))
    }

    // Public semantic API (kept stable for existing call sites).
    /// The "you" accent — UI tint, your ink, selection.
    var accent: Color { Self.dynamic(tokens.primary) }
    /// The "AI" accent — the tutor's colour.
    var aiAccent: Color { Self.dynamic(tokens.secondary) }
    /// Library/editor content background (chromePaper).
    var paper: Color { Self.dynamic(tokens.bgChrome) }
    var sidebar: Color { Self.dynamic(tokens.bgSidebar) }
    var deskUIColor: UIColor { Self.dynamicUI(tokens.bgDesk) }
    var desk: Color { Color(uiColor: deskUIColor) }
    /// Card / panel surface.
    var surface: Color { Self.dynamic(tokens.surface) }
    var surface2: Color { Self.dynamic(tokens.surface2) }
    var separator: Color { Self.dynamic(tokens.border) }
    var separatorStrong: Color { Self.dynamic(tokens.borderStrong) }
    /// Selected sidebar-row fill.
    var fillSelected: Color { Self.dynamic(tokens.primarySoft) }
    var textPrimary: Color { Self.dynamic(tokens.text) }
    var textMuted: Color { Self.dynamic(tokens.textMuted) }
    var successColor: Color { Self.dynamic(tokens.success) }
    var destructiveColor: Color { Self.dynamic(tokens.destructive) }
    var aiCircleColor: Color { Self.dynamic(tokens.aiCircle) }
    var aiArrowColor: Color { Self.dynamic(tokens.aiArrow) }
    var aiUnderlineColor: Color { Self.dynamic(tokens.aiUnderline) }
    var aiHighlight: Color { Self.dynamic(tokens.aiHi).opacity(tokens.aiHiAlpha) }
    var cardRadius: CGFloat { tokens.radiusCard }

    var labelKey: LocalizedStringKey {
        switch self {
        case .foolscap: return "theme.foolscap"
        case .neon:     return "theme.neon"
        case .daylight: return "theme.daylight"
        case .graphite: return "theme.graphite"
        }
    }

    /// Alternate app-icon name; nil = the primary (Foolscap) icon. Each of the
    /// other three skins has its own alternate icon (AppIcon-<rawValue>).
    var iconName: String? { self == .foolscap ? nil : "AppIcon-\(rawValue)" }

    /// Current theme from storage — for non-SwiftUI / static read sites.
    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "settings.theme") ?? "") ?? .foolscap
    }
}

/// The current theme's AI accent, propagated through the environment so AI
/// views re-render the moment the theme changes.
private struct AIAccentKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.foolscap.aiAccent
}
private struct ThemePaperKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.foolscap.paper
}
private struct ThemeSidebarKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.foolscap.sidebar
}
private struct ThemeDeskKey: EnvironmentKey {
    static let defaultValue: Color = AppTheme.foolscap.desk
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
    static var fillSelected: Color { AppTheme.current.fillSelected }
    static var toolbarBorder: Color { AppTheme.current.separator }
    static var aiBubbleBorder: Color { AppTheme.current.separator }
    /// Card / panel surface (lighter than chrome).
    static var surface: Color { AppTheme.current.surface }
    static var surface2: Color { AppTheme.current.surface2 }
    static var textPrimary: Color { AppTheme.current.textPrimary }
    static var textMutedColor: Color { AppTheme.current.textMuted }
    static var success: Color { AppTheme.current.successColor }
    static var destructive: Color { AppTheme.current.destructiveColor }
}

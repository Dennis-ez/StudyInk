import SwiftUI

@main
struct StudyInkApp: App {
    let persistence = PersistenceController.shared
    @AppStorage("settings.appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistence.viewContext)
                // nil falls back to the system appearance; setting the scheme on the
                // root view switches instantly with no relaunch or flash.
                .preferredColorScheme(preferredScheme)
        }
    }

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
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

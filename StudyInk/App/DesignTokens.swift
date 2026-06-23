import SwiftUI

/// The Foolscap design system's non-color tokens — radii, spacing, elevation,
/// and the named motion curves. Color tokens live on `AppTheme` / `SemanticColor`.
/// Source of truth: DesignHandoff/README.md.
enum DS {
    // MARK: Corner radius
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // MARK: Spacing (8-pt grid)
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
        static let huge: CGFloat = 48
    }

    // MARK: Stroke width
    enum Stroke {
        static let hairline: CGFloat = 1
        static let thin: CGFloat = 1.5
        static let regular: CGFloat = 2
        static let thick: CGFloat = 3
    }

    // MARK: Elevation (warm-black ambient shadow)
    struct Elevation {
        let opacity: Double
        let radius: CGFloat
        let y: CGFloat
        /// Cards.
        static let e1 = Elevation(opacity: 0.06, radius: 1, y: 1)
        /// Toolbar, popovers.
        static let e2 = Elevation(opacity: 0.14, radius: 12, y: 6)
        /// AI bubble, sheets.
        static let e3 = Elevation(opacity: 0.22, radius: 22, y: 10)
        static let color = Color(red: 0.157, green: 0.133, blue: 0.110) // #28221C
    }

    // MARK: Motion (named transitions)
    enum Motion {
        static let viewPush     = Animation.spring(response: 0.45, dampingFraction: 0.82)
        static let sheetPresent = Animation.spring(response: 0.50, dampingFraction: 0.85)
        static let toolbarDock  = Animation.spring(response: 0.38, dampingFraction: 0.80)
        static let bubbleAppear = Animation.spring(response: 0.32, dampingFraction: 0.78)
        static let selection    = Animation.easeOut(duration: 0.12)
        static let pageTurn     = Animation.easeInOut(duration: 0.45)
    }
}

extension View {
    /// Apply a Foolscap elevation token.
    func elevation(_ e: DS.Elevation) -> some View {
        shadow(color: DS.Elevation.color.opacity(e.opacity), radius: e.radius, x: 0, y: e.y)
    }
}

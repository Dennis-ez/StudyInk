import SwiftUI

/// A bundled Lucide icon (the design system's line-icon set), rendered as a
/// tintable template image so it follows `foregroundStyle`/the theme accent.
/// Assets live in Assets.xcassets as `lucide-<name>` template SVGs.
///
/// Usage: `Lucide("pen")` or `Lucide("wand-sparkles", size: 18)`.
struct Lucide: View {
    let name: String
    var size: CGFloat

    init(_ name: String, size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image("lucide-\(name)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

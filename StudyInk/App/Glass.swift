import SwiftUI

/// The app's chrome surface treatment. Per the Foolscap design, floating chrome
/// (toolbar, AI panel, page indicator, pinned chips) is a warm **chromePaper**
/// card — opaque, hairline-bordered, softly lifted — NOT neutral liquid glass.
/// Because the fill is the theme's paper, every surface follows the active theme.
struct StudyGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.themePaper) private var themePaper

    func body(content: Content) -> some View {
        content
            .background(themePaper, in: shape)
            .overlay(shape.strokeBorder(SemanticColor.separator, lineWidth: 1))
            .elevation(.e2)
    }
}

extension View {
    func studyGlass(cornerRadius: CGFloat = 20) -> some View {
        modifier(StudyGlass(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }

    func studyGlassCapsule() -> some View {
        modifier(StudyGlass(shape: Capsule()))
    }
}

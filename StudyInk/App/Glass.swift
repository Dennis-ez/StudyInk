import SwiftUI

/// The app's "liquid glass" surface treatment. On iOS 26+ this is the real
/// system glass effect; earlier OSes get a convincing material fallback
/// (ultra-thin material + specular gradient edge + soft shadow).
struct StudyGlass<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // A faint accent tint so glass chrome (toolbar, AI panel) carries
            // the active theme instead of reading as neutral grey.
            content.glassEffect(.regular.tint(Color.accentColor.opacity(0.10)), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(Color.accentColor.opacity(0.07), in: shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.45), .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        }
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

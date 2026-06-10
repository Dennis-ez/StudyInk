import UIKit

/// Centralized haptic vocabulary so interactions feel consistent app-wide.
enum Haptics {
    /// Discrete selection changes: picking a tool, snapping to a page.
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Light physical taps: pinning a bubble, dismissing a card.
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// An AI response (or other long-running result) arrived.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

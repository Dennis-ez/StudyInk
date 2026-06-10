import Foundation
import CoreGraphics

// MARK: - Annotations

/// A visual mark Claude asks the app to draw on the canvas overlay.
struct AIAnnotationModel: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case circle, highlight, arrow, underline
    }

    var id = UUID()
    var kind: Kind
    /// OCR string the annotation targets (resolved to a rect against OCR lines).
    var matchString: String?
    /// Resolved target rect in page coordinates; nil until matched.
    var rectX: Double?
    var rectY: Double?
    var rectW: Double?
    var rectH: Double?
    /// Semantic color token name (aiHighlightYellow, aiCircleStroke, …).
    var colorToken: String

    var rect: CGRect? {
        get {
            guard let rectX, let rectY, let rectW, let rectH else { return nil }
            return CGRect(x: rectX, y: rectY, width: rectW, height: rectH)
        }
        set {
            // Plain unwrapping; `Optional.map(\.keyPath)` mis-resolves to
            // SwiftUI's Gesture.map overload and breaks the build.
            if let rect = newValue {
                rectX = rect.origin.x
                rectY = rect.origin.y
                rectW = rect.width
                rectH = rect.height
            } else {
                rectX = nil
                rectY = nil
                rectW = nil
                rectH = nil
            }
        }
    }

    var defaultToken: String {
        switch kind {
        case .circle: return "aiCircleStroke"
        case .highlight: return "aiHighlightYellow"
        case .arrow: return "aiArrow"
        case .underline: return "accentBlue"
        }
    }
}

// MARK: - Bubble

/// One Q&A turn inside a bubble thread.
struct AIExchange: Codable, Equatable, Identifiable {
    var id = UUID()
    /// nil for proactive (guided-mode) openers.
    var question: String?
    var answer: String
}

/// The tone of a response, mapped to the bubble's left border strip.
enum AIBubbleTone: String, Codable {
    case explanation   // blue
    case encouragement // green
    case correction    // orange
    case error         // red

    var colorToken: String {
        switch self {
        case .explanation: return "accentBlue"
        case .encouragement: return "aiArrow"
        case .correction: return "aiCircleStroke"
        case .error: return "errorRed"
        }
    }
}

/// A floating AI response card anchored to canvas content. Bubbles are overlay
/// state, never ink; pinned bubbles serialize into the page.
struct AIBubbleModel: Codable, Equatable, Identifiable {
    var id = UUID()
    var pageIndex: Int
    /// What the bubble points at, in page coordinates.
    var anchorX: Double
    var anchorY: Double
    /// Card position (top-leading), draggable by the student.
    var x: Double
    var y: Double
    var width: Double = 320
    var tone: AIBubbleTone = .explanation
    var thread: [AIExchange] = []
    var chips: [String] = []
    var annotations: [AIAnnotationModel] = []
    var isPinned = false
    var isCollapsed = false
    var createdAt = Date()

    var anchor: CGPoint { CGPoint(x: anchorX, y: anchorY) }
    var latestAnswer: String { thread.last?.answer ?? "" }

    /// Places the card beside the anchor, flipping to whichever side of the page
    /// has room; clamps inside the page bounds.
    static func position(anchor: CGPoint, pageSize: CGSize, width: Double = 320, estimatedHeight: Double = 180) -> CGPoint {
        var x = anchor.x + 36
        if x + width > pageSize.width - 12 {
            x = anchor.x - width - 36
        }
        x = max(12, min(x, pageSize.width - width - 12))
        var y = anchor.y - 24
        y = max(12, min(y, pageSize.height - estimatedHeight - 12))
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Parsed response

/// Everything extracted from one Claude reply.
struct AIParsedResponse: Equatable {
    var text: String
    var annotations: [AIAnnotationModel]
    var chips: [String]
    var tone: AIBubbleTone
}

/// Rough text-direction probe for RTL bubble layout.
extension String {
    var isMostlyRTL: Bool {
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x0590...0x05FF, 0xFB1D...0xFB4F, 0x0600...0x06FF: return true
            case 0x0041...0x005A, 0x0061...0x007A: return false
            default: continue
            }
        }
        return false
    }

    /// True when the text likely contains LaTeX worth a KaTeX render pass.
    var containsLaTeX: Bool {
        contains("$") || contains("\\(") || contains("\\[") || contains("\\frac") || contains("\\int") || contains("\\sum")
    }
}

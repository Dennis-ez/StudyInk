import PencilKit
import SwiftUI

/// User-facing tool identity. The "logical color" the user picked is stored separately
/// from the rendered color so dark mode can remap ink (see InkColorAdapter, phase 4).
enum ToolKind: String, CaseIterable, Codable, Identifiable {
    case ballpoint, fountain, monoline, highlighter, pencil
    case eraserPixel, eraserObject, lasso, hand

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .ballpoint: return "pencil.tip"
        case .fountain: return "paintbrush.pointed"
        case .monoline: return "pencil.line"
        case .highlighter: return "highlighter"
        case .pencil: return "pencil"
        case .eraserPixel: return "eraser"
        case .eraserObject: return "eraser.line.dashed"
        case .lasso: return "lasso"
        case .hand: return "hand.draw"
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .ballpoint: return "tool.ballpoint"
        case .fountain: return "tool.fountain"
        case .monoline: return "tool.monoline"
        case .highlighter: return "tool.highlighter"
        case .pencil: return "tool.pencil"
        case .eraserPixel: return "tool.eraser.pixel"
        case .eraserObject: return "tool.eraser.object"
        case .lasso: return "tool.lasso"
        case .hand: return "tool.hand"
        }
    }

    var isInking: Bool {
        switch self {
        case .ballpoint, .fountain, .monoline, .highlighter, .pencil: return true
        default: return false
        }
    }
}

/// Complete tool state: kind + per-kind color/width/opacity, persisted across launches.
struct ToolState: Codable, Equatable {
    var kind: ToolKind = .ballpoint
    var colorHex: String = "#000000"
    var width: Double = 4
    var opacity: Double = 1.0
    /// Pressure-sensitive ink (pen/fountain respond to Pencil force); off = constant width.
    var pressureSensitive: Bool = true

    /// Builds the PencilKit tool. `darkMode` drives ink remapping: pure black ink
    /// renders near-white on a dark canvas while the stored logical color is unchanged.
    func pkTool(darkMode: Bool) -> PKTool {
        switch kind {
        case .eraserPixel: return PKEraserTool(.bitmap, width: width)
        case .eraserObject: return PKEraserTool(.vector)
        case .lasso: return PKLassoTool()
        // Drawing is disabled while the hand tool is active; the tool itself is inert.
        case .hand: return PKLassoTool()
        case .ballpoint, .fountain, .monoline, .highlighter, .pencil:
            // What the user sees while drawing should be exactly this color:
            var base = InkColorAdapter.rendered(from: UIColor(hex: colorHex) ?? .black, darkMode: darkMode)
            if darkMode {
                // PencilKit re-interprets tool colors against the current
                // appearance (storing a light-mode equivalent and inverting at
                // display). Without this pre-conversion our dark-adapted color
                // gets inverted a second time — black AND white both came out
                // black on the dark canvas.
                base = PKInkingTool.convertColor(base, from: .dark, to: .light)
            }
            let color = base.withAlphaComponent(kind == .highlighter ? min(opacity, 0.6) : opacity)
            return PKInkingTool(inkType, color: color, width: width)
        }
    }

    private var inkType: PKInkingTool.InkType {
        switch kind {
        // With pressure off, force-responsive inks fall back to constant-width monoline.
        case .ballpoint: return pressureSensitive ? .pen : .monoline
        case .fountain: return pressureSensitive ? .fountainPen : .monoline
        case .monoline: return .monoline
        case .highlighter: return .marker
        case .pencil: return .pencil
        default: return .pen
        }
    }
}

extension ToolState {
    private enum CodingKeys: String, CodingKey {
        case kind, colorHex, width, opacity, pressureSensitive
    }

    // Hand-rolled so tool states persisted before `pressureSensitive` existed still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ToolKind.self, forKey: .kind)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        width = try c.decode(Double.self, forKey: .width)
        opacity = try c.decode(Double.self, forKey: .opacity)
        pressureSensitive = try c.decodeIfPresent(Bool.self, forKey: .pressureSensitive) ?? true
    }
}

/// Maps the user's logical ink color to a rendered color per appearance mode.
/// Black ↔ near-white swap; saturated colors get a brightness lift in dark mode.
enum InkColorAdapter {
    static func rendered(from logical: UIColor, darkMode: Bool) -> UIColor {
        guard darkMode else { return logical }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        logical.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.15 && b < 0.3 {
            // Black-ish ink → near-white, like Notability.
            return UIColor(white: 0.92, alpha: a)
        }
        return UIColor(hue: h, saturation: s, brightness: min(1.0, b + 0.18), alpha: a)
    }
}

// MARK: - Hex color plumbing

extension UIColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

extension Color {
    init?(hex: String) {
        guard let ui = UIColor(hex: hex) else { return nil }
        self.init(uiColor: ui)
    }
}

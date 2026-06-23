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
        case .fountain: return "pencil.and.outline"
        case .monoline: return "pencil.line"
        case .highlighter: return "highlighter"
        case .pencil: return "pencil"
        case .eraserPixel: return "eraser"
        case .eraserObject: return "eraser.line.dashed"
        case .lasso: return "lasso"
        case .hand: return "hand.draw"
        }
    }

    /// Bundled Lucide glyph name (v2 redesign). Rendered via `Lucide(name:)`
    /// in the floating toolbar; `symbolName` stays the SF Symbol fallback used
    /// by the customize sheet and any non-Lucide surface.
    var lucideName: String {
        switch self {
        case .ballpoint: return "pen"
        case .fountain: return "pen-tool"
        case .monoline: return "pen-line"
        case .highlighter: return "highlighter"
        case .pencil: return "pencil"
        case .eraserPixel, .eraserObject: return "eraser"
        case .lasso: return "lasso"
        case .hand: return "hand"
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
    /// `widthScale` is the live canvas's supersample factor (inkScale): the
    /// canvas works in inkScale× coordinates for native-sharp zoom, so a pen the
    /// user picked as 4pt must be 4×inkScale in canvas space to *look* 4pt. The
    /// stored stroke is scaled back to canonical on save, so widths stay correct.
    func pkTool(darkMode: Bool, widthScale: CGFloat = 1) -> PKTool {
        let width = self.width * widthScale
        switch kind {
        case .eraserPixel: return PKEraserTool(.bitmap, width: width)
        case .eraserObject: return PKEraserTool(.vector, width: width)
        // NEVER PKLassoTool — it engages Apple's native lasso selection on top of
        // ours. Our lasso is driven by a separate pencil gesture; the canvas's
        // drawing gesture is disabled for these tools (see applyTool), so an inert
        // clear pen is fine and PencilKit simply never has a lasso tool to fire.
        case .lasso, .hand: return PKInkingTool(.pen, color: .clear, width: 1)
        case .ballpoint, .fountain, .monoline, .highlighter, .pencil:
            // iOS 26 SDK renders PencilKit tool/stroke colors LITERALLY (no
            // appearance re-interpretation), so the tool color must already be
            // the DISPLAY color: black ink → near-white on a dark canvas. No
            // convertColor — that pre-conversion inverted dark ink into
            // invisibility on this SDK. Storage stays canonical (the live
            // drawing is mapped back via InkColorAdapter.storageDrawing).
            let base = InkColorAdapter.displayColor(UIColor(hex: colorHex) ?? .black, darkMode: darkMode)
            let color = base.withAlphaComponent(kind == .highlighter ? min(opacity, 0.6) : opacity)
            let type = inkType
            // Constant-width inks (monoline = pressure-off pens) render at the FULL
            // nominal width, which reads much heavier than the tapered pressure pens
            // at the same size. Scale them down so the sizes feel consistent.
            let typeFactor: CGFloat = type == .monoline ? 0.38 : 1
            return PKInkingTool(type, color: color, width: width * typeFactor)
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

/// iOS 26 SDK renders PencilKit stroke colors LITERALLY, so dark-mode ink
/// adaptation is the app's job at DISPLAY time while storage stays canonical
/// (light appearance). The mapping is an invertible achromatic swap — black
/// ink ↔ near-white — so it round-trips losslessly; chromatic ink reads fine
/// on both the white and dark canvas and passes through untouched.
enum InkColorAdapter {
    /// The near-white used for black ink on a dark canvas (Notability-style).
    private static let darkInk = UIColor(white: 0.92, alpha: 1)

    /// Canonical (light/storage) → display color for the current appearance.
    static func displayColor(_ logical: UIColor, darkMode: Bool) -> UIColor {
        guard darkMode else { return logical }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        logical.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Black-ish ink → near-white.
        return (s < 0.2 && b < 0.25) ? darkInk.withAlphaComponent(a) : logical
    }

    /// Display → canonical (light/storage): the inverse of `displayColor`.
    static func storageColor(_ shown: UIColor, darkMode: Bool) -> UIColor {
        guard darkMode else { return shown }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        shown.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // The near-white we produced → back to black.
        return (s < 0.2 && b > 0.8) ? UIColor(white: 0, alpha: a) : shown
    }

    /// Storage → display for a whole drawing (load into a dark canvas/render).
    static func displayDrawing(_ drawing: PKDrawing, darkMode: Bool) -> PKDrawing {
        guard darkMode, !drawing.strokes.isEmpty else { return drawing }
        return mapInk(drawing) { displayColor($0, darkMode: true) }
    }

    /// Display → storage for a whole drawing (save back from a dark canvas).
    static func storageDrawing(_ drawing: PKDrawing, darkMode: Bool) -> PKDrawing {
        guard darkMode, !drawing.strokes.isEmpty else { return drawing }
        return mapInk(drawing) { storageColor($0, darkMode: true) }
    }

    private static func mapInk(_ drawing: PKDrawing, _ transform: (UIColor) -> UIColor) -> PKDrawing {
        var strokes = drawing.strokes
        for i in strokes.indices {
            let ink = strokes[i].ink
            let newColor = transform(ink.color)
            guard newColor != ink.color else { continue }
            strokes[i] = PKStroke(
                ink: PKInk(ink.inkType, color: newColor),
                path: strokes[i].path,
                transform: strokes[i].transform,
                mask: strokes[i].mask
            )
        }
        return PKDrawing(strokes: strokes)
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

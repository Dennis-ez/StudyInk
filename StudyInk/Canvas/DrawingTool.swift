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

    // MARK: Custom vector engine mapping (settings.canvas.customInk)

    /// The custom engine's config for this tool. Unlike `pkTool`, colours are
    /// CANONICAL (storage) — the engine maps to the current appearance at render
    /// time (VectorInkView.displayColor), and works in page coordinates (no inkScale).
    /// `.hand` returns `draws == false` so the mount can let a finger pan instead.
    struct VectorToolConfig {
        var tool: InkTool
        var color: UIColor       // canonical
        var width: CGFloat
        var draws: Bool          // false for hand → mount disables ink capture
        var widthVariation: CGFloat = 0   // 0 = constant; >0 = velocity/pressure taper (fountain)
    }

    func vectorTool() -> VectorToolConfig {
        let canonical = UIColor(hex: colorHex) ?? .black
        switch kind {
        case .eraserPixel, .eraserObject:
            return VectorToolConfig(tool: .eraser, color: canonical, width: width, draws: true)
        case .lasso:
            return VectorToolConfig(tool: .lasso, color: canonical, width: width, draws: true)
        case .hand:
            return VectorToolConfig(tool: .pen, color: canonical, width: width, draws: false)
        case .highlighter:
            // Opacity is user-controlled (the InkOptionsStrip slider), capped so it
            // stays a see-through highlight, never a solid fill.
            return VectorToolConfig(tool: .pen, color: canonical.withAlphaComponent(min(opacity, 0.6)),
                                    width: width * 2.2, draws: true)
        // Distinct pens (the engine is constant-width, so differentiate by weight +
        // opacity rather than taper): ballpoint fine & crisp, monoline medium-uniform,
        // fountain the boldest, pencil a soft translucent graphite.
        case .ballpoint:
            return VectorToolConfig(tool: .pen, color: canonical, width: width * 0.5, draws: true)
        case .monoline:
            return VectorToolConfig(tool: .pen, color: canonical, width: width * 0.6, draws: true)
        case .fountain:
            // The fountain pen tapers with speed + pressure (Notability-style); the
            // others stay constant (widthVariation defaults to 0).
            return VectorToolConfig(tool: .pen, color: canonical, width: width * 0.85, draws: true, widthVariation: 0.6)
        case .pencil:
            return VectorToolConfig(tool: .pen, color: canonical.withAlphaComponent(min(opacity, 0.8)),
                                    width: width * 0.62, draws: true)
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

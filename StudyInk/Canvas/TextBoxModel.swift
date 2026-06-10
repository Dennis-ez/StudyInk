import SwiftUI

/// A typed text box placed on the canvas, stored in page-space coordinates.
struct TextBoxModel: Codable, Equatable, Identifiable {
    var id = UUID()
    var x: Double
    var y: Double
    var width: Double = 260
    var height: Double = 60
    var text: String = ""
    var fontName: String = "SFPro"          // "SFPro" maps to the system font
    var fontSize: Double = 17
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var colorHex = "#000000"
    /// nil = automatic: RTL when the first strong character is Hebrew.
    var explicitAlignment: TextBoxAlignment?

    enum TextBoxAlignment: String, Codable { case leading, center, trailing }

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.origin.x; y = newValue.origin.y; width = newValue.width; height = newValue.height }
    }

    /// Unicode-bidi first-strong detection, limited to what we need:
    /// Hebrew block (incl. presentation forms) → RTL.
    var isRTL: Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x05FF, 0xFB1D...0xFB4F: return true     // Hebrew
            case 0x0041...0x005A, 0x0061...0x007A: return false    // Latin
            default: continue
            }
        }
        return Locale.characterDirection(forLanguage: Locale.preferredLanguages.first ?? "en") == .rightToLeft
    }

    var textAlignment: TextAlignment {
        switch explicitAlignment {
        case .leading: return isRTL ? .trailing : .leading
        case .center: return .center
        case .trailing: return isRTL ? .leading : .trailing
        case nil: return isRTL ? .trailing : .leading
        }
    }

    var uiFont: UIFont {
        var font: UIFont = fontName == "SFPro"
            ? .systemFont(ofSize: fontSize)
            : (UIFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize))
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: fontSize)
        }
        return font
    }
}

/// Fonts offered in the picker — Hebrew-friendly options included per spec.
enum TextBoxFonts {
    static let options: [(display: String, name: String)] = [
        ("SF Pro", "SFPro"),
        ("David", "DavidMF"),
        ("Arial Hebrew", "ArialHebrew"),
        ("Times New Roman", "TimesNewRomanPSMT"),
        ("Helvetica Neue", "HelveticaNeue"),
        ("Courier New", "CourierNewPSMT"),
    ]
}

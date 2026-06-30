import SwiftUI

/// Conote ambient-tutor design tokens — the **authoritative** palette, type, lane,
/// and motion constants from the AI handoff (`design_handoff_conote_ai`, §3). Views
/// for the five tutor surfaces (guided ladder, fill-in ghost, diagnostic, selection
/// rail, margin threads) pull every color/metric from here — **zero hardcoded hex in
/// views**. The paper/ink values intentionally mirror the Foolscap skin but are fixed
/// here so the tutor reads the same regardless of the active app skin (the spec:
/// "paper — NEVER theme-tinted").
enum AITokens {

    // MARK: builders

    /// Opaque color from a 0xRRGGBB literal.
    static func hex(_ rgb: UInt32, _ opacity: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((rgb >> 16) & 0xFF) / 255,
              green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255,
              opacity: opacity)
    }
    /// Color from literal 0–255 channels + alpha (for the spec's `rgba(...)` tokens).
    static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
    static func uiHex(_ rgb: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    // MARK: color — paper & rules

    static let paper        = hex(0xFCFAF5)        // writing surface — never theme-tinted
    static let ruleLine     = hex(0xEAE0CC)        // ruled lines (denser: 0xE7DDC8 / 0xE9DFCB)
    static let ruleLineDense = hex(0xE7DDC8)
    static let marginLine   = rgba(192, 57, 43, 0.20)   // faint red lane divider
    static let laneTint     = rgba(181, 118, 42, 0.06)  // amber lane wash (0 when tutor off)

    // MARK: color — ink

    static let inkStudent   = hex(0x2E4057)        // all student handwriting (Caveat)
    static let uiInkStudent = uiHex(0x2E4057)
    /// A suggestion = student ink, dimmed (NO box, NO pulse).
    static let inkGhostOpacity: Double = 0.33      // spec range 0.32–0.34

    // MARK: color — the AI (amber is always the tutor)

    static let ai           = hex(0xB5762A)        // all AI ink, glyphs, accents
    static let uiAI         = uiHex(0xB5762A)
    static let aiInkTagBg   = rgba(181, 118, 42, 0.10)  // "✦ AI ink" pill
    static let correction   = hex(0xD98714)        // ~ squiggle, correction/diagnostic accent
    static let errorRed     = hex(0xC0392B)        // strike-through of a wrong attempt
    static let success      = hex(0x6B8E4E)        // ✓ marks, "step revealed"
    static let successTint  = rgba(107, 142, 78, 0.16)

    // MARK: color — surfaces

    static let cardBg       = rgba(252, 250, 245, 0.98)
    static let cardRing     = hex(0xE6D9BE)        // 1px hairline
    static let cardShadow   = Color.black.opacity(0.32)   // 0 18–20 42–46 -16
    static let scaffoldBoxBg   = hex(0xF1E6CF)     // the 2a blank
    static let scaffoldBoxRing = hex(0xD9C49E)
    static let workedBox    = hex(0xF4EEE0)        // boxed correct answer / hint scaffold
    static let chipBg       = hex(0xF4ECDD)

    // MARK: color — text

    static let textInk      = hex(0x2B2722)
    static let textMuted    = hex(0x5C5447)
    static let textFaint    = hex(0x8A8073)
    static let textFainter  = hex(0x9A8A68)
    static let textGhost    = hex(0xA89E8B)
    /// rung-0 "static dot" cue used by the Subtle dial.
    static let subtleDot    = hex(0xC6B699)

    // MARK: color — dark panels (decision trace / code)

    static let panelDark    = hex(0x211D18)
    static let panelText    = hex(0xCABFA8)
    static let panelMuted   = hex(0x8D8472)
    static let codeKey      = hex(0xE0A85A)
    static let codeString   = hex(0x9FB985)

    // MARK: type

    /// Display / titles / labels — Fraunces (serif) 600. Falls back to the system
    /// serif if the face isn't bundled yet.
    static func fraunces(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .custom("Fraunces", size: size).weight(weight)
    }
    /// Handwriting — Caveat (student + ghost + accepted AI ink). For a Hebrew/RTL
    /// page pass `hebrew: true` → "Gveret Levin AlefAlefAlef" (fallback Caveat).
    static func caveat(_ size: CGFloat, _ weight: Font.Weight = .medium, hebrew: Bool = false) -> Font {
        .custom(hebrew ? "Gveret Levin AlefAlefAlef" : "Caveat", size: size).weight(weight)
    }
    /// Technical labels / kickers — SF Mono 10, UPPERCASE, tracked, textFainter.
    static func mono(_ size: CGFloat = 10, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: lane & glyphs

    enum Lane {
        static let widthSingle: CGFloat = 58   // single column (logical inline-start inset)
        static let widthColumn: CGFloat = 48   // per column (multi)
        static let widthRTL: CGFloat = 56
        static let glyphSize: CGFloat = 25     // 24–26pt circle
        static let tapTarget: CGFloat = 44     // ≥44pt via padding
    }

    // MARK: motion (§8 — at most ONE breathing element on screen, ever)

    enum Motion {
        /// The ONE allowed continuous loop: scale 1↔1.12, opacity 0.7↔1, 3.2–3.4s ease-in-out.
        static let breatheDuration: Double = 3.3
        static let breatheScaleTo: CGFloat = 1.12
        static let breatheOpacityFrom: Double = 0.7
        /// glyph in: scale 0.4→1, 0.3s, no bounce.
        static let settle = Animation.spring(response: 0.3, dampingFraction: 1)
        /// card grows from its glyph origin: opacity+scale 0.95→1.
        static let unfold = Animation.spring(response: 0.4, dampingFraction: 0.85)
        /// ghost: fade in 0.2s then STATIC; commit = draw-on 0.45s.
        static let ghostAppear = Animation.easeIn(duration: 0.2)
        static let commitDuration: Double = 0.45
        /// dismiss/resolve: fade+scale→0.9, 0.2s.
        static let dismiss = Animation.easeOut(duration: 0.2)
        /// Reduce-Motion replacement — everything becomes a 0.2s opacity crossfade.
        static let reduced = Animation.easeInOut(duration: 0.2)
        /// fix-it ink draw-on speed (chars/sec).
        static let fixItCharsPerSec: Double = 14
    }
}

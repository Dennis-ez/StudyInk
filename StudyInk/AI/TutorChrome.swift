import SwiftUI

/// Shared chrome for the Conote ambient-tutor surfaces (handoff §3/§4): the margin
/// card, the glyph set, the depth meter, action chips, and the single allowed
/// breathing animation. Every value comes from `AITokens` — no hardcoded hex. Reused
/// by the guided ladder (1a), diagnostic (3b), and selection rail (4b).

/// The accent a surface carries (drives the 4px accent bar + the mono kicker color).
enum TutorAccent {
    case ai, correction, success
    var color: Color {
        switch self {
        case .ai: return AITokens.ai
        case .correction: return AITokens.correction
        case .success: return AITokens.success
        }
    }
}

/// The margin note card — leading accent bar, mono UPPERCASE kicker, Fraunces title,
/// frosted paper body, hairline ring + soft shadow. `unfold` grows it from its origin.
struct TutorCard<Content: View>: View {
    var kicker: String
    var title: String?
    var accent: TutorAccent = .ai
    var maxWidth: CGFloat = 320
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kicker.uppercased())
                .font(AITokens.mono(10, .medium)).tracking(1.1)
                .foregroundStyle(accent.color)
            if let title, !title.isEmpty {
                Text(title).font(AITokens.fraunces(16)).foregroundStyle(AITokens.textInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(.leading, 18).padding(.trailing, 14).padding(.vertical, 12)
        .frame(maxWidth: maxWidth, alignment: .leading)
        // Ideal (content) height — otherwise the flexible accent bar stretches the card
        // to fill its container when placed via .position() in the editor overlay.
        .fixedSize(horizontal: false, vertical: true)
        .background(AITokens.cardBg)
        // The 4px accent bar rides the card's actual height as a leading overlay.
        .overlay(alignment: .leading) { Rectangle().fill(accent.color).frame(width: 4) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AITokens.cardRing, lineWidth: 1))
        .shadow(color: AITokens.cardShadow.opacity(0.32), radius: 22, x: 0, y: 16)
    }
}

/// The lane glyph set. **Shape differs per kind** (✓ ~ ? ✦ !) so color is never the
/// sole signal (Graphite skin + colorblind safety, §9).
enum TutorGlyphKind { case correct, correction, hint, spark, error }

struct TutorGlyph: View {
    let kind: TutorGlyphKind
    /// Mirror the `~`/`?` glyphs horizontally on an RTL page.
    var rtl: Bool = false
    private let d = AITokens.Lane.glyphSize

    var body: some View {
        Group {
            switch kind {
            case .correct:
                Circle().fill(AITokens.successTint)
                    .overlay(Image(systemName: "checkmark").font(.system(size: d * 0.5, weight: .bold))
                        .foregroundStyle(AITokens.success))
                    .frame(width: d, height: d)
            case .correction:
                SquigglePath()
                    .stroke(AITokens.correction, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .frame(width: d * 1.5, height: d * 0.62)
                    .scaleEffect(x: rtl ? -1 : 1)
            case .hint:
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.6, dash: [3, 2.5]))
                    .foregroundStyle(AITokens.ai)
                    .overlay(Image(systemName: "questionmark").font(.system(size: d * 0.46, weight: .bold))
                        .foregroundStyle(AITokens.ai))
                    .frame(width: d, height: d)
                    .scaleEffect(x: rtl ? -1 : 1)
            case .spark:
                Image(systemName: "sparkle").font(.system(size: d * 0.7, weight: .semibold))
                    .foregroundStyle(AITokens.ai)
                    .frame(width: d, height: d)
            case .error:
                Circle().fill(AITokens.correction)
                    .overlay(Image(systemName: "exclamationmark").font(.system(size: d * 0.55, weight: .heavy))
                        .foregroundStyle(.white))
                    .frame(width: d, height: d)
            }
        }
        .frame(width: AITokens.Lane.tapTarget, height: AITokens.Lane.tapTarget)   // ≥44pt tap target
        .contentShape(Rectangle())
    }
}

/// The 1a depth meter — three bars (ai · ai · success) filling up to the current rung,
/// with the stage label. `level` is 1…3.
struct DepthMeter: View {
    let level: Int
    private let colors: [Color] = [AITokens.ai, AITokens.ai, AITokens.success]
    private let labels = ["untouched", "question", "hint", "the step"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(colors[i].opacity(i < level ? 1 : 0.22))
                        .frame(height: 4)
                }
            }
            Text("level \(level) of 3 · \(labels[min(level, 3)])")
                .font(AITokens.mono(9)).tracking(0.6).foregroundStyle(AITokens.textFainter)
        }
    }
}

/// An action chip (the card's primary/secondary verbs). `.solid` = a filled accent
/// pill; `.ghost` = a tinted outline.
struct TutorChip: View {
    enum Style { case solid, ghost }
    var title: LocalizedStringKey
    var systemImage: String?
    var accent: Color = AITokens.ai
    var style: Style = .solid
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .bold)) }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .foregroundStyle(style == .solid ? Color.white : accent)
            .background {
                if style == .solid { Capsule().fill(accent) }
                else { Capsule().fill(accent.opacity(0.12)).overlay(Capsule().strokeBorder(accent.opacity(0.4))) }
            }
        }
        .buttonStyle(.plain)
    }
}

/// The ONE allowed continuous loop (§8): scale 1↔1.12, opacity 0.7↔1, ~3.3s. Honors
/// Reduce Motion (then it just sits at full strength, no pulse).
struct Breathing: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? AITokens.Motion.breatheScaleTo : 1)
            .opacity(on ? 1 : AITokens.Motion.breatheOpacityFrom)
            .onAppear {
                guard !reduceMotion else { on = true; return }
                withAnimation(.easeInOut(duration: AITokens.Motion.breatheDuration).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

extension View {
    /// The single allowed breathing animation — apply to the ONE element actively
    /// asking for a decision (the rung-0 ✦ / the check offer).
    func breathing() -> some View { modifier(Breathing()) }
}

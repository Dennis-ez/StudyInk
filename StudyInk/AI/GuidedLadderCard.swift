import SwiftUI

/// Feature 1a — **Guided mode · Reveal in layers** (handoff §4.1, `GuidedMode.dc.html`).
/// One rung per tap: a guiding question → one hint (+ scaffold box) → the step revealed.
/// The model returns `nudge`/`hint`/`stepLatex` in ONE `next_step` call; this card
/// reveals only up to the current rung — never paints a deeper field early.
struct GuidedLadderCard: View {
    let step: AIClient.NextStep
    /// 1 = question · 2 = hint · 3 = step.
    let rung: Int
    var onAdvance: () -> Void
    var onReplay: () -> Void
    var onDismiss: () -> Void

    private var accent: TutorAccent { rung >= 3 ? .success : .ai }

    var body: some View {
        TutorCard(kicker: kicker, title: nil, accent: accent) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    if rung >= 3 { TutorGlyph(kind: .correct).frame(width: 22, height: 22) }
                    Text(bodyText).font(.system(size: 13.5)).foregroundStyle(AITokens.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if rung == 2 { scaffoldBox }
                DepthMeter(level: rung)
                HStack(spacing: 8) {
                    primaryAction
                    Spacer(minLength: 0)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AITokens.textFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // The hint's worked scaffold: "u = ⬚   du = ⬚" on the workedBox.
    private var scaffoldBox: some View {
        HStack(spacing: 18) {
            blankPair(lhs: "u =")
            blankPair(lhs: "du =")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AITokens.workedBox, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func blankPair(lhs: String) -> some View {
        HStack(spacing: 6) {
            Text(lhs).font(AITokens.caveat(22)).foregroundStyle(AITokens.inkStudent)
            RoundedRectangle(cornerRadius: 4)
                .fill(AITokens.scaffoldBoxBg)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(AITokens.scaffoldBoxRing))
                .frame(width: 26, height: 24)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch rung {
        case 1: TutorChip(title: "ambient.ladder.stuckHint", systemImage: "arrow.down", action: onAdvance)
        case 2: TutorChip(title: "ambient.ladder.showStep", systemImage: "eye", action: onAdvance)
        default: TutorChip(title: "ambient.ladder.replay", systemImage: "arrow.counterclockwise",
                           accent: AITokens.success, action: onReplay)
        }
    }

    private var kicker: String {
        switch rung {
        case 1: return "a nudge · just a question"
        case 2: return "a hint · one rung lower"
        default: return "step revealed"
        }
    }

    /// Gemini content, falling back to the canonical demo copy when a field is nil.
    private var bodyText: String {
        switch rung {
        case 1:
            return step.nudge ?? "You've set the integral up. Notice cos(x²) — its inside isn't a plain x. What kind of move untangles a function-inside-a-function?"
        case 2:
            return step.hint ?? "Let u be the inside of the cosine. Then differentiate it to find du — and watch for the 2x already sitting in front."
        default:
            return "It's written faintly on your next line — trace over it to keep it in your own hand, or carry on yourself."
        }
    }
}

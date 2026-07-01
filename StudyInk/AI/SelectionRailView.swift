import SwiftUI

/// Feature 4b — **Circle to ask · The selection morphs** (handoff §4.4, `CircleAsk.dc.html`).
/// Lasso a span → no popup, no modal: the circled span lifts into a soft pill in place
/// and an inline rail slides out beside it on the same line; tapping a verb unfolds the
/// answer directly beneath the circled line. Question and answer stay attached on the page.

enum CircleVerb: String, CaseIterable, Identifiable {
    case explain, simpler
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .explain: return "ambient.circle.explain"
        case .simpler: return "ambient.circle.simpler"
        }
    }
    func answer(from r: AIClient.CircleResult) -> String {
        switch self {
        case .explain: return r.explain
        case .simpler: return r.simpler
        }
    }
}

/// The inline verb rail — a ✦ hub + Explain · Simpler · Analogy + ×, fully rounded,
/// `cardBg` on `cardRing`. Mirrors in RTL via the layout direction it's placed in.
struct SelectionRail: View {
    let selected: CircleVerb?
    var onVerb: (CircleVerb) -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkle").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AITokens.ai)
                .padding(.leading, 4)
            ForEach(CircleVerb.allCases) { verb in
                Button { onVerb(verb) } label: {
                    Text(verb.label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(selected == verb ? AITokens.ai : AITokens.textMuted)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background {
                            if selected == verb {
                                Capsule().fill(AITokens.ai.opacity(0.14))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AITokens.textFaint).padding(.horizontal, 5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 5).padding(.vertical, 5)
        .background(AITokens.cardBg, in: Capsule())
        .overlay(Capsule().strokeBorder(AITokens.cardRing))
        .shadow(color: AITokens.cardShadow.opacity(0.22), radius: 12, y: 5)
    }
}

/// The answer that unfolds directly beneath the circled line (ai accent; kicker = the
/// verb; a sub-line stresses the attachment). Loading shows a quiet placeholder.
struct CircleAnswerCard: View {
    let verb: CircleVerb
    let result: AIClient.CircleResult?
    var isLoading: Bool = false

    var body: some View {
        TutorCard(kicker: kickerText, title: nil, accent: .ai) {
            VStack(alignment: .leading, spacing: 6) {
                if isLoading || result == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("ai.thinking").font(.system(size: 12)).foregroundStyle(AITokens.textFaint)
                    }
                } else if let result {
                    Text(verb.answer(from: result))
                        .font(.system(size: 13.5)).foregroundStyle(AITokens.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("— it threads right under the line you circled")
                    .font(AITokens.mono(9)).tracking(0.4).foregroundStyle(AITokens.textFainter)
            }
        }
    }

    private var kickerText: String {
        switch verb {
        case .explain: return "explain"
        case .simpler: return "simpler"
        }
    }
}

/// Styles the circled span itself as the soft amber pill (apply to the lifted span).
struct CircledSpanPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(AITokens.ai.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AITokens.ai.opacity(0.40)))
    }
}
extension View {
    func circledSpanPill() -> some View { modifier(CircledSpanPill()) }
}

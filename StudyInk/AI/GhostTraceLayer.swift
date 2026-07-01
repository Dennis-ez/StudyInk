import SwiftUI

/// Feature 2a — **Suggest next step · The fill-in ghost** (handoff §4.2, `NextStep.dc.html`).
/// The next line renders inline as dimmed student ink with the ONE insight-bearing token
/// blanked into a pulsing scaffold box. The student can write it themselves, reveal it,
/// or trace to keep — which commits to solid amber tagged AI ink (one-undo, export-strippable).
struct GhostTraceLayer: View {
    /// The next line as plain/unicode text, e.g. "= sin(u) + C".
    let fullText: String
    /// The token to mask first (the substituted variable / key operand), e.g. "u".
    let blankToken: String
    let why: String?
    var onAccept: (String) -> Void
    var onDismiss: () -> Void
    /// When set, the "?" opens a chat thread about this step instead of the inline why.
    var onAsk: (() -> Void)? = nil

    enum GhostState { case scaffold, revealed, accepted }
    @State private var state: GhostState = .scaffold
    @State private var showWhy = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var parts: (pre: String, blank: String, post: String) {
        let text = fullText.mathToUnicode()
        let token = blankToken.mathToUnicode()
        guard !token.isEmpty, let r = text.range(of: token) else { return (text, "", "") }
        return (String(text[text.startIndex..<r.lowerBound]), String(text[r]), String(text[r.upperBound...]))
    }

    /// The next line as clean LaTeX (delimiters stripped). Typeset in 2D when it's real
    /// math so a fraction/root reads correctly instead of folding to "(…)/(2√(x))".
    private var latexClean: String {
        fullText
            .replacingOccurrences(of: "$$", with: "").replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "\\(", with: "").replacingOccurrences(of: "\\)", with: "")
            .replacingOccurrences(of: "\\[", with: "").replacingOccurrences(of: "\\]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Heavy 2D structure that unicode-folding mangles → typeset it. A plain linear line
    /// (e.g. "= sin(u) + C") stays handwritten with the pulsing scaffold box.
    private var needsTypeset: Bool {
        let s = latexClean
        guard MathSegmenter.typesets(s) else { return false }
        return ["\\frac", "\\dfrac", "\\tfrac", "\\sqrt", "\\int", "\\sum", "\\prod",
                "\\lim", "^{", "_{"].contains { s.contains($0) }
    }

    /// The typeset LaTeX with the insight token masked by SwiftMath's placeholder box
    /// (\square) until revealed. Falls back to the full expression if the token can't be
    /// located in the LaTeX — correct math wins over the blank.
    private var scaffoldLatex: String {
        guard !blankToken.isEmpty, let r = latexClean.range(of: blankToken) else { return latexClean }
        var s = latexClean; s.replaceSubrange(r, with: "\\square ")
        return MathSegmenter.typesets(s) ? s : latexClean
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                traceLine
                actionCluster
            }
            if showWhy { whyCard }
            if state == .accepted { aiInkPill }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: AITokens.Motion.breatheDuration).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    // The dimmed step with the blank in the middle — typeset in 2D for real math
    // (fractions/roots), handwritten (Caveat) with a pulsing scaffold box for a plain
    // linear line. Tapping a scaffold reveals the answer either way.
    @ViewBuilder private var traceLine: some View {
        let accepted = state == .accepted
        if needsTypeset {
            AIInkMath(latex: state == .scaffold ? scaffoldLatex : latexClean,
                      color: accepted ? AITokens.ai : AITokens.inkStudent, fontSize: 36)
                .opacity(accepted ? 1 : AITokens.inkGhostOpacity)
                .scaleEffect(state == .scaffold && pulse ? 1.02 : 1.0)
                .contentShape(Rectangle())
                .onTapGesture { if state == .scaffold { withAnimation(AITokens.Motion.unfold) { state = .revealed } } }
        } else {
            let p = parts
            HStack(spacing: 0) {
                Text(p.pre).font(AITokens.caveat(32))
                blankView
                Text(p.post).font(AITokens.caveat(32))
            }
            .foregroundStyle(accepted ? AITokens.ai : AITokens.inkStudent)
            .opacity(accepted ? 1 : AITokens.inkGhostOpacity)
        }
    }

    @ViewBuilder private var blankView: some View {
        let p = parts
        switch state {
        case .scaffold:
            // The one exception to "no box": the blank is a pulsing scaffold box.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AITokens.scaffoldBoxBg)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AITokens.scaffoldBoxRing))
                .frame(width: max(34, CGFloat(p.blank.count) * 16), height: 38)
                .scaleEffect(pulse ? 1.06 : 1.0)
                .opacity(1)   // the blank stays full-strength even though the trace is dimmed
                .onTapGesture { withAnimation(AITokens.Motion.unfold) { state = .revealed } }
        case .revealed, .accepted:
            Text(p.blank).font(AITokens.caveat(32))
        }
    }

    // ? (toggle why) · fill the blank · trace to keep.
    private var actionCluster: some View {
        HStack(spacing: 6) {
            Button {
                if let onAsk { onAsk() }
                else { withAnimation(AITokens.Motion.dismiss) { showWhy.toggle() } }
            } label: {
                Image(systemName: "questionmark")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(AITokens.ai)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [3, 2])).foregroundStyle(AITokens.ai))
            }
            .buttonStyle(.plain)
            .tutorTapTarget(24)
            switch state {
            case .scaffold:
                TutorChip(title: "ambient.ghost.fillBlank", action: { withAnimation(AITokens.Motion.unfold) { state = .revealed } })
            case .revealed:
                TutorChip(title: "ambient.ghost.traceToKeep", systemImage: "checkmark",
                          accent: AITokens.success, action: commit)
            case .accepted:
                EmptyView()
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(AITokens.textFaint)
            }
            .buttonStyle(.plain)
            .tutorTapTarget(16)
        }
    }

    private var whyCard: some View {
        TutorCard(kicker: "why this step", title: nil, accent: .ai, maxWidth: 280) {
            Text(why ?? "You've reduced it to ∫ cos(u) du. The antiderivative of cosine is sine — so the blank fills with u, and you'll back-substitute next.")
                .font(.system(size: 13)).foregroundStyle(AITokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aiInkPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold))
            Text("ambient.ghost.aiInkOneUndo").font(AITokens.mono(9)).tracking(0.4)
        }
        .foregroundStyle(AITokens.ai)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(AITokens.aiInkTagBg, in: Capsule())
    }

    private func commit() {
        withAnimation(.easeOut(duration: AITokens.Motion.commitDuration)) { state = .accepted }
        onAccept(fullText)
    }
}

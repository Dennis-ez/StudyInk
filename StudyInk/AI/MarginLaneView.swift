import SwiftUI
import PencilKit

/// The tutor's margin lane: glyphs anchored in page-content space (they scroll/
/// zoom with the ink), and the note that unfolds from a tapped glyph. Empty
/// regions pass touches through to the canvas.
struct MarginLaneView: View {
    @ObservedObject var ambient: AmbientTutorController
    let pageIndex: Int
    let transform: CanvasTransform
    /// Width reserved on the trailing edge (the page navigator strip) so the
    /// unfolded note card parks clear of it instead of hiding underneath.
    var trailingInset: CGFloat = 0
    var onFixIt: (MarginItem) -> Void = { _ in }
    var onShowWhy: (MarginItem) -> Void = { _ in }
    var onOpenHint: (MarginItem) -> Void = { _ in }
    var onAcceptGhost: (GhostSuggestion) -> Void = { _ in }
    /// The student tapped the "grade my answer" glyph.
    var onGrade: () -> Void = {}

    /// Smallest page-space x a glyph may sit at (keeps it on the page for a
    /// left-margin question); right-column questions sit beside their own line.
    private let minGlyphPageX: CGFloat = 30

    private var pageItems: [MarginItem] { ambient.items(onPage: pageIndex) }

    /// Page-space x just left of an equation, so the glyph sits next to THAT
    /// question (works for two-column layouts) instead of the page's far margin.
    private func glyphPageX(for item: MarginItem) -> CGFloat {
        max(minGlyphPageX, item.anchorRect.minX - 30)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Transient highlight over the line a just-opened hint is about.
                if let f = ambient.focusHighlight, f.pageIndex == pageIndex {
                    let tl = transform.toScreen(CGPoint(x: f.rect.minX, y: f.rect.minY))
                    let br = transform.toScreen(CGPoint(x: f.rect.maxX, y: f.rect.maxY))
                    let w = max(24, br.x - tl.x), h = max(14, br.y - tl.y)
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppTheme.current.aiAccent.opacity(0.16))
                        .frame(width: w + 18, height: h + 10)
                        .position(x: (tl.x + br.x) / 2, y: (tl.y + br.y) / 2)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // Glyphs just left of each line's equation.
                ForEach(pageItems) { item in
                    let p = transform.toScreen(CGPoint(x: glyphPageX(for: item), y: item.anchorRect.midY))
                    // IMPORTANT: gesture/contentShape BEFORE .position — applying
                    // them after .position makes the tap target fill the whole
                    // screen and blocks the canvas (can't draw).
                    AmbientGlyphView(glyph: item.glyph)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        // A watcher hint opens the full explanation bubble; a
                        // check glyph unfolds its margin note.
                        .onTapGesture { item.glyph == .hint ? onOpenHint(item) : ambient.open(item.id) }
                        .accessibilityLabel(Text(item.glyph == .correct ? "ambient.glyph.correct" : "ambient.glyph.attend"))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .position(x: p.x, y: p.y)
                }

                // The open note (max one at a time), parked on the trailing side
                // at the glyph's line height.
                if let id = ambient.openItemID,
                   let item = ambient.items.first(where: { $0.id == id }) {
                    let p = transform.toScreen(CGPoint(x: glyphPageX(for: item), y: item.anchorRect.midY))
                    MarginNoteView(
                        item: item,
                        onDismiss: { ambient.dismiss() },
                        onFixIt: { onFixIt(item) },
                        onShowWhy: { onShowWhy(item) }
                    )
                    .frame(width: 300)
                    .position(
                        x: geo.size.width - 170 - trailingInset,
                        y: min(max(p.y, 120), geo.size.height - 170)
                    )
                    .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                }

                // Ghost next-step suggestion, faint amber ahead of the pen.
                if let g = ambient.ghost, g.pageIndex == pageIndex {
                    GhostInkLayer(
                        ghost: g,
                        transform: transform,
                        onAccept: { onAcceptGhost(g) },
                        onDismiss: { ambient.dismissGhost() }
                    )
                }

                // "Grade my answer" glyph — parks in the trailing margin at the
                // student's last line; tap it to grade the page.
                if let gp = ambient.gradePrompt, gp.pageIndex == pageIndex, !ambient.isChecking {
                    let y = transform.toScreen(gp.anchor).y
                    GradeGlyphView(onTap: onGrade, onDismiss: { ambient.clearGradePrompt() })
                        .position(
                            x: geo.size.width - 52 - trailingInset,
                            y: min(max(y, 110), geo.size.height - 90)
                        )
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }

                // Inline "why" explanation as worked steps (the step UI), near the
                // line — replaces opening the AI chat bubble.
                if let ex = ambient.explanation, ex.pageIndex == pageIndex {
                    let p = transform.toScreen(ex.anchor)
                    StepDetailCard(why: ex.why, steps: ex.steps, isLoading: ex.isLoading,
                                   onDismiss: { ambient.dismissExplanation() })
                        .position(
                            x: min(max(p.x, 180), geo.size.width - 170 - trailingInset),
                            y: min(max(p.y + 34, 160), geo.size.height - 190)
                        )
                        .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
                }
            }
        }
    }
}

/// The predicted next step, drawn as the SAME handwriting it'll become (InkWriter
/// strokes, as vectors so it matches the real ink) — placed exactly where accepting
/// will write it, inside a dashed accent box so it reads as a suggestion. Beside it
/// a "?" button: tap for the WHY + steps and to dismiss. Tap the ink (or flick
/// right) to keep it; flick left to drop it.
struct GhostInkLayer: View {
    let ghost: GhostSuggestion
    let transform: CanvasTransform
    var onAccept: () -> Void
    var onDismiss: () -> Void
    @State private var showDetail = false
    @State private var preview: PreviewState = .rendering

    private enum PreviewState { case rendering; case ready([[CGPoint]], CGRect); case failed }

    var body: some View {
        Group {
            switch preview {
            case .ready(let lines, let bounds): handwriting(lines, bounds)
            case .failed:                       typesetFallback
            case .rendering:                    Color.clear.frame(width: 1, height: 1)
            }
        }
        .task(id: ghost.text) { await renderPreview() }
    }

    /// The handwriting strokes drawn as vectors, sized + placed to match writeInk.
    private func handwriting(_ lines: [[CGPoint]], _ bounds: CGRect) -> some View {
        let z = transform.zoomScale
        let dw = bounds.width * z, dh = bounds.height * z
        let lineW = max(2.4, 22 * 0.135) * z
        // Handoff §6: the trace is the STUDENT'S own ink, dimmed — NOT amber, NO box.
        // The only amber is the "?" marker; AI-ness is conveyed by the marker, not by
        // decorating the math.
        let color = Color.primary
        // writeInk lands inline = vertically centred on the line at anchor.x; a new
        // line = top-left at the anchor. Match it so the preview IS where the ink goes.
        let centerPage = ghost.inline
            ? CGPoint(x: ghost.anchor.x + bounds.width / 2, y: ghost.anchor.y)
            : CGPoint(x: ghost.anchor.x + bounds.width / 2, y: ghost.anchor.y + bounds.height / 2)
        let c = transform.toScreen(centerPage)
        return ZStack(alignment: .topTrailing) {
            Canvas { ctx, _ in
                for line in lines where line.count > 1 {
                    var path = Path()
                    path.move(to: CGPoint(x: (line[0].x - bounds.minX) * z, y: (line[0].y - bounds.minY) * z))
                    for k in 1..<line.count {
                        path.addLine(to: CGPoint(x: (line[k].x - bounds.minX) * z, y: (line[k].y - bounds.minY) * z))
                    }
                    ctx.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: dw, height: dh)
            // The student's ink at ~30% (§7 --ai-ghost-opacity) — a faint under-trace,
            // STATIC (no pulse: §7 "at most one breathing element on screen").
            .opacity(0.30)
            .contentShape(Rectangle())
            .onTapGesture { onAccept() }
            whyButton.offset(x: 18, y: -14)
        }
        .frame(width: dw, height: dh)
        .overlay(alignment: .topLeading) {
            if showDetail { ghostSteps.fixedSize().offset(x: 0, y: dh + 12) }
        }
        .highPriorityGesture(flick)
        .position(c)
        .transition(.opacity)
    }

    /// Fallback if InkWriter can't render the expression: the typeset form, faint.
    private var typesetFallback: some View {
        let p = transform.toScreen(ghost.anchor)
        return HStack(alignment: .center, spacing: 7) {
            AIInkMath(latex: ghost.text, color: AppTheme.current.aiAccent, fontSize: 20)
                .opacity(0.7).contentShape(Rectangle()).onTapGesture { onAccept() }
            whyButton
        }
        .fixedSize()
        .overlay(alignment: .topLeading) { if showDetail { ghostSteps.fixedSize().offset(y: 36) } }
        .highPriorityGesture(flick)
        .position(x: p.x + (ghost.inline ? 64 : 34), y: p.y)
        .transition(.opacity)
    }

    private var flick: some Gesture {
        DragGesture(minimumDistance: 28).onEnded { v in
            if v.translation.width > 24 { onAccept() } else if v.translation.width < -24 { onDismiss() }
        }
    }

    /// The "?" why button — tap to explain WHY (steps) / dismiss.
    private var whyButton: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { showDetail.toggle() } } label: {
            Image(systemName: "questionmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(showDetail ? Color.white : AppTheme.current.aiAccent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(showDetail ? AppTheme.current.aiAccent : SemanticColor.surface))
                .overlay(Circle().strokeBorder(SemanticColor.separator))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("ambient.why"))
    }

    /// Build the handwriting polylines (off-main) the way writeInk would, so the
    /// preview matches the real ink — drawn as vectors, no rasterization mismatch.
    @MainActor private func renderPreview() async {
        let text = ghost.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { preview = .failed; return }
        let result: ([[CGPoint]], CGRect)? = await Task.detached(priority: .userInitiated) {
            let fontSize: CGFloat = 22
            let strokes = InkWriter.strokes(for: text, topLeft: .zero, fontSize: fontSize,
                                            ink: PKInk(.pen, color: .label),
                                            strokeWidth: max(2.4, fontSize * 0.135))
            guard !strokes.isEmpty else { return nil }
            var lines: [[CGPoint]] = []
            var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            for stroke in strokes {
                let p = stroke.path
                guard p.count > 0 else { continue }
                let step = max(1, p.count / 80)
                var pts: [CGPoint] = []
                var i = 0
                while i < p.count {
                    let loc = p[i].location.applying(stroke.transform)
                    pts.append(loc)
                    minX = min(minX, loc.x); minY = min(minY, loc.y)
                    maxX = max(maxX, loc.x); maxY = max(maxY, loc.y)
                    i += step
                }
                let last = p[p.count - 1].location.applying(stroke.transform)
                pts.append(last)
                minX = min(minX, last.x); minY = min(minY, last.y)
                maxX = max(maxX, last.x); maxY = max(maxY, last.y)
                lines.append(pts)
            }
            guard maxX > minX, maxY > minY else { return nil }
            return (lines, CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }.value
        if let (lines, bounds) = result {
            withAnimation(.easeIn(duration: 0.2)) { preview = .ready(lines, bounds) }
        } else {
            preview = .failed
        }
    }

    /// Tapped-"?" detail: the SAME inline step UI the grade-note / hint use — the
    /// why + worked steps. Keep = tap the ink or flick right; dismiss = flick left.
    private var ghostSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            StepDetailCard(why: ghost.why, steps: ghost.steps,
                           onDismiss: { withAnimation(.easeOut(duration: 0.2)) { showDetail = false } })
            // Keep — write the suggestion in as real ink (the step card has no verb).
            Button(action: onAccept) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    Text("ambient.flickAccept").font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(AppTheme.current.aiAccent, in: Capsule())
            }
            .buttonStyle(.plain)
            .environment(\.layoutDirection, .leftToRight)
        }
    }
}

/// One margin glyph — ✓ correct · ~ correction · ? hint · • note. Cheap shapes,
/// no blur (it floats over the live canvas).
struct AmbientGlyphView: View {
    let glyph: AmbientGlyph

    var body: some View {
        switch glyph {
        case .correct:
            Circle().fill(glyph.color.opacity(0.14))
                .frame(width: 24, height: 24)
                .overlay(Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(glyph.color))
        case .attend:
            SquigglePath()
                .stroke(glyph.color, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .frame(width: 38, height: 16)
        case .hint:
            // Same family as the ✓ — a soft tinted disc with a hand-weight mark,
            // not the odd-one-out dashed ring.
            Circle().fill(glyph.color.opacity(0.14))
                .frame(width: 24, height: 24)
                .overlay(Text(verbatim: "?").font(.system(size: 13, weight: .bold)).foregroundStyle(glyph.color))
        case .note:
            Circle().fill(glyph.color).frame(width: 9, height: 9)
        }
    }
}

/// "Grade my answer" glyph shown after the student finishes writing — a breathing
/// accent pill (tap → grade the page) with a small dismiss.
struct GradeGlyphView: View {
    var onTap: () -> Void
    var onDismiss: () -> Void
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 15, weight: .semibold))
                    Text("ambient.check").font(.caption.weight(.semibold)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(AppTheme.current.aiAccent, in: Capsule())
                .shadow(color: AppTheme.current.aiAccent.opacity(breathe ? 0.45 : 0.2), radius: breathe ? 12 : 6)
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SemanticColor.textMutedColor)
                    .frame(width: 22, height: 22)
                    .background(SemanticColor.surface, in: Circle())
                    .overlay(Circle().strokeBorder(SemanticColor.separator))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("ai.dismiss"))
        }
        .fixedSize()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// Inline "why" → worked steps, shown in place (the step UI) instead of the AI
/// chat bubble. Used by the ghost's "?", the grade-result note, and the hint glyph.
struct StepDetailCard: View {
    let why: String?
    let steps: [String]
    var isLoading: Bool = false
    var onDismiss: () -> Void

    private var rtl: Bool { (why?.isMostlyRTL ?? false) || (steps.first?.isMostlyRTL ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Lucide("sparkles", size: 12).foregroundStyle(AppTheme.current.aiAccent)
                Text("ambient.why").font(.caption.weight(.semibold)).foregroundStyle(SemanticColor.textMutedColor)
                Spacer(minLength: 6)
                Button(action: onDismiss) { Lucide("x", size: 12).foregroundStyle(SemanticColor.textMutedColor) }
                    .buttonStyle(.plain).accessibilityLabel(Text("ai.dismiss"))
            }
            .environment(\.layoutDirection, .leftToRight)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("ai.thinking").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if let why, !why.isEmpty { AIRichText(content: why).font(.system(size: 12)) }
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: "\(i + 1)")
                            .font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                            .frame(width: 17, height: 17).background(AppTheme.current.aiAccent, in: Circle())
                        AIRichText(content: step).font(.system(size: 12))
                    }
                }
                if steps.isEmpty && (why?.isEmpty ?? true) {
                    Text("ambient.notice.noSuggestion").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: 300, alignment: rtl ? .trailing : .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SemanticColor.separator))
        .shadow(color: AppTheme.current.aiAccent.opacity(0.14), radius: 16, y: 6)
        // Hebrew reason/steps read right-to-left (number badge on the right).
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
    }
}

/// The hand-drawn correction squiggle from the design (38×16 viewBox path).
struct SquigglePath: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 38, sy = rect.height / 16
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        var p = Path()
        p.move(to: pt(3, 10))
        p.addCurve(to: pt(17, 9), control1: pt(8, 3), control2: pt(12, 3))
        p.addCurve(to: pt(35, 5), control1: pt(21, 14), control2: pt(26, 14))
        return p
    }
}

/// The note that unfolds from a glyph — the redesigned bubble. Frosted amber
/// card, leading tone strip, ✦ avatar with a breathing glow, italic math,
/// action-first chips.
struct MarginNoteView: View {
    let item: MarginItem
    var onDismiss: () -> Void
    var onFixIt: () -> Void
    var onShowWhy: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    private var material: Material { colorScheme == .dark ? .regularMaterial : .ultraThinMaterial }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                avatar
                Text(verbatim: item.label)
                    .font(.footnote)
                    .foregroundStyle(SemanticColor.textMutedColor)
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Lucide("x", size: 14).foregroundStyle(SemanticColor.textMutedColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)

            // Render LaTeX as math (folds $…$ / \cdot, typesets heavy math) instead
            // of spilling raw $$…$$ onto the card.
            AIRichText(content: item.body)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if let result = item.result, !result.isEmpty {
                Text(verbatim: "= \(InkWriter.plainText(from: result))")
                    .font(.fraunces(15, weight: .medium, relativeTo: .subheadline).italic())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(SemanticColor.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.vertical, 9)
            }

            HStack(spacing: 10) {
                // "Fix it" writes the corrected line as ink — only offer it when we
                // actually have a correction to write (a conceptual-only note has
                // nothing to land on the page, so the button would do nothing).
                if let result = item.result, !result.isEmpty {
                    Button(action: onFixIt) {
                        Text("ambient.fixIt")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 13).padding(.vertical, 6)
                            .background(SemanticColor.success, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onShowWhy) {
                    Text("ambient.showWhy")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, item.result == nil ? 8 : 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(material))
        .overlay(alignment: .leading) {
            Rectangle().fill(item.tone.color).frame(width: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SemanticColor.separator))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Amber-breathe — the tutor's quiet glow.
        .shadow(color: AppTheme.current.aiAccent.opacity(breathe ? 0.20 : 0.10), radius: breathe ? 30 : 22, y: 8)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    private var avatar: some View {
        Circle()
            .fill(AppTheme.current.aiAccent)
            .frame(width: 20, height: 20)
            .overlay(Lucide("sparkles", size: 11).foregroundStyle(.white))
            .shadow(color: AppTheme.current.aiAccent.opacity(0.4), radius: 8)
    }
}

/// A small breathing sparkle pill shown in a corner while the AI tutor is
/// working (Circle & Ask, Explain, Answer in Ink, …) — the same amber-breathe
/// language as the check-my-work flow, so any AI activity reads the same.
struct AIThinkingBadge: View {
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(AppTheme.current.aiAccent)
            .frame(width: 34, height: 34)
            .overlay(Lucide("sparkles", size: 17).foregroundStyle(.white))
            .scaleEffect(breathe || reduceMotion ? 1.0 : 0.82)
            .shadow(color: AppTheme.current.aiAccent.opacity(breathe ? 0.7 : 0.25),
                    radius: breathe ? 18 : 7)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { breathe = true }
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .accessibilityLabel(Text("ai.thinking"))
    }
}

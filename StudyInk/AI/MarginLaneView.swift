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
    /// The ghost's "?" (or a tap on the ghost ink) → open a chat thread about the step.
    var onAskGhostChat: (GhostSuggestion) -> Void = { _ in }
    /// The student explicitly dismissed the ghost (✕ / flick-left) — feeds the P3
    /// governor's dismissal suppression (two dismissals silence the type).
    var onGhostDismissed: () -> Void = {}
    /// The student tapped the "grade my answer" glyph.
    var onGrade: () -> Void = {}
    /// The ghost's "?" asked for a full worked derivation (its own steps were sparse).
    var onGhostRequestSteps: (GhostSuggestion) -> Void = { _ in }
    /// 3b diagnostic "Fix it" — write the fix as amber ink below the broken line.
    var onDiagnosticFix: (AIClient.CheckResult.FirstError, CGRect) -> Void = { _, _ in }
    /// 3b diagnostic "Show the rule" — open the worked explanation for the break.
    var onDiagnosticShowRule: (AIClient.CheckResult.FirstError, CGRect) -> Void = { _, _ in }

    /// True while the ghost's why/steps detail is open — drives the matching
    /// color-coded highlights over the student's ink on the canvas.
    @State private var ghostDetailShown = false

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
                        explanation: ambient.explanation?.itemID == item.id ? ambient.explanation : nil,
                        onDismiss: { ambient.dismiss(); ambient.dismissExplanation() },
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

                // NOTE: on-canvas colour boxes over the student's ink are DISABLED — the
                // model's normalized box coordinates are unreliable (they landed in empty
                // space). The colour-coded chips in the card still show the considered
                // params; precise on-ink placement needs the {col,line} layout anchoring.

                // Ghost next-step suggestion, faint amber ahead of the pen.
                if let g = ambient.ghost, g.pageIndex == pageIndex {
                    GhostInkLayer(
                        ghost: g,
                        transform: transform,
                        onAccept: { onAcceptGhost(g) },
                        onDismiss: { ambient.dismissGhost(); onGhostDismissed() },
                        onAskChat: { onAskGhostChat(g) },
                        onDetailChanged: { ghostDetailShown = $0 },
                        explanation: ambient.explanation?.itemID == GhostSuggestion.explainItemID ? ambient.explanation : nil,
                        onRequestSteps: { onGhostRequestSteps(g) },
                        // Subtle = no-spoiler: park a glyph, reveal the answer on request.
                        spoilerHidden: ambient.sensitivity == .subtle
                    )
                    .onDisappear { ghostDetailShown = false }
                }

                // 3b idle affordance — the breathing "✦ Find my mistake" pill parks in
                // the trailing margin at the student's last line; tap it to run the check.
                if let gp = ambient.gradePrompt, gp.pageIndex == pageIndex, !ambient.isChecking, ambient.diagnostic == nil {
                    let y = transform.toScreen(gp.anchor).y
                    FindMistakePill(onTap: onGrade)
                        .position(
                            x: geo.size.width - 92 - trailingInset,
                            y: min(max(y, 110), geo.size.height - 90)
                        )
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }

                // 3b result — the line-health map (top), the in-place spotlight on the
                // broken line, and the diagnostic card in the trailing margin.
                if let d = ambient.diagnostic, d.pageIndex == pageIndex {
                    LineHealthMap(ok: d.ok, brokenLine: d.brokenLine)
                        .position(x: geo.size.width / 2, y: 64)
                        .transition(.opacity)
                    if let b = d.brokenLine, d.lineRects.indices.contains(b) {
                        LineSpotlight(screenRect: transform.toScreen(d.lineRects[b]))
                    }
                    if let err = d.error {
                        let rect = d.lineRects.indices.contains(err.line) ? d.lineRects[err.line] : .zero
                        let y = transform.toScreen(CGPoint(x: rect.midX, y: rect.maxY)).y
                        DiagnosticCard(
                            error: err,
                            onFixIt: { onDiagnosticFix(err, rect) },
                            onShowRule: { onDiagnosticShowRule(err, rect) },
                            onReplay: { ambient.dismissDiagnostic(); onGrade() })
                            .frame(width: 300)
                            .position(
                                x: geo.size.width - 172 - trailingInset,
                                y: min(max(y + 60, 260), geo.size.height - 220))
                            .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                    }
                }

                // Inline "why" explanation as worked steps (the step UI), near the line.
                // Skip the ones bound to a margin note (itemID) — those render INSIDE it.
                if let ex = ambient.explanation, ex.pageIndex == pageIndex, ex.itemID == nil {
                    let p = transform.toScreen(ex.anchor)
                    StepDetailCard(why: ex.why, steps: ex.steps, isLoading: ex.isLoading,
                                   onDismiss: { ambient.dismissExplanation() })
                        .position(
                            x: min(max(p.x, 180), geo.size.width - 170 - trailingInset),
                            y: min(max(p.y + 34, 160), geo.size.height - 190)
                        )
                        .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
                }

                // 1a guided ladder — question → hint → step, one rung per tap.
                if let g = ambient.guidedLadder, g.pageIndex == pageIndex {
                    let p = transform.toScreen(g.anchor)
                    GuidedLadderCard(
                        step: g.step, rung: g.rung,
                        onAdvance: { ambient.advanceLadder() },
                        onReplay: { ambient.replayLadder() },
                        onDismiss: { ambient.dismissLadder() })
                        .frame(width: 300)
                        .position(
                            x: min(max(p.x + 150, 180), geo.size.width - 170 - trailingInset),
                            y: min(max(p.y, 210), geo.size.height - 230))
                        .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
                }
            }
        }
    }
}

/// Translucent color-coded boxes drawn over the student's OWN ink at the spots the
/// tutor used to derive its step — each box's color matches its chip in the why/steps
/// card. Never intercepts touches; the ink stays readable through the wash.
struct InkHighlightOverlay: View {
    let highlights: [AIHighlight]
    let transform: CanvasTransform
    @State private var appeared = false

    var body: some View {
        ZStack {
            ForEach(highlights) { h in
                if let rect = h.rect {
                    let r = transform.toScreen(rect)
                    let color = AIHighlightPalette.color(h.colorIndex)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(color.opacity(0.20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(color.opacity(0.55), lineWidth: 1.5)
                        )
                        .frame(width: r.width + 10, height: r.height + 8)
                        .position(x: r.midX, y: r.midY)
                        .opacity(appeared ? 1 : 0)
                        .scaleEffect(appeared ? 1 : 0.92)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(AITokens.Motion.unfold) { appeared = true } }
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
    /// The "?" (and tapping the ghost ink) now opens an interactive CHAT thread about
    /// this step — anchored at the ghost, pinnable, supports follow-up questions —
    /// instead of the inline why/steps card. `nil` falls back to the inline card.
    var onAskChat: (() -> Void)? = nil
    /// Fired when the why/steps detail is revealed/hidden, so the editor can show
    /// the matching color-coded highlights over the student's ink on the canvas.
    var onDetailChanged: (Bool) -> Void = { _ in }
    /// A worked derivation fetched on demand for the "?" (when the ghost's own steps
    /// are sparse) + the callback that requests it.
    var explanation: StepExplanation? = nil
    var onRequestSteps: () -> Void = {}
    /// No-spoiler mode (hardwired to the "subtle" sensitivity): park a glyph instead
    /// of writing the answer ahead of the pen. Tap → the HOW (why + steps); the
    /// answer ink only appears once the student taps "Reveal answer".
    var spoilerHidden: Bool = false
    @State private var showDetail = false
    @State private var revealed = false
    @State private var preview: PreviewState = .rendering

    private enum PreviewState { case rendering; case ready([[CGPoint]], CGRect); case failed }

    /// Whether the answer ink itself may be shown (vs. kept behind the glyph).
    private var showAnswer: Bool { !spoilerHidden || revealed }

    var body: some View {
        Group {
            if !showAnswer {
                // 2a fill-in ghost: show the next line with the insight token blanked
                // (never a full spoiler); fall back to the compact glyph when there's
                // no maskable token.
                if let blank = ghost.blankToken {
                    fillInGhost(blank)
                } else {
                    spoilerGlyph
                }
            } else {
                switch preview {
                case .ready(let lines, let bounds): handwriting(lines, bounds)
                case .failed:                       typesetFallback
                case .rendering:                    Color.clear.frame(width: 1, height: 1)
                }
            }
        }
        .task(id: ghost.text) { await renderPreview() }
        .onChange(of: showDetail) {
            onDetailChanged(showDetail)
            // Opening the "?" with no steps → fetch a full worked derivation on demand.
            if showDetail && ghost.steps.isEmpty && explanation == nil { onRequestSteps() }
        }
    }

    /// The 2a fill-in ghost (GhostTraceLayer) parked at the ghost anchor.
    private func fillInGhost(_ blank: String) -> some View {
        let p = transform.toScreen(ghost.anchor)
        return GhostTraceLayer(
            fullText: ghost.text, blankToken: blank, why: ghost.why,
            onAccept: { _ in onAccept() },
            onDismiss: onDismiss,
            onAsk: onAskChat)
            .fixedSize()
            .position(x: p.x + 140, y: p.y)
            .transition(.opacity)
    }

    /// The no-spoiler affordance: a compact "Next step" pill at the anchor. Tapping
    /// opens the why/steps card (the HOW) without revealing the answer line; the card
    /// carries a "Reveal answer" button that flips `revealed` on.
    private var spoilerGlyph: some View {
        let p = transform.toScreen(ghost.anchor)
        return ZStack(alignment: .topLeading) {
            Button { withAnimation(AITokens.Motion.dismiss) { showDetail.toggle() } } label: {
                HStack(spacing: 5) {
                    Lucide("sparkles", size: 13).foregroundStyle(AppTheme.current.aiAccent)
                    Text("ambient.nextStep").font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.current.aiAccent)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(AppTheme.current.aiAccent.opacity(0.35)))
                .shadow(color: AppTheme.current.aiAccent.opacity(0.14), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            dismissButton.offset(x: 12, y: -12)
        }
        .fixedSize()
        .overlay(alignment: .topLeading) {
            if showDetail { ghostSteps.fixedSize().offset(y: 38) }
        }
        .highPriorityGesture(flick)
        .position(x: p.x + (ghost.inline ? 56 : 30), y: p.y)
        .transition(.opacity)
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
            // Tap the ink → open a chat thread about HOW it got there (not a silent
            // accept — a spoiler some students don't want). Accept stays on the "Keep"
            // button + the flick-right.
            .onTapGesture { openDetail() }
            whyButton.offset(x: 18, y: -14)
            dismissButton.offset(x: 18, y: 14)
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
                .opacity(0.7).contentShape(Rectangle())
                .onTapGesture { openDetail() }
            whyButton
            dismissButton
        }
        .fixedSize()
        .overlay(alignment: .topLeading) { if showDetail { ghostSteps.fixedSize().offset(y: 36) } }
        .highPriorityGesture(flick)
        .position(x: p.x + (ghost.inline ? 64 : 34), y: p.y)
        .transition(.opacity)
    }

    private var flick: some Gesture {
        DragGesture(minimumDistance: 40).onEnded { v in
            // Only a FAST, mostly-horizontal flick counts — a slow pan (to scroll the
            // page / read a cut-off card) must NOT accept or dismiss (that was losing
            // the steps bubble when panning, #6).
            let fast = abs(v.velocity.width) > 700
            let horizontal = abs(v.translation.width) > abs(v.translation.height) * 1.8
            guard fast, horizontal else { return }
            if v.translation.width > 30 { onAccept() } else if v.translation.width < -30 { onDismiss() }
        }
    }

    /// The "?" opens the chat thread about this step (or, if no chat handler is wired,
    /// toggles the inline why/steps card as before).
    private func openDetail() {
        if let onAskChat { onAskChat() }
        else { withAnimation(AITokens.Motion.dismiss) { showDetail.toggle() } }
    }

    /// The "?" button — tap to open a chat thread about this step (was the inline card).
    private var whyButton: some View {
        Button { openDetail() } label: {
            Image(systemName: "questionmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(showDetail ? Color.white : AppTheme.current.aiAccent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(showDetail ? AppTheme.current.aiAccent : SemanticColor.surface))
                .overlay(Circle().strokeBorder(SemanticColor.separator))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .tutorTapTarget(26)
        .accessibilityLabel(Text("ambient.why"))
    }

    /// A visible dismiss (✕) — the left-flick alone wasn't discoverable, so the ghost
    /// felt impossible to get rid of.
    private var dismissButton: some View {
        Button { onDismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(SemanticColor.textMutedColor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(SemanticColor.surface))
                .overlay(Circle().strokeBorder(SemanticColor.separator))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .tutorTapTarget(22)
        .accessibilityLabel(Text("ai.dismiss"))
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
            // Pad by the stroke width: the bounds are the CENTERLINE, but the ink is
            // stroked ±strokeWidth/2 beyond it, so a tight frame clipped the edges
            // (the "looks cropped" report). A full-strokeWidth margin clears it.
            let pad = max(2.4, fontSize * 0.135) + 1
            return (lines, CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -pad, dy: -pad))
        }.value
        if let (lines, bounds) = result {
            withAnimation(AITokens.Motion.ghostAppear) { preview = .ready(lines, bounds) }
        } else {
            preview = .failed
        }
    }

    /// Tapped-"?" detail: the SAME inline step UI the grade-note / hint use — the
    /// why + worked steps. Keep = tap the ink or flick right; dismiss = flick left.
    private var ghostSteps: some View {
        // Prefer the ghost's own why/steps; when they're sparse, fall back to the
        // on-demand worked derivation fetched via "?".
        let steps = ghost.steps.isEmpty ? (explanation?.steps ?? []) : ghost.steps
        let why = (ghost.why?.isEmpty == false) ? ghost.why : explanation?.why
        // Steps missing ⇒ a fetch is (or is about to be) in flight — keep the loading
        // row up until it lands, so the card never flashes an empty/"no suggestion" state.
        let loading = ghost.steps.isEmpty && (explanation?.isLoading ?? true)
        return VStack(alignment: .leading, spacing: 6) {
            StepDetailCard(why: why, steps: steps, isLoading: loading,
                           onDismiss: { withAnimation(AITokens.Motion.dismiss) { showDetail = false } })
            // No-spoiler mode shows "Reveal answer" first (the card explained the HOW
            // without the answer); once revealed it becomes "Keep" — write it as ink.
            let needsReveal = spoilerHidden && !revealed
            Button(action: {
                if needsReveal { withAnimation(AITokens.Motion.dismiss) { revealed = true } }
                else { onAccept() }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: needsReveal ? "eye" : "checkmark").font(.system(size: 11, weight: .bold))
                    Text(needsReveal ? "ambient.revealAnswer" : "ambient.flickAccept").font(.caption.weight(.semibold))
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
            withAnimation(.easeInOut(duration: AITokens.Motion.breatheDuration).repeatForever(autoreverses: true)) { breathe = true }
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

    /// RTL if ANY Hebrew appears (first-strong-char fails on math/number-leading lines).
    private var rtl: Bool {
        let all = ([why].compactMap { $0 } + steps).joined(separator: " ")
        return Bidi.containsRTL(all)
    }

    var body: some View {
        VStack(alignment: rtl ? .trailing : .leading, spacing: 8) {
            HStack(spacing: 7) {
                Lucide("sparkles", size: 12).foregroundStyle(AppTheme.current.aiAccent)
                Text("ambient.why").font(.caption.weight(.semibold)).foregroundStyle(SemanticColor.textMutedColor)
                Spacer(minLength: 6)
                Button(action: onDismiss) { Lucide("x", size: 12).foregroundStyle(SemanticColor.textMutedColor) }
                    .buttonStyle(.plain).accessibilityLabel(Text("ai.dismiss"))
            }
            .environment(\.layoutDirection, .leftToRight)

            // ONE fixed shape every time: the one-line "why" heading (when present),
            // then the numbered worked steps. While the steps are still being fetched a
            // loading row stands in for them — so the card is only ever "why + steps" or
            // "why + loading", never a bare sentence, a collapsed step, or a chip row.
            if let why, !why.isEmpty { AIRichText(content: why).font(.system(size: 12)) }
            if isLoading || (steps.isEmpty && why?.isEmpty == false) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("ai.thinking").font(.caption).foregroundStyle(.secondary)
                }
            } else if steps.isEmpty {
                Text("ambient.notice.noSuggestion").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: "\(i + 1)")
                            .font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                            .frame(width: 17, height: 17).background(AppTheme.current.aiAccent, in: Circle())
                        AIRichText(content: step).font(.system(size: 12))
                    }
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
    /// The "Show why" worked steps, fetched for THIS note — rendered inline in the bubble.
    var explanation: StepExplanation? = nil
    var onDismiss: () -> Void
    var onFixIt: () -> Void
    var onShowWhy: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    private var material: Material { colorScheme == .dark ? .regularMaterial : .ultraThinMaterial }

    /// True when the "why" is essentially the note text already shown above it.
    private func whyRepeatsNote(_ why: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let a = norm(why), b = norm(item.body)
        guard a.count >= 6, b.count >= 6 else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

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
                // Once the why is showing (or loading) inline, drop the button.
                if explanation == nil {
                    Button(action: onShowWhy) {
                        Text("ambient.showWhy")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, item.result == nil ? 8 : 0)

            // The "why" worked steps, expanded INSIDE this note (not a floating card).
            if let ex = explanation {
                Divider().padding(.vertical, 9)
                if ex.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("ai.thinking").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        // Skip the why when it just repeats the note above it (the "show
                        // why is the same as the first thing it said" bug); the steps ARE
                        // the deeper answer.
                        if let why = ex.why, !why.isEmpty, !whyRepeatsNote(why) {
                            AIRichText(content: why).font(.system(size: 12.5))
                        }
                        ForEach(Array(ex.steps.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text(verbatim: "\(i + 1)")
                                    .font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                                    .frame(width: 16, height: 16).background(AppTheme.current.aiAccent, in: Circle())
                                AIRichText(content: step).font(.system(size: 12.5))
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
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
            withAnimation(.easeInOut(duration: AITokens.Motion.breatheDuration).repeatForever(autoreverses: true)) { breathe = true }
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
                withAnimation(.easeInOut(duration: AITokens.Motion.breatheDuration).repeatForever(autoreverses: true)) { breathe = true }
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .accessibilityLabel(Text("ai.thinking"))
    }
}

import SwiftUI

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
            }
        }
    }
}

/// The predicted next step, rendered as faint AI "ink" written in right where it
/// belongs on the page. Beside it sits ONE small pin — tap it to read WHY (and the
/// worked steps) and to dismiss. Tap the ink itself (or flick it right) to keep it
/// — the editor then lays it down as real ink; flick left to drop it.
struct GhostInkLayer: View {
    let ghost: GhostSuggestion
    let transform: CanvasTransform
    var onAccept: () -> Void
    var onDismiss: () -> Void
    @State private var pulse = false
    @State private var showDetail = false

    private var detailRTL: Bool {
        (ghost.why?.isMostlyRTL ?? false) || (ghost.steps.first?.isMostlyRTL ?? false)
    }

    var body: some View {
        let p = transform.toScreen(ghost.anchor)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 7) {
                // The suggested next line, written in as faint 2D AI ink. Tap to
                // keep it (the editor lays it down as real ink).
                AIInkMath(latex: ghost.text, color: AppTheme.current.aiAccent, fontSize: 20)
                    .opacity(pulse ? 0.6 : 0.4)
                    .contentShape(Rectangle())
                    .onTapGesture { onAccept() }

                // The pin — the only chrome. Tap to explain WHY / dismiss.
                Button { withAnimation(.easeOut(duration: 0.2)) { showDetail.toggle() } } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(showDetail ? 0 : 32))
                        .foregroundStyle(showDetail ? Color.white : AppTheme.current.aiAccent)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(showDetail ? AppTheme.current.aiAccent : SemanticColor.surface))
                        .overlay(Circle().strokeBorder(SemanticColor.separator))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("ambient.why"))
            }

            if showDetail {
                detailCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .fixedSize()
        // Gesture BEFORE .position so the flick area is the ghost itself, not
        // the whole screen (which would block drawing).
        .highPriorityGesture(
            DragGesture(minimumDistance: 28).onEnded { v in
                if v.translation.width > 24 { onAccept() } else if v.translation.width < -24 { onDismiss() }
            }
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { pulse = true }
        }
        // Sit the ink where the next step goes: continuing the current line for an
        // inline completion, or just in from the margin for a new line below.
        .position(x: p.x + (ghost.inline ? 64 : 34), y: p.y)
        .transition(.opacity)
    }

    /// Tapped-pin detail: the reason + worked steps, and keep / dismiss.
    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let why = ghost.why, !why.isEmpty {
                AIRichText(content: why).font(.system(size: 12))
            }
            if !ghost.steps.isEmpty {
                ForEach(Array(ghost.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: "\(index + 1)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .background(AppTheme.current.aiAccent, in: Circle())
                        AIRichText(content: step).font(.system(size: 12))
                    }
                }
            }
            HStack(spacing: 10) {
                // Keep — write the suggestion in as real ink.
                Button(action: onAccept) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(AppTheme.current.aiAccent, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("ambient.flickAccept"))
                Button(action: onDismiss) {
                    Text("ai.dismiss").font(.caption.weight(.semibold)).foregroundStyle(SemanticColor.textMutedColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 1)
            .environment(\.layoutDirection, .leftToRight)   // keep/dismiss stay LTR
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SemanticColor.separator))
        .frame(maxWidth: 280, alignment: detailRTL ? .trailing : .leading)
        // Hebrew reason/steps read right-to-left (number badge on the right).
        .environment(\.layoutDirection, detailRTL ? .rightToLeft : .leftToRight)
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

            Text(verbatim: item.body)
                .font(.subheadline)
                .foregroundStyle(.primary)
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

    var body: some View {
        Circle()
            .fill(AppTheme.current.aiAccent)
            .frame(width: 34, height: 34)
            .overlay(Lucide("sparkles", size: 17).foregroundStyle(.white))
            .scaleEffect(breathe ? 1.0 : 0.82)
            .shadow(color: AppTheme.current.aiAccent.opacity(breathe ? 0.7 : 0.25),
                    radius: breathe ? 18 : 7)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { breathe = true }
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .accessibilityLabel(Text("ai.thinking"))
    }
}

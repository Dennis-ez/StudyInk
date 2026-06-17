import SwiftUI

/// The tutor's margin lane: glyphs anchored in page-content space (they scroll/
/// zoom with the ink), and the note that unfolds from a tapped glyph. Empty
/// regions pass touches through to the canvas.
struct MarginLaneView: View {
    @ObservedObject var ambient: AmbientTutorController
    let pageIndex: Int
    let transform: CanvasTransform
    var onFixIt: (MarginItem) -> Void = { _ in }
    var onShowWhy: (MarginItem) -> Void = { _ in }

    /// Page-space x of the margin gutter (where the red rule lives).
    private let marginPageX: CGFloat = 34

    private var pageItems: [MarginItem] { ambient.items(onPage: pageIndex) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Faint amber lane wash — the only "it's on" cue.
                if ambient.isOn && !pageItems.isEmpty {
                    LinearGradient(
                        colors: [AppTheme.current.aiAccent.opacity(0.07), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 72)
                    .allowsHitTesting(false)
                }

                // Glyphs at each line's content-space y.
                ForEach(pageItems) { item in
                    let p = transform.toScreen(CGPoint(x: marginPageX, y: item.anchorRect.midY))
                    AmbientGlyphView(glyph: item.glyph)
                        .position(x: p.x, y: p.y)
                        .contentShape(Circle())
                        .onTapGesture { ambient.open(item.id) }
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .accessibilityLabel(Text(item.glyph == .correct ? "ambient.glyph.correct" : "ambient.glyph.attend"))
                }

                // The open note (max one at a time), parked on the trailing side
                // at the glyph's line height.
                if let id = ambient.openItemID,
                   let item = ambient.items.first(where: { $0.id == id }) {
                    let p = transform.toScreen(CGPoint(x: marginPageX, y: item.anchorRect.midY))
                    MarginNoteView(
                        item: item,
                        onDismiss: { ambient.dismiss() },
                        onFixIt: { onFixIt(item) },
                        onShowWhy: { onShowWhy(item) }
                    )
                    .frame(width: 300)
                    .position(
                        x: geo.size.width - 170,
                        y: min(max(p.y, 120), geo.size.height - 170)
                    )
                    .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                }
            }
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
            Circle().strokeBorder(glyph.color.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
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
                Text(verbatim: "= \(result)")
                    .font(.fraunces(15, weight: .medium, relativeTo: .subheadline).italic())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(SemanticColor.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.vertical, 9)
            }

            HStack(spacing: 10) {
                Button(action: onFixIt) {
                    Text("ambient.fixIt")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13).padding(.vertical, 6)
                        .background(SemanticColor.success, in: Capsule())
                }
                .buttonStyle(.plain)
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

import SwiftUI

// MARK: - Smart Collapse — IDE-style handwriting folding
//
// Lasso a block of work → "Fold" → a paper-coloured cover hides it behind a
// "collapsed" pill; tap to expand. The strokes are NEVER removed from the drawing
// (no data-loss risk) — the cover just hides them. Session-scoped for now (folds
// clear on page change); durable folding is a later step.

/// One folded region, in PAGE coordinates. Codable so folds persist per page.
struct FoldedBlock: Identifiable, Equatable, Codable {
    var id = UUID()
    var rect: CGRect
    var count: Int
}

/// The paper-coloured cover + "collapsed" pill drawn over a folded block. Tap to
/// expand. Tracks the canvas transform so it stays glued to the work.
struct FoldedBlockCover: View {
    let block: FoldedBlock
    let transform: CanvasTransform
    var onExpand: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var paper: Color {
        colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.118) : .white
    }

    var body: some View {
        let tl = transform.toScreen(CGPoint(x: block.rect.minX, y: block.rect.minY))
        let br = transform.toScreen(CGPoint(x: block.rect.maxX, y: block.rect.maxY))
        let w = max(120, br.x - tl.x) + 16
        let h = max(34, br.y - tl.y) + 10

        Button(action: onExpand) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(paper)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(AppTheme.current.aiAccent.opacity(0.4),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
                .overlay(
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.bold))
                        Text("collapse.collapsed")
                            .font(.footnote.weight(.medium))
                        Text(verbatim: "·  \(block.count)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(AppTheme.current.aiAccent)
                )
                .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .frame(width: w, height: h)
        .position(x: (tl.x + br.x) / 2, y: (tl.y + br.y) / 2)
        .accessibilityLabel(Text("collapse.expand"))
    }
}

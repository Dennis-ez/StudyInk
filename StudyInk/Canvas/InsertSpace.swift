import SwiftUI

/// Apple-style "Insert Space": a draggable handle at the insert line; dragging it
/// down opens a gap and the content below slides with the drag (a live snapshot),
/// committed on Done. The actual strokes only move once, on commit.
struct InsertSpaceSession {
    var lineYPage: CGFloat       // page-space y of the insert line
    var belowImage: UIImage      // snapshot of the page region BELOW the line
    var pageSize: CGSize
}

struct InsertSpaceOverlay: View {
    let session: InsertSpaceSession
    let transform: CanvasTransform
    @Binding var dragPage: CGFloat   // inserted amount, page units
    var onCommit: () -> Void
    var onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragStart: CGFloat?

    private var paper: Color { colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.118) : .white }
    private var accent: Color { AppTheme.current.aiAccent }

    var body: some View {
        let zoom = transform.zoomScale
        let pageLeft = transform.toScreen(.zero).x
        let lineY = transform.toScreen(CGPoint(x: 0, y: session.lineYPage)).y
        let pageW = session.pageSize.width * zoom
        let belowH = (session.pageSize.height - session.lineYPage) * zoom
        let gap = dragPage * zoom
        let grabberY = lineY + gap

        ZStack(alignment: .topLeading) {
            // Paper over the original below-region + the new gap (hides the real
            // strokes while the snapshot stands in for them).
            Rectangle().fill(paper)
                .frame(width: pageW, height: belowH + gap)
                .position(x: pageLeft + pageW / 2, y: lineY + (belowH + gap) / 2)

            // The content below, slid down by the drag.
            Image(uiImage: session.belowImage)
                .resizable()
                .frame(width: pageW, height: belowH)
                .position(x: pageLeft + pageW / 2, y: grabberY + belowH / 2)

            // The insert line.
            Rectangle().fill(accent.opacity(0.55))
                .frame(width: pageW, height: 1.5)
                .position(x: pageLeft + pageW / 2, y: lineY)

            // Draggable grabber that rides the top of the moved content.
            Capsule().fill(accent)
                .frame(width: 70, height: 8)
                .overlay(Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                .shadow(color: accent.opacity(0.4), radius: 6, y: 2)
                .position(x: pageLeft + pageW / 2, y: grabberY)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if dragStart == nil { dragStart = dragPage }
                            dragPage = max(0, (dragStart ?? 0) + v.translation.height / zoom)
                        }
                        .onEnded { _ in dragStart = nil }
                )

            // Done / Cancel, above the line.
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("action.cancel").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(SemanticColor.separator))
                }
                Button(action: onCommit) {
                    Text("action.done").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(accent, in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .position(x: pageLeft + pageW / 2, y: max(64, lineY - 30))
        }
        .ignoresSafeArea()
    }
}

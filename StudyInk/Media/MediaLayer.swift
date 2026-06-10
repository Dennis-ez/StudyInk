import SwiftUI

/// Renders page media (images, stickers, inline PDF pages) above the template and
/// below the ink. Items are draggable and pinch-resizable when selected.
struct MediaLayer: View {
    @Binding var items: [MediaItemModel]
    let transform: CanvasTransform
    @Binding var selectedItemID: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach($items) { $item in
                MediaItemView(
                    item: $item,
                    isSelected: selectedItemID == item.id,
                    transform: transform,
                    onSelect: { selectedItemID = item.id },
                    onDelete: {
                        MediaStore.delete(fileName: item.fileName)
                        items.removeAll { $0.id == item.id }
                    }
                )
            }
        }
    }
}

private struct MediaItemView: View {
    @Binding var item: MediaItemModel
    let isSelected: Bool
    let transform: CanvasTransform
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var image: UIImage?
    @State private var dragStart: CGPoint?
    @State private var resizeStart: CGSize?

    var body: some View {
        let screenFrame = transform.toScreen(item.frame)

        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .clipped()
        .rotationEffect(.degrees(item.rotation))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 18, height: 18)
                    .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9)).foregroundStyle(.white))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .gesture(resizeGesture)
            }
        }
        .position(x: screenFrame.midX, y: screenFrame.midY)
        .onTapGesture(perform: onSelect)
        .gesture(isSelected ? dragGesture : nil)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("action.delete", systemImage: "trash")
            }
        }
        .task(id: item.fileName) { image = MediaStore.image(named: item.fileName) }
        .accessibilityLabel(Text(item.kind == .sticker ? "media.sticker" : "media.image"))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil { dragStart = CGPoint(x: item.x, y: item.y) }
                guard let start = dragStart else { return }
                item.x = start.x + value.translation.width / transform.zoomScale
                item.y = start.y + value.translation.height / transform.zoomScale
            }
            .onEnded { _ in dragStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if resizeStart == nil { resizeStart = CGSize(width: item.width, height: item.height) }
                guard let start = resizeStart else { return }
                let aspect = start.height / max(start.width, 1)
                let newWidth = max(32, start.width + value.translation.width / transform.zoomScale)
                item.width = newWidth
                item.height = newWidth * aspect
            }
            .onEnded { _ in resizeStart = nil }
    }
}

import SwiftUI

/// Renders page media (images, stickers, inline PDF pages) above the template and
/// below the ink. Tap to select; selected items can be dragged, pinch-resized,
/// rotated with two fingers (or via the corner handle), or deleted.
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
                        selectedItemID = nil
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
    @State private var rotateStart: Double?

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
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                handle(systemName: "arrow.up.left.and.arrow.down.right")
                    .gesture(resizeGesture)
                    .accessibilityLabel(Text("media.resize"))
            }
        }
        .overlay(alignment: .topLeading) {
            if isSelected {
                Button(action: onDelete) {
                    handle(systemName: "xmark", tint: Color("errorRed"))
                }
                .accessibilityLabel(Text("action.delete"))
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                handle(systemName: "rotate.right")
                    .gesture(rotateHandleGesture(center: screenFrame))
                    .accessibilityLabel(Text("media.rotate"))
            }
        }
        .rotationEffect(.degrees(item.rotation))
        .position(x: screenFrame.midX, y: screenFrame.midY)
        .onTapGesture(perform: onSelect)
        // Selected items move with one finger and rotate with two.
        .gesture(isSelected ? dragGesture.simultaneously(with: twoFingerRotation) : nil)
        .contextMenu {
            Button {
                item.rotation = 0
            } label: {
                Label("media.resetRotation", systemImage: "arrow.counterclockwise")
            }
            Button(role: .destructive, action: onDelete) {
                Label("action.delete", systemImage: "trash")
            }
        }
        .task(id: item.fileName) { image = MediaStore.image(named: item.fileName) }
        .accessibilityLabel(Text(item.kind == .sticker ? "media.sticker" : "media.image"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func handle(systemName: String, tint: Color = .accentColor) -> some View {
        Circle()
            .fill(tint)
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .contentShape(Circle().scale(1.8))
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

    /// Two-finger twist anywhere on the selected item.
    private var twoFingerRotation: some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(2))
            .onChanged { value in
                if rotateStart == nil { rotateStart = item.rotation }
                item.rotation = (rotateStart ?? 0) + value.rotation.degrees
            }
            .onEnded { _ in rotateStart = nil }
    }

    /// One-finger rotation by dragging the corner handle around the item's center.
    private func rotateHandleGesture(center frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let center = CGPoint(x: frame.midX, y: frame.midY)
                let start = atan2(value.startLocation.y - center.y, value.startLocation.x - center.x)
                let now = atan2(value.location.y - center.y, value.location.x - center.x)
                if rotateStart == nil { rotateStart = item.rotation }
                item.rotation = (rotateStart ?? 0) + Double((now - start) * 180 / .pi)
            }
            .onEnded { _ in rotateStart = nil }
    }
}

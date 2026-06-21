import SwiftUI

/// Renders page media (images, stickers, inline PDF pages) above the template and
/// below the ink. Tap to select; a selected item shows a floating action bar
/// (delete · duplicate · copy · cut · crop) ABOVE it and four aspect-locked
/// corner handles ON it for resizing. Drag to move, two fingers to rotate.
struct MediaLayer: View {
    @Binding var items: [MediaItemModel]
    let transform: CanvasTransform
    @Binding var selectedItemID: UUID?
    var snap: SnapMetrics?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach($items) { $item in
                MediaItemView(
                    item: $item,
                    isSelected: selectedItemID == item.id,
                    transform: transform,
                    snap: snap,
                    onSelect: { selectedItemID = item.id },
                    onDelete: {
                        MediaStore.delete(fileName: item.fileName)
                        items.removeAll { $0.id == item.id }
                        selectedItemID = nil
                    },
                    onDuplicate: {
                        let newName = MediaStore.duplicate(fileName: item.fileName) ?? item.fileName
                        var copy = item
                        copy.id = UUID()
                        copy.fileName = newName
                        copy.x += 28
                        copy.y += 28
                        items.append(copy)
                        selectedItemID = copy.id
                    }
                )
            }
        }
        // Handle gestures resolve drag locations in this space so they line up
        // with transform.toScreen coordinates (global space is offset by the
        // editor's chrome, which broke the rotation math).
        .coordinateSpace(name: "mediaLayer")
    }
}

private struct MediaItemView: View {
    @Binding var item: MediaItemModel
    let isSelected: Bool
    let transform: CanvasTransform
    var snap: SnapMetrics?
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void

    @State private var image: UIImage?
    @State private var dragStart: CGPoint?
    @State private var resizeStart: CGRect?
    @State private var rotateStart: Double?
    // Crop mode keeps a normalized [0,1] rectangle of the region to KEEP.
    @State private var cropMode = false
    @State private var cropNorm = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var cropStart: CGRect?

    private enum Corner: CaseIterable {
        case tl, tr, bl, br
        var isRight: Bool { self == .tr || self == .br }
        var isBottom: Bool { self == .bl || self == .br }
        var alignment: Alignment {
            switch self {
            case .tl: return .topLeading
            case .tr: return .topTrailing
            case .bl: return .bottomLeading
            case .br: return .bottomTrailing
            }
        }
    }

    var body: some View {
        let screenFrame = transform.toScreen(item.frame)

        ZStack {
            imageContent(screenFrame)
                .rotationEffect(.degrees(item.rotation))
                .position(x: screenFrame.midX, y: screenFrame.midY)

            // The floating bar sits upright ABOVE the item (never rotates).
            if isSelected {
                Group { cropMode ? AnyView(cropBar) : AnyView(actionBar) }
                    .position(x: screenFrame.midX, y: max(46, screenFrame.minY - 34))
            }
        }
        .onTapGesture(perform: onSelect)
        .gesture(isSelected && !cropMode ? dragGesture.simultaneously(with: twoFingerRotation) : nil)
        .task(id: item.fileName) { image = MediaStore.image(named: item.fileName) }
        .accessibilityLabel(Text(item.kind == .sticker ? "media.sticker" : "media.image"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Only a SELECTED image is interactive; an unselected one lets touches
        // (pan/zoom, drawing) pass through. Tap-to-select is handled by the
        // canvas's finger-tap (onCanvasFingerTap).
        .allowsHitTesting(isSelected)
    }

    // MARK: - Image + handles

    @ViewBuilder
    private func imageContent(_ screenFrame: CGRect) -> some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
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
        .overlay { if cropMode { cropOverlay(screenFrame) } }
        .overlay {
            // Four aspect-locked resize handles (hidden while cropping).
            if isSelected && !cropMode {
                ForEach(Corner.allCases, id: \.self) { corner in
                    cornerHandle()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                        .gesture(resizeGesture(corner, start: screenFrame))
                }
            }
        }
    }

    private func cornerHandle() -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .contentShape(Circle().scale(2.2))
    }

    /// Aspect-locked resize: width follows the horizontal drag, the OPPOSITE
    /// corner stays pinned, height follows the original aspect ratio.
    private func resizeGesture(_ corner: Corner, start screenFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if resizeStart == nil { resizeStart = item.frame }
                guard let start = resizeStart else { return }
                let aspect = start.height / max(start.width, 1)
                let dxPage = value.translation.width / transform.zoomScale
                let deltaW = corner.isRight ? dxPage : -dxPage
                let newW = max(40, start.width + deltaW)
                let newH = newW * aspect
                // Pin the opposite corner: a right handle keeps the left edge, a
                // bottom handle keeps the top edge, and vice-versa.
                let newX = corner.isRight ? start.minX : (start.maxX - newW)
                let newY = corner.isBottom ? start.minY : (start.maxY - newH)
                item.frame = CGRect(x: newX, y: newY, width: newW, height: newH)
            }
            .onEnded { _ in resizeStart = nil }
    }

    // MARK: - Move / rotate

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil { dragStart = CGPoint(x: item.x, y: item.y) }
                guard let start = dragStart else { return }
                var x = start.x + value.translation.width / transform.zoomScale
                var y = start.y + value.translation.height / transform.zoomScale
                if let snap { x = snap.snappedX(x); y = snap.snappedY(y) }
                item.x = x
                item.y = y
            }
            .onEnded { _ in dragStart = nil }
    }

    private var twoFingerRotation: some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(2))
            .onChanged { value in
                if rotateStart == nil { rotateStart = item.rotation }
                item.rotation = (rotateStart ?? 0) + value.rotation.degrees
            }
            .onEnded { _ in rotateStart = nil }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 2) {
            barButton("trash", role: .destructive, label: "action.delete", action: onDelete)
            barButton("plus.square.on.square", label: "media.duplicate", action: onDuplicate)
            barButton("doc.on.doc", label: "media.copy") { copyToPasteboard() }
            barButton("scissors", label: "media.cut") { copyToPasteboard(); onDelete() }
            barButton("crop", label: "media.crop") {
                cropNorm = CGRect(x: 0, y: 0, width: 1, height: 1)
                withAnimation(.easeOut(duration: 0.18)) { cropMode = true }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SemanticColor.separator, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .fixedSize()
    }

    private var cropBar: some View {
        HStack(spacing: 2) {
            barButton("xmark", label: "action.cancel") {
                withAnimation(.easeOut(duration: 0.18)) { cropMode = false }
            }
            barButton("checkmark", tint: SemanticColor.success, label: "action.done") { applyCrop() }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SemanticColor.separator, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .fixedSize()
    }

    private func barButton(_ symbol: String, role: ButtonRole? = nil, tint: Color = .primary,
                           label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(role: role) { Haptics.tap(); action() } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(role == .destructive ? Color("errorRed") : tint)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    // MARK: - Crop

    /// Dim outside the kept region + a border and four corner handles on it.
    private func cropOverlay(_ screenFrame: CGRect) -> some View {
        let w = screenFrame.width, h = screenFrame.height
        let rect = CGRect(x: cropNorm.minX * w, y: cropNorm.minY * h,
                          width: cropNorm.width * w, height: cropNorm.height * h)
        return ZStack {
            Color.black.opacity(0.45)
                .mask {
                    Rectangle()
                        .overlay(Rectangle().frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .blendMode(.destinationOut))
                        .compositingGroup()
                }
                .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
            ForEach(Corner.allCases, id: \.self) { corner in
                cropHandle()
                    .position(
                        x: corner.isRight ? rect.maxX : rect.minX,
                        y: corner.isBottom ? rect.maxY : rect.minY
                    )
                    .gesture(cropDrag(corner, w: w, h: h))
            }
        }
    }

    private func cropHandle() -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .contentShape(Circle().scale(2.4))
    }

    private func cropDrag(_ corner: Corner, w: CGFloat, h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if cropStart == nil { cropStart = cropNorm }
                guard let start = cropStart, w > 0, h > 0 else { return }
                let dnx = value.translation.width / transform.zoomScale / w
                let dny = value.translation.height / transform.zoomScale / h
                let minSize: CGFloat = 0.12
                var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
                if corner.isRight { maxX = min(1, max(start.minX + minSize, start.maxX + dnx)) }
                else { minX = max(0, min(start.maxX - minSize, start.minX + dnx)) }
                if corner.isBottom { maxY = min(1, max(start.minY + minSize, start.maxY + dny)) }
                else { minY = max(0, min(start.maxY - minSize, start.minY + dny)) }
                cropNorm = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in cropStart = nil }
    }

    private func applyCrop() {
        defer { withAnimation(.easeOut(duration: 0.18)) { cropMode = false } }
        guard let img = image, cropNorm != CGRect(x: 0, y: 0, width: 1, height: 1) else { return }
        let s = img.scale
        let pxW = img.size.width * s, pxH = img.size.height * s
        let px = CGRect(x: cropNorm.minX * pxW, y: cropNorm.minY * pxH,
                        width: cropNorm.width * pxW, height: cropNorm.height * pxH).integral
        guard px.width > 1, px.height > 1, let cg = img.cgImage?.cropping(to: px) else { return }
        let out = UIImage(cgImage: cg, scale: s, orientation: img.imageOrientation)
        guard let data = out.pngData(), let newName = MediaStore.save(data) else { return }
        // Shrink the on-page frame to the kept region so the image doesn't move.
        let f = item.frame
        item.frame = CGRect(x: f.minX + f.width * cropNorm.minX,
                            y: f.minY + f.height * cropNorm.minY,
                            width: f.width * cropNorm.width,
                            height: f.height * cropNorm.height)
        item.fileName = newName    // (old file left in place — never shared, but safe to keep)
        image = out
        cropNorm = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func copyToPasteboard() {
        if let img = image { UIPasteboard.general.image = img }
    }
}

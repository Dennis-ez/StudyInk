import SwiftUI

/// Maps between page space (model coordinates) and screen space, tracking the
/// canvas scroll offset and zoom so overlays stay anchored to the ink.
struct CanvasTransform {
    var zoomScale: CGFloat
    var contentOffset: CGPoint

    func toScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoomScale - contentOffset.x, y: point.y * zoomScale - contentOffset.y)
    }

    func toScreen(_ rect: CGRect) -> CGRect {
        CGRect(origin: toScreen(rect.origin),
               size: CGSize(width: rect.width * zoomScale, height: rect.height * zoomScale))
    }

    func toPage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x + contentOffset.x) / zoomScale, y: (point.y + contentOffset.y) / zoomScale)
    }
}

/// Typed text boxes floating above the ink. Boxes live in page space; this layer
/// renders them in screen space via CanvasTransform so they track zoom/scroll.
struct TextBoxLayer: View {
    @Binding var boxes: [TextBoxModel]
    let transform: CanvasTransform
    @Binding var editingBoxID: UUID?
    var snap: SnapMetrics?
    @FocusState private var focusedBox: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach($boxes) { $box in
                TextBoxView(
                    box: $box,
                    isEditing: editingBoxID == box.id,
                    transform: transform,
                    snap: snap,
                    focusedBox: $focusedBox,
                    onBeginEdit: { editingBoxID = box.id; focusedBox = box.id },
                    onDelete: { boxes.removeAll { $0.id == box.id } }
                )
            }
        }
        .onChange(of: focusedBox) { _, newValue in
            if newValue == nil { editingBoxID = nil }
        }
    }
}

private struct TextBoxView: View {
    @Binding var box: TextBoxModel
    let isEditing: Bool
    let transform: CanvasTransform
    var snap: SnapMetrics?
    var focusedBox: FocusState<UUID?>.Binding
    let onBeginEdit: () -> Void
    let onDelete: () -> Void

    @State private var dragStart: CGPoint?
    @State private var resizeStart: CGSize?

    var body: some View {
        let screenFrame = transform.toScreen(box.frame)

        Group {
            if isEditing {
                TextEditor(text: $box.text)
                    .focused(focusedBox, equals: box.id)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
            } else {
                Text(box.text.isEmpty ? " " : box.text)
                    .multilineTextAlignment(box.textAlignment)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: box.isRTL ? .topTrailing : .topLeading)
            }
        }
        .font(Font(box.uiFont as CTFont))
        .underline(box.underline)
        .strikethrough(box.strikethrough)
        .foregroundStyle(Color(hex: box.colorHex) ?? .primary)
        .environment(\.layoutDirection, box.isRTL ? .rightToLeft : .leftToRight)
        .padding(4)
        .frame(width: screenFrame.width, height: screenFrame.height)
        .background {
            if isEditing {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4]))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isEditing {
                boxHandle(systemName: "arrow.up.left.and.arrow.down.right")
                    .gesture(resizeGesture)
                    .accessibilityLabel(Text("textbox.resize"))
            }
        }
        .overlay(alignment: .topTrailing) {
            if isEditing {
                Button(action: onDelete) {
                    boxHandle(systemName: "xmark", tint: Color("errorRed"))
                }
                .accessibilityLabel(Text("action.delete"))
            }
        }
        .position(x: screenFrame.midX, y: screenFrame.midY)
        .onTapGesture(perform: onBeginEdit)
        .gesture(dragGesture)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("action.delete", systemImage: "trash")
            }
        }
        .accessibilityLabel(Text("textbox.accessibility"))
        .accessibilityValue(Text(box.text))
    }

    private func boxHandle(systemName: String, tint: Color = .accentColor) -> some View {
        Circle()
            .fill(tint)
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .contentShape(Circle().scale(1.8))
            .offset(x: 11, y: systemName == "xmark" ? -11 : 11)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil { dragStart = CGPoint(x: box.x, y: box.y) }
                guard let start = dragStart else { return }
                var x = start.x + value.translation.width / transform.zoomScale
                var y = start.y + value.translation.height / transform.zoomScale
                if let snap {
                    x = snap.snappedX(x)
                    y = snap.snappedY(y)
                }
                box.x = x
                box.y = y
            }
            .onEnded { _ in dragStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if resizeStart == nil { resizeStart = CGSize(width: box.width, height: box.height) }
                guard let start = resizeStart else { return }
                var width = max(80, start.width + value.translation.width / transform.zoomScale)
                var height = max(40, start.height + value.translation.height / transform.zoomScale)
                if let snap {
                    // Magnetize trailing edges to the grid.
                    width = max(80, snap.snappedX(box.x + width) - box.x)
                    height = max(40, snap.snappedY(box.y + height) - box.y)
                }
                box.width = width
                box.height = height
            }
            .onEnded { _ in resizeStart = nil }
    }
}

/// Text style editing controls shown while a box is being edited.
struct TextBoxStyleBar: View {
    @Binding var box: TextBoxModel
    @State private var color: Color = .primary

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(TextBoxFonts.options, id: \.name) { option in
                    Button(option.display) { box.fontName = option.name }
                }
            } label: {
                Image(systemName: "textformat")
            }
            Stepper(value: $box.fontSize, in: 9...96, step: 1) {
                Text(verbatim: "\(Int(box.fontSize))")
                    .font(.footnote.monospacedDigit())
            }
            .fixedSize()
            Toggle(isOn: $box.bold) { Image(systemName: "bold") }
            Toggle(isOn: $box.italic) { Image(systemName: "italic") }
            Toggle(isOn: $box.underline) { Image(systemName: "underline") }
            Toggle(isOn: $box.strikethrough) { Image(systemName: "strikethrough") }
            Picker("textbox.alignment", selection: $box.explicitAlignment) {
                Image(systemName: "text.alignleft").tag(TextBoxModel.TextBoxAlignment?.some(.leading))
                Image(systemName: "text.aligncenter").tag(TextBoxModel.TextBoxAlignment?.some(.center))
                Image(systemName: "text.alignright").tag(TextBoxModel.TextBoxAlignment?.some(.trailing))
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            ColorPicker("tool.color", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .onChange(of: color) { _, newValue in box.colorHex = UIColor(newValue).hexString }
        }
        .toggleStyle(.button)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { color = Color(hex: box.colorHex) ?? .primary }
    }
}

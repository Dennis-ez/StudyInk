import SwiftUI
import PencilKit

/// A lasso-captured set of strokes mid-transform.
struct StrokeSelection {
    var pageIndex: Int
    var strokeIndices: [Int]
    /// Union of the selected strokes' render bounds, page space.
    var bounds: CGRect
    /// The selected strokes rendered alone, for the live rotation preview.
    var image: UIImage
}

enum StrokeSelector {
    /// Strokes with at least one path point inside the lasso polygon (page space).
    static func indices(in drawing: PKDrawing, polygon: [CGPoint]) -> [Int] {
        guard polygon.count > 3 else { return [] }
        return drawing.strokes.enumerated().compactMap { index, stroke in
            let path = stroke.path
            let step = max(1, path.count / 24)
            for i in stride(from: 0, to: path.count, by: step) {
                let point = path[i].location.applying(stroke.transform)
                if contains(polygon: polygon, point: point) { return index }
            }
            return nil
        }
    }

    static func selection(from drawing: PKDrawing, polygon: [CGPoint], pageIndex: Int, darkMode: Bool) -> StrokeSelection? {
        let indices = self.indices(in: drawing, polygon: polygon)
        guard !indices.isEmpty else { return nil }
        let strokes = indices.map { drawing.strokes[$0] }
        let bounds = strokes.dropFirst().reduce(strokes[0].renderBounds) { $0.union($1.renderBounds) }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let traits = UITraitCollection(userInterfaceStyle: darkMode ? .dark : .light)
        var image = UIImage()
        traits.performAsCurrent {
            image = PKDrawing(strokes: strokes).image(from: bounds, scale: 2)
        }
        return StrokeSelection(pageIndex: pageIndex, strokeIndices: indices, bounds: bounds, image: image)
    }

    /// Ray-casting point-in-polygon.
    static func contains(polygon: [CGPoint], point: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Bakes a rotation about the selection's center into the strokes.
    static func applyRotation(_ degrees: Double, selection: StrokeSelection, to drawing: PKDrawing) -> PKDrawing {
        let center = CGPoint(x: selection.bounds.midX, y: selection.bounds.midY)
        let rotation = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
        var result = drawing
        for index in selection.strokeIndices where result.strokes.indices.contains(index) {
            result.strokes[index].transform = result.strokes[index].transform.concatenating(rotation)
        }
        return result
    }
}

/// Lasso capture for transform mode: draw a loop (or, in rectangular mode,
/// drag a marquee) and get its page-space polygon. The mode is switchable
/// inline, right in the capture overlay.
struct TransformLassoOverlay: View {
    @Binding var isActive: Bool
    let transform: CanvasTransform
    /// false = freeform loop; true = drag-a-rectangle marquee.
    @State private var rectangular = false
    var onComplete: ([CGPoint]) -> Void

    @State private var points: [CGPoint] = []
    @State private var marquee: CGRect?

    var body: some View {
        if isActive {
            ZStack {
                Color.black.opacity(0.04).ignoresSafeArea()
                if rectangular {
                    if let marquee {
                        Path(marquee)
                            .stroke(SemanticColor.aiCircleStroke, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 5]))
                            .background(Path(marquee).fill(SemanticColor.aiCircleStroke.opacity(0.06)))
                    }
                } else {
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(SemanticColor.aiCircleStroke, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 5]))
                }

                VStack {
                    HStack(spacing: 10) {
                        Text(rectangular ? "lasso.rect.hint" : "lasso.transform.hint")
                            .font(.footnote)
                        Divider().frame(height: 18)
                        // Inline mode switch — no extra toolbar round-trip.
                        modeToggle(symbol: "lasso", labelKey: "tool.lasso.freeform", isRect: false)
                        modeToggle(symbol: "rectangle.dashed", labelKey: "tool.lasso.rect", isRect: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 70)
                    Spacer()
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if rectangular {
                            marquee = CGRect(
                                x: min(value.startLocation.x, value.location.x),
                                y: min(value.startLocation.y, value.location.y),
                                width: abs(value.location.x - value.startLocation.x),
                                height: abs(value.location.y - value.startLocation.y)
                            )
                        } else {
                            points.append(value.location)
                        }
                    }
                    .onEnded { _ in
                        let polygon: [CGPoint]
                        if let rect = marquee, rectangular {
                            polygon = [
                                CGPoint(x: rect.minX, y: rect.minY),
                                CGPoint(x: rect.maxX, y: rect.minY),
                                CGPoint(x: rect.maxX, y: rect.maxY),
                                CGPoint(x: rect.minX, y: rect.maxY),
                            ].map(transform.toPage)
                        } else {
                            polygon = points.map(transform.toPage)
                        }
                        points = []
                        marquee = nil
                        isActive = false
                        onComplete(polygon)
                    }
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    points = []
                    marquee = nil
                    isActive = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .padding()
                }
                .accessibilityLabel(Text("action.cancel"))
            }
            .transition(.opacity)
        }
    }

    private func modeToggle(symbol: String, labelKey: LocalizedStringKey, isRect: Bool) -> some View {
        Button {
            Haptics.selection()
            rectangular = isRect
            points = []
            marquee = nil
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(rectangular == isRect ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(rectangular == isRect ? Color.accentColor.opacity(0.16) : .clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(labelKey))
        .accessibilityAddTraits(rectangular == isRect ? .isSelected : [])
    }
}

/// Live rotation preview for a captured selection: twist with two fingers or
/// drag the corner handle; Done bakes the rotation, Cancel discards it.
struct StrokeTransformOverlay: View {
    let selection: StrokeSelection
    let transform: CanvasTransform
    @Binding var rotation: Double
    var onDone: () -> Void
    var onCancel: () -> Void

    @State private var rotateStart: Double?

    var body: some View {
        let frame = transform.toScreen(selection.bounds)

        ZStack {
            Color.black.opacity(0.03)
                .ignoresSafeArea()
                .onTapGesture(perform: onDone)
                // Two-finger twist anywhere on screen rotates the selection —
                // precise finger rotation, no buttons needed.
                .simultaneousGesture(twistGesture)

            Image(uiImage: selection.image)
                .resizable()
                .frame(width: frame.width, height: frame.height)
                .overlay(
                    Rectangle()
                        .strokeBorder(SemanticColor.accentBlue, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(SemanticColor.accentBlue)
                        .frame(width: 26, height: 26)
                        .overlay(Image(systemName: "rotate.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
                        .contentShape(Circle().scale(1.8))
                        .gesture(handleGesture(center: CGPoint(x: frame.midX, y: frame.midY)))
                        .accessibilityLabel(Text("media.rotate"))
                }
                .rotationEffect(.degrees(rotation))
                .position(x: frame.midX, y: frame.midY)
                .gesture(twistGesture)

            // Rotation lollipop: a single-finger handle hanging off the
            // selection — precise finger rotation that always works.
            rotationLollipop(frame: frame)

            VStack {
                HStack(spacing: 12) {
                    Button {
                        rotation -= 90
                        Haptics.tap()
                    } label: {
                        Image(systemName: "rotate.left")
                    }
                    Button {
                        rotation += 90
                        Haptics.tap()
                    } label: {
                        Image(systemName: "rotate.right")
                    }
                    Text(verbatim: "\(Int(rotation.rounded()))°")
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 44)
                    Button("action.cancel", role: .cancel, action: onCancel)
                    Button("action.done", action: onDone)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(SemanticColor.toolbarBorder, lineWidth: 0.5))
                .padding(.top, 70)
                Spacer()
            }
        }
        // Handle drags resolve in this space so locations line up with the
        // selection frame (global space is offset by the editor's chrome,
        // which made the handles rotate around the wrong point).
        .coordinateSpace(name: "strokeTransform")
    }

    @ViewBuilder
    private func rotationLollipop(frame: CGRect) -> some View {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let radius = frame.height / 2 + 48
        let angle = (rotation + 90) * .pi / 180
        let handle = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))

        Path { path in
            let edge = CGPoint(
                x: center.x + (frame.height / 2) * CGFloat(cos(angle)),
                y: center.y + (frame.height / 2) * CGFloat(sin(angle))
            )
            path.move(to: edge)
            path.addLine(to: handle)
        }
        .stroke(SemanticColor.accentBlue.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

        Circle()
            .fill(SemanticColor.accentBlue)
            .frame(width: 30, height: 30)
            .overlay(
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .contentShape(Circle().scale(2))
            .position(handle)
            .gesture(handleGesture(center: center))
            .accessibilityLabel(Text("media.rotate"))
    }

    private var twistGesture: some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(2))
            .onChanged { value in
                if rotateStart == nil { rotateStart = rotation }
                rotation = (rotateStart ?? 0) + value.rotation.degrees
            }
            .onEnded { _ in rotateStart = nil }
    }

    private func handleGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("strokeTransform"))
            .onChanged { value in
                let start = atan2(value.startLocation.y - center.y, value.startLocation.x - center.x)
                let now = atan2(value.location.y - center.y, value.location.x - center.x)
                if rotateStart == nil { rotateStart = rotation }
                rotation = (rotateStart ?? 0) + Double((now - start) * 180 / .pi)
            }
            .onEnded { _ in rotateStart = nil }
    }
}

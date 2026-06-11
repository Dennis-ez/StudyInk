import SwiftUI
import PencilKit

/// A shape under editing (freshly created or tapped later).
struct EditingShape {
    var pageIndex: Int
    var strokeIndex: Int
    var shape: ShapeRecognizer.Shape
    var ink: PKInk
    var colorHex: String
    var width: Double
}

/// Interactive editing for a recognized shape: drag the shape body to move it,
/// twist with two fingers to rotate (lines/polygons), and drag the nodes to
/// reshape — line endpoints, polygon corners, ellipse center + radii. Edits
/// apply to the ink live; tap anywhere else (or ✓) to finish.
struct ShapeNodeOverlay: View {
    @Binding var editing: EditingShape
    let transform: CanvasTransform
    var snap: SnapMetrics?
    var onChange: (ShapeRecognizer.Shape) -> Void
    var onDone: () -> Void

    @State private var dragStartShape: ShapeRecognizer.Shape?
    @State private var moveStartShape: ShapeRecognizer.Shape?
    @State private var rotateStartShape: ShapeRecognizer.Shape?

    var body: some View {
        ZStack {
            // Tap-away commits; two-finger twist rotates the shape.
            Color.black.opacity(0.02)
                .ignoresSafeArea()
                .onTapGesture(perform: onDone)
                .simultaneousGesture(rotateGesture)

            // Invisible fat outline along the shape: grab it to move the whole shape.
            Color.clear
                .contentShape(previewPath.strokedPath(StrokeStyle(lineWidth: 34, lineCap: .round, lineJoin: .round)))
                .gesture(moveGesture)
                .simultaneousGesture(rotateGesture)

            previewPath
                .stroke(
                    (Color(hex: editing.colorHex) ?? .accentColor).opacity(0.9),
                    style: StrokeStyle(lineWidth: max(editing.width * transform.zoomScale, 1.5), lineCap: .round, lineJoin: .round)
                )
                .allowsHitTesting(false)

            ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(SemanticColor.accentBlue, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .contentShape(Circle().scale(2.4))
                    .position(transform.toScreen(node))
                    .gesture(nodeGesture(index: index))
                    .accessibilityLabel(Text("shape.node"))
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDone) {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .padding(12)
                            .studyGlassCapsule()
                    }
                    .accessibilityLabel(Text("action.done"))
                    .padding(.trailing, 16)
                }
                .padding(.top, 70)
                Spacer()
            }
        }
    }

    // MARK: - Geometry

    private var nodes: [CGPoint] {
        switch editing.shape {
        case .line(let from, let to):
            return [from, to]
        case .polygon(let corners):
            return corners
        case .ellipse(let center, let rx, let ry):
            // center, right (radiusX), bottom (radiusY)
            return [center, CGPoint(x: center.x + rx, y: center.y), CGPoint(x: center.x, y: center.y + ry)]
        }
    }

    /// One-finger drag on the shape body translates the whole shape (snapped).
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if moveStartShape == nil { moveStartShape = editing.shape }
                guard let base = moveStartShape else { return }
                var dx = value.translation.width / transform.zoomScale
                var dy = value.translation.height / transform.zoomScale
                if let snap {
                    // Snap the moved shape's bounding origin to the grid.
                    let box = boundingBox(of: base)
                    dx += snap.snappedX(box.minX + dx) - (box.minX + dx)
                    dy += snap.snappedY(box.minY + dy) - (box.minY + dy)
                }
                let updated = translate(base, dx: dx, dy: dy)
                editing.shape = updated
                onChange(updated)
            }
            .onEnded { _ in moveStartShape = nil }
    }

    /// Two-finger twist rotates lines and polygons about their center.
    /// (Axis-aligned ellipses can't rotate; circles don't need to.)
    private var rotateGesture: some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(2))
            .onChanged { value in
                if rotateStartShape == nil { rotateStartShape = editing.shape }
                guard let base = rotateStartShape else { return }
                let updated = rotate(base, by: value.rotation.radians)
                guard updated != base || value.rotation.radians == 0 else { return }
                editing.shape = updated
                onChange(updated)
            }
            .onEnded { _ in rotateStartShape = nil }
    }

    private func translate(_ shape: ShapeRecognizer.Shape, dx: CGFloat, dy: CGFloat) -> ShapeRecognizer.Shape {
        switch shape {
        case .line(let from, let to):
            return .line(
                from: CGPoint(x: from.x + dx, y: from.y + dy),
                to: CGPoint(x: to.x + dx, y: to.y + dy)
            )
        case .polygon(let corners):
            return .polygon(corners.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
        case .ellipse(let center, let rx, let ry):
            return .ellipse(center: CGPoint(x: center.x + dx, y: center.y + dy), radiusX: rx, radiusY: ry)
        }
    }

    private func rotate(_ shape: ShapeRecognizer.Shape, by angle: Double) -> ShapeRecognizer.Shape {
        let box = boundingBox(of: shape)
        let center = CGPoint(x: box.midX, y: box.midY)
        func spin(_ p: CGPoint) -> CGPoint {
            let dx = p.x - center.x, dy = p.y - center.y
            return CGPoint(
                x: center.x + dx * cos(angle) - dy * sin(angle),
                y: center.y + dx * sin(angle) + dy * cos(angle)
            )
        }
        switch shape {
        case .line(let from, let to):
            return .line(from: spin(from), to: spin(to))
        case .polygon(let corners):
            return .polygon(corners.map(spin))
        case .ellipse:
            return shape
        }
    }

    private func boundingBox(of shape: ShapeRecognizer.Shape) -> CGRect {
        switch shape {
        case .line(let from, let to):
            return CGRect(
                x: min(from.x, to.x), y: min(from.y, to.y),
                width: abs(to.x - from.x), height: abs(to.y - from.y)
            )
        case .polygon(let corners):
            let xs = corners.map(\.x), ys = corners.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { return .zero }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .ellipse(let center, let rx, let ry):
            return CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2)
        }
    }

    private func nodeGesture(index: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartShape == nil { dragStartShape = editing.shape }
                guard let base = dragStartShape else { return }
                var page = transform.toPage(value.location)
                if let snap { page = snap.snappedPoint(page) }
                let updated = moveNode(of: base, index: index, to: page)
                editing.shape = updated
                onChange(updated)
            }
            .onEnded { _ in dragStartShape = nil }
    }

    private func moveNode(of shape: ShapeRecognizer.Shape, index: Int, to point: CGPoint) -> ShapeRecognizer.Shape {
        switch shape {
        case .line(let from, let to):
            return index == 0 ? .line(from: point, to: to) : .line(from: from, to: point)
        case .polygon(var corners):
            guard corners.indices.contains(index) else { return shape }
            corners[index] = point
            return .polygon(corners)
        case .ellipse(let center, let rx, let ry):
            switch index {
            case 0:
                return .ellipse(center: point, radiusX: rx, radiusY: ry)
            case 1:
                return .ellipse(center: center, radiusX: max(abs(point.x - center.x), 8), radiusY: ry)
            default:
                return .ellipse(center: center, radiusX: rx, radiusY: max(abs(point.y - center.y), 8))
            }
        }
    }

    private var previewPath: Path {
        var path = Path()
        switch editing.shape {
        case .line(let from, let to):
            path.move(to: transform.toScreen(from))
            path.addLine(to: transform.toScreen(to))
        case .polygon(let corners):
            guard let first = corners.first else { break }
            path.move(to: transform.toScreen(first))
            for corner in corners.dropFirst() { path.addLine(to: transform.toScreen(corner)) }
            path.closeSubpath()
        case .ellipse(let center, let rx, let ry):
            let rect = CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2)
            path.addEllipse(in: transform.toScreen(rect))
        }
        return path
    }
}

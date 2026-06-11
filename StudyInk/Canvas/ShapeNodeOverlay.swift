import SwiftUI
import PencilKit

/// A freshly created shape under node editing.
struct EditingShape {
    var pageIndex: Int
    var strokeIndex: Int
    var shape: ShapeRecognizer.Shape
    var colorHex: String
    var width: Double
}

/// Draggable nodes on a recognized shape: line endpoints, polygon corners,
/// ellipse center + radius handles. Edits apply to the ink live; tap anywhere
/// else (or ✓) to finish.
struct ShapeNodeOverlay: View {
    @Binding var editing: EditingShape
    let transform: CanvasTransform
    var snap: SnapMetrics?
    var onChange: (ShapeRecognizer.Shape) -> Void
    var onDone: () -> Void

    @State private var dragStartShape: ShapeRecognizer.Shape?

    var body: some View {
        ZStack {
            // Tap-away commits.
            Color.black.opacity(0.02)
                .ignoresSafeArea()
                .onTapGesture(perform: onDone)

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

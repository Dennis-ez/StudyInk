import SwiftUI

// Notability-style shape editing: tap a drawn shape → it lifts off the page and
// this overlay shows it with draggable NODES (line endpoints / ellipse corners /
// polygon vertices). Drag a node to reshape, drag the body to move, tap anywhere
// else to commit (one undo step restores the original).

extension ShapeRecognizer {
    /// A recognized shape → the dense polyline the vector renderer draws as a clean
    /// stroke (same geometry the shape tool commits).
    static func strokeSamples(for shape: Shape, width: CGFloat) -> [InkSample] {
        switch shape {
        case let .line(from, to):
            return [InkSample(location: from, width: width), InkSample(location: to, width: width)]
        case let .ellipse(center, rx, ry):
            return (0...64).map { i -> InkSample in
                let a = CGFloat(i) / 64 * 2 * .pi
                return InkSample(location: CGPoint(x: center.x + cos(a) * rx, y: center.y + sin(a) * ry), width: width)
            }
        case let .polygon(corners):
            guard let first = corners.first else { return [] }
            return (corners + [first]).map { InkSample(location: $0, width: width) }
        }
    }
}

/// The lifted shape being edited (page-space geometry + the stroke's ink).
struct ShapeEditState {
    var shape: ShapeRecognizer.Shape
    let color: UIColor
    let width: CGFloat
}

struct ShapeNodeOverlay: View {
    @Binding var edit: ShapeEditState?
    let transform: CanvasTransform
    /// Commit the reshaped stroke back to the canvas.
    var onCommit: (ShapeEditState) -> Void

    /// Geometry at the start of the current drag — reshaping is computed against
    /// this, not the live value, so a drag is stable (no feedback wobble).
    @State private var dragStart: ShapeRecognizer.Shape?
    @Environment(\.colorScheme) private var colorScheme

    private let nodeSize: CGFloat = 12

    var body: some View {
        if let state = edit {
            ZStack {
                // Tap-out commits (blocks canvas input while editing, like Notability's
                // selection mode — drawing elsewhere first deselects).
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { commit() }

                // The shape itself, drawn at ink color/width — draggable to move.
                shapePath(state.shape)
                    .stroke(Color(displayColor(state.color)),
                            style: StrokeStyle(lineWidth: max(1.5, state.width * transform.zoomScale),
                                               lineCap: .round, lineJoin: .round))
                    .contentShape(shapePath(state.shape).stroke(style: StrokeStyle(lineWidth: 44)))
                    .gesture(moveGesture(state))

                // Dashed marquee just outside the shape, so selection reads instantly.
                let box = screenBox(state.shape).insetBy(dx: -12, dy: -12)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    .foregroundStyle(Color.accentColor.opacity(0.55))
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                    .allowsHitTesting(false)

                // The resize nodes.
                ForEach(Array(nodes(of: state.shape).enumerated()), id: \.offset) { i, p in
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .frame(width: nodeSize, height: nodeSize)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .position(transform.toScreen(p))
                        .contentShape(Circle().inset(by: -16))   // ≥44pt grab area
                        .gesture(nodeGesture(state, nodeIndex: i))
                }
            }
            // Match the canvas's safe-area treatment or every node lands offset by
            // the bottom inset (the lasso-offset bug).
            .ignoresSafeArea(edges: .bottom)
            .transition(.opacity)
        }
    }

    private func commit() {
        guard let state = edit else { return }
        onCommit(state)
        withAnimation(.easeOut(duration: 0.15)) { edit = nil }
    }

    // MARK: geometry

    private func displayColor(_ c: UIColor) -> UIColor {
        InkColorAdapter.displayColor(c, darkMode: colorScheme == .dark)
    }

    private func shapePath(_ shape: ShapeRecognizer.Shape) -> Path {
        var p = Path()
        switch shape {
        case let .line(a, b):
            p.move(to: transform.toScreen(a)); p.addLine(to: transform.toScreen(b))
        case let .ellipse(c, rx, ry):
            let tl = transform.toScreen(CGPoint(x: c.x - rx, y: c.y - ry))
            let br = transform.toScreen(CGPoint(x: c.x + rx, y: c.y + ry))
            p.addEllipse(in: CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y))
        case let .polygon(corners):
            guard let f = corners.first else { break }
            p.move(to: transform.toScreen(f))
            for c in corners.dropFirst() { p.addLine(to: transform.toScreen(c)) }
            p.closeSubpath()
        }
        return p
    }

    /// Screen-space bounding box of the shape (via its nodes).
    private func screenBox(_ shape: ShapeRecognizer.Shape) -> CGRect {
        let pts = nodes(of: shape).map { transform.toScreen($0) }
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Node positions in PAGE space.
    private func nodes(of shape: ShapeRecognizer.Shape) -> [CGPoint] {
        switch shape {
        case let .line(a, b): return [a, b]
        case let .ellipse(c, rx, ry):
            return [CGPoint(x: c.x - rx, y: c.y - ry), CGPoint(x: c.x + rx, y: c.y - ry),
                    CGPoint(x: c.x + rx, y: c.y + ry), CGPoint(x: c.x - rx, y: c.y + ry)]
        case let .polygon(corners): return corners
        }
    }

    // MARK: gestures

    private func moveGesture(_ state: ShapeEditState) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if dragStart == nil { dragStart = state.shape }
                guard let start = dragStart else { return }
                let z = max(transform.zoomScale, 0.01)
                let d = CGPoint(x: v.translation.width / z, y: v.translation.height / z)
                edit?.shape = translated(start, by: d)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func nodeGesture(_ state: ShapeEditState, nodeIndex: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragStart == nil { dragStart = state.shape }
                guard let start = dragStart else { return }
                edit?.shape = reshaped(start, node: nodeIndex, to: transform.toPage(v.location))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func translated(_ shape: ShapeRecognizer.Shape, by d: CGPoint) -> ShapeRecognizer.Shape {
        switch shape {
        case let .line(a, b):
            return .line(from: CGPoint(x: a.x + d.x, y: a.y + d.y), to: CGPoint(x: b.x + d.x, y: b.y + d.y))
        case let .ellipse(c, rx, ry):
            return .ellipse(center: CGPoint(x: c.x + d.x, y: c.y + d.y), radiusX: rx, radiusY: ry)
        case let .polygon(corners):
            return .polygon(corners.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) })
        }
    }

    /// Reshape by dragging one node to a page-space point.
    private func reshaped(_ shape: ShapeRecognizer.Shape, node: Int, to p: CGPoint) -> ShapeRecognizer.Shape {
        switch shape {
        case let .line(a, b):
            return node == 0 ? .line(from: p, to: b) : .line(from: a, to: p)
        case let .ellipse(c, rx, ry):
            // Dragging a corner scales the bounding box anchored at the OPPOSITE corner.
            let corners = [CGPoint(x: c.x - rx, y: c.y - ry), CGPoint(x: c.x + rx, y: c.y - ry),
                           CGPoint(x: c.x + rx, y: c.y + ry), CGPoint(x: c.x - rx, y: c.y + ry)]
            let anchor = corners[(node + 2) % 4]
            let newCenter = CGPoint(x: (anchor.x + p.x) / 2, y: (anchor.y + p.y) / 2)
            return .ellipse(center: newCenter,
                            radiusX: max(8, abs(p.x - anchor.x) / 2),
                            radiusY: max(8, abs(p.y - anchor.y) / 2))
        case .polygon(var corners):
            guard corners.indices.contains(node) else { return .polygon(corners) }
            corners[node] = p
            return .polygon(corners)
        }
    }
}

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
    /// The lasso loop the user drew (page space) — drawn as the marching-ants
    /// outline, Apple-style, instead of a bounding box.
    var polygon: [CGPoint] = []
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
        // The canvas strokes are already DISPLAY-mapped (near-white on a dark page).
        // Render them in a FIXED LIGHT trait so iOS 26 doesn't re-adapt them — a
        // .dark trait inverted the near-white ink to black (invisible / "turns
        // black" in dark mode). Matches PageRenderer.inkImage.
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = PKDrawing(strokes: strokes).image(from: bounds, scale: 2)
        }
        return StrokeSelection(pageIndex: pageIndex, strokeIndices: indices, bounds: bounds, image: image, polygon: polygon)
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

    /// Bakes a scale + rotation (both about the selection's center) AND a
    /// page-space translation into the strokes — one seamless move/resize/rotate.
    static func applyTransform(rotation degrees: Double, scale: CGFloat, translation: CGSize, selection: StrokeSelection, to drawing: PKDrawing) -> PKDrawing {
        let center = CGPoint(x: selection.bounds.midX, y: selection.bounds.midY)
        let combined = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: degrees * .pi / 180)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(translationX: translation.width, y: translation.height))
        var result = drawing
        for index in selection.strokeIndices where result.strokes.indices.contains(index) {
            result.strokes[index].transform = result.strokes[index].transform.concatenating(combined)
        }
        return result
    }
}

/// Lasso capture: draw a loop (or, in rectangular mode, drag a marquee) and get
/// its page-space polygon. The free/rectangle shape comes from the toolbar
/// (LassoOptionsStrip) — no on-canvas toast. Tap off to cancel.
struct TransformLassoOverlay: View {
    @Binding var isActive: Bool
    let transform: CanvasTransform
    /// false = freeform loop; true = drag-a-rectangle marquee (from the toolbar).
    let rectangular: Bool
    /// Pencil-only (like the other tools) unless the user turned pencil-only off.
    var penOnly: Bool = false
    var onComplete: ([CGPoint]) -> Void

    @State private var points: [CGPoint] = []
    @State private var marquee: CGRect?
    @State private var dragStart: CGPoint?
    /// Marching-ants: the dash phase scrolls continuously while selecting.
    @State private var antsPhase: CGFloat = 0

    private var antsStyle: StrokeStyle {
        StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 5], dashPhase: antsPhase)
    }

    var body: some View {
        if isActive {
            ZStack {
                // Pen-aware capture: a UIKit pan that honours pen-only (a finger
                // won't start a lasso unless pencil-only is off), like the pens.
                LassoTouchCatcher(
                    penOnly: penOnly,
                    onChanged: { p in
                        if dragStart == nil { dragStart = p }
                        if rectangular {
                            let s = dragStart ?? p
                            marquee = CGRect(x: min(s.x, p.x), y: min(s.y, p.y),
                                             width: abs(p.x - s.x), height: abs(p.y - s.y))
                        } else {
                            points.append(p)
                        }
                    },
                    onEnded: { complete() },
                    onTap: { reset() }
                )

                if rectangular {
                    if let marquee {
                        Path(marquee)
                            .stroke(SemanticColor.aiCircleStroke, style: antsStyle)
                            .background(Path(marquee).fill(SemanticColor.aiCircleStroke.opacity(0.06)))
                    }
                } else {
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(SemanticColor.aiCircleStroke, style: antsStyle)
                }
            }
            // Whole overlay ignores the safe area so the UIKit catcher's touch
            // coordinates and the SwiftUI Path / transform.toPage all share ONE
            // full-screen space — otherwise the lasso drew offset below the pen.
            .ignoresSafeArea()
            .onAppear {
                // Scroll one dash+gap (12pt) forever → marching ants.
                withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: false)) {
                    antsPhase = -12
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: reset) {
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

    private func reset() {
        points = []; marquee = nil; dragStart = nil; isActive = false
    }

    private func complete() {
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
        reset()
        onComplete(polygon)
    }
}

/// A full-screen UIKit touch catcher for the lasso. A `UIPanGestureRecognizer`
/// reports the drag points and a `UITapGestureRecognizer` reports a plain tap —
/// both gated to PENCIL touches when `penOnly`, so a resting finger can't start a
/// lasso (matching the pen tools' pencil-only behaviour).
private struct LassoTouchCatcher: UIViewRepresentable {
    var penOnly: Bool
    var onChanged: (CGPoint) -> Void
    var onEnded: () -> Void
    var onTap: () -> Void

    private var allowed: [NSNumber] {
        penOnly
            ? [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            : [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
    }

    func makeUIView(context: Context) -> UIView {
        let view = PassthroughCatcher()
        view.penOnly = penOnly
        view.backgroundColor = UIColor.black.withAlphaComponent(0.04)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = allowed
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.allowedTouchTypes = allowed
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        context.coordinator.parent = self
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        (view as? PassthroughCatcher)?.penOnly = penOnly
        for gr in view.gestureRecognizers ?? [] { gr.allowedTouchTypes = allowed }
    }

    /// Captures only the touches the lasso actually wants (pencil, or finger in
    /// finger-draw mode); everything else — single-finger scroll in pencil-only
    /// mode, and any two-finger pinch — falls THROUGH to the canvas scroll view,
    /// so the note still scrolls and zooms while the lasso is armed.
    final class PassthroughCatcher: UIView {
        var penOnly = true
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let touches = event?.allTouches ?? []
            if touches.count >= 2 { return nil }                    // pinch-zoom → scroll view
            if penOnly, let t = touches.first, t.type != .pencil { return nil }  // finger scroll → scroll view
            return super.hitTest(point, with: event)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var parent: LassoTouchCatcher?
        @objc func pan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began, .changed: parent?.onChanged(g.location(in: g.view))
            case .ended, .cancelled, .failed: parent?.onEnded()
            default: break
            }
        }
        @objc func tap(_ g: UITapGestureRecognizer) { parent?.onTap() }
    }
}

/// Apple-style transform for a captured selection: drag to move, twist with
/// TWO fingers to rotate, drag a corner handle to resize. Tap off the selection
/// commits; no anchor/rotation handle, no toolbar of buttons.
struct StrokeTransformOverlay: View {
    let selection: StrokeSelection
    let transform: CanvasTransform
    @Binding var rotation: Double
    /// Screen-space drag offset of the selection (→ page space on commit).
    @Binding var translation: CGSize
    /// Uniform scale factor applied on commit.
    @Binding var scale: CGFloat
    var onDone: () -> Void
    var onCancel: () -> Void
    // Apple-style edit actions.
    var canPaste: Bool = false
    var onCut: () -> Void = {}
    var onCopy: () -> Void = {}
    var onPaste: () -> Void = {}
    var onDuplicate: () -> Void = {}
    var onDelete: () -> Void = {}
    var onCollapse: () -> Void = {}

    @State private var rotateStart: Double?
    @State private var dragStart: CGSize?
    @State private var scaleStart: CGFloat?
    @State private var antsPhase: CGFloat = 0

    /// The marching-ants outline tracing the lasso loop (falling back to the
    /// bounds), with the live move/rotate/scale baked in.
    private func antsOutline(base: CGRect) -> Path {
        let c = CGPoint(x: base.midX, y: base.midY)
        let rad = rotation * .pi / 180
        func tf(_ p: CGPoint) -> CGPoint {
            var q = CGPoint(x: c.x + (p.x - c.x) * scale, y: c.y + (p.y - c.y) * scale)
            let dx = q.x - c.x, dy = q.y - c.y
            q = CGPoint(x: c.x + dx * cos(rad) - dy * sin(rad), y: c.y + dx * sin(rad) + dy * cos(rad))
            return CGPoint(x: q.x + translation.width, y: q.y + translation.height)
        }
        let pts: [CGPoint] = selection.polygon.count >= 3
            ? selection.polygon.map { tf(transform.toScreen($0)) }
            : [CGPoint(x: base.minX, y: base.minY), CGPoint(x: base.maxX, y: base.minY),
               CGPoint(x: base.maxX, y: base.maxY), CGPoint(x: base.minX, y: base.maxY)].map(tf)
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    var body: some View {
        let base = transform.toScreen(selection.bounds)
        let size = CGSize(width: base.width * scale, height: base.height * scale)
        let center = CGPoint(x: base.midX + translation.width, y: base.midY + translation.height)

        ZStack {
            // Tap off the selection to commit, like Apple's lasso. Pinch or
            // twist ANYWHERE on the page resizes/rotates the selection.
            Color.black.opacity(0.02)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDone)
                .simultaneousGesture(moveGesture)   // drag anywhere to move
                .simultaneousGesture(twistGesture)
                .simultaneousGesture(pinchGesture)

            // The selected strokes preview (move/resize/rotate with the gestures).
            Image(uiImage: selection.image)
                .resizable()
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(rotation))
                .position(center)
                .gesture(moveGesture)               // one finger drags
                .simultaneousGesture(twistGesture)  // two fingers rotate
                .simultaneousGesture(pinchGesture)  // …and pinch resizes, even from INSIDE the selection

            // Apple-style marching-ants OUTLINE tracing the lasso loop (not a box,
            // no corner handles — resize is a pinch). Falls back to the bounds.
            antsOutline(base: base)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: [6, 4], dashPhase: antsPhase))
                .allowsHitTesting(false)

            // Apple-style edit menu, floating just above the selection.
            editMenu
                .position(x: center.x, y: max(46, center.y - size.height / 2 - 30))
        }
        .coordinateSpace(name: "strokeTransform")
        .onAppear {
            // Marching ants: the dash sum is 10, so sliding the phase by -10
            // loops seamlessly.
            withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: false)) {
                antsPhase = -10
            }
        }
    }

    // MARK: - Apple-style edit menu

    private var editMenu: some View {
        HStack(spacing: 0) {
            menuButton("Cut", action: onCut)
            menuDivider
            menuButton("Copy", action: onCopy)
            if canPaste {
                menuDivider
                menuButton("Paste", action: onPaste)
            }
            menuDivider
            menuButton("Duplicate", action: onDuplicate)
            menuDivider
            menuButton("Fold", action: onCollapse)
            menuDivider
            menuButton("Delete", tint: .red, action: onDelete)
        }
        .frame(height: 40)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .fixedSize()
    }

    private func menuButton(_ title: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.subheadline)
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var menuDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5, height: 22)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("strokeTransform"))
            .onChanged { value in
                if dragStart == nil { dragStart = translation }
                let b = dragStart ?? .zero
                translation = CGSize(width: b.width + value.translation.width, height: b.height + value.translation.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Pinch anywhere on the page to resize the selection (Apple-style — no corner
    /// handles).
    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if scaleStart == nil { scaleStart = scale }
                scale = min(6, max(0.2, (scaleStart ?? 1) * value.magnification))
            }
            .onEnded { _ in scaleStart = nil }
    }

    private var twistGesture: some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(2))
            .onChanged { value in
                if rotateStart == nil { rotateStart = rotation }
                rotation = (rotateStart ?? 0) + value.rotation.degrees
            }
            .onEnded { _ in rotateStart = nil }
    }
}

private extension Alignment {
    init(_ unit: UnitPoint) {
        switch unit {
        case .topLeading: self = .topLeading
        case .topTrailing: self = .topTrailing
        case .bottomLeading: self = .bottomLeading
        case .bottomTrailing: self = .bottomTrailing
        default: self = .center
        }
    }
}

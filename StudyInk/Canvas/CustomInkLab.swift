import SwiftUI
import UIKit

/// Custom ink engine lab — phases A1 (proven on device: sharp at zoom + pen-accurate)
/// and A2 (this file): PERFORMANCE.
///
/// A2 thesis: drawing stays smooth no matter how many strokes are on the page,
/// because committed strokes are cached to a bitmap (re-rendered only when a stroke
/// commits or the zoom changes) and only the LIVE stroke is redrawn each frame.
/// Without this, redrawing every stroke per frame crawls on a full page.
///
/// Isolated — touches nothing in the real app. Reachable from
/// Settings → Developer → "Custom ink lab (preview)".
///
/// HOW TO TEST A2: tap "+300" a couple of times to load the page with strokes, then
/// write — the live stroke should stay smooth (no lag) even with hundreds on screen.
/// Pinch-zoom + release should still be crisp.
struct CustomInkLabView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lab = InkLabController()

    var body: some View {
        ZStack(alignment: .top) {
            CustomInkScroll(controller: lab).ignoresSafeArea()
            HStack(spacing: 8) {
                Button { lab.addRandom(300) } label: { chip("+300") }
                Button { lab.clear() } label: { chip("Clear") }
                if lab.strokeCount > 0 {
                    Text(verbatim: "\(lab.strokeCount) strokes")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { chip("Done", bold: true) }
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    private func chip(_ text: String, bold: Bool = false) -> some View {
        Text(verbatim: text)
            .font(.footnote.weight(bold ? .semibold : .regular))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Bridges SwiftUI buttons to the UIKit ink view.
final class InkLabController: ObservableObject {
    weak var view: VectorInkView?
    @Published var strokeCount = 0
    func addRandom(_ n: Int) { view?.addRandomStrokes(n) }
    func clear() { view?.clearAll() }
    func syncCount() { strokeCount = view?.strokeCount ?? 0 }
}

struct CustomInkScroll: UIViewRepresentable {
    let controller: InkLabController

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeUIView(context: Context) -> UIScrollView {
        let page = CGSize(width: 820, height: 1100)
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true
        scroll.backgroundColor = UIColor(white: 0.98, alpha: 1)
        scroll.delegate = context.coordinator
        scroll.contentInsetAdjustmentBehavior = .never
        // Notes-app split: ONE finger/pencil draws, TWO fingers pan, pinch zooms.
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.delaysContentTouches = false

        let ink = VectorInkView(frame: CGRect(origin: .zero, size: page))
        ink.backgroundColor = .white
        ink.onChange = { [weak controller] in controller?.syncCount() }
        scroll.contentSize = page
        scroll.addSubview(ink)
        controller.view = ink
        context.coordinator.inkView = ink
        return scroll
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {}

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var inkView: VectorInkView?
        init(_ controller: InkLabController) {}
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { inkView }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            inkView?.setRasterScale(for: scale)
        }
    }
}

private struct InkSample {
    let location: CGPoint
    let width: CGFloat
}

/// Custom vector ink surface.
///
/// Committed strokes live in a cached bitmap (re-rasterised only on commit / zoom).
/// The LIVE stroke is drawn on a separate CAShapeLayer ("wet ink") — a GPU-
/// composited vector layer that's cheap to update every frame and, crucially,
/// NEVER touches the big committed bitmap. That's the fix for the slow live drawing
/// when zoomed in: before, every frame re-blitted the ~100 MB high-res committed
/// image; now the committed image is only drawn on commit and zoom.
final class VectorInkView: UIView {
    private var strokes: [[InkSample]] = []
    private var current: [InkSample] = []
    private var committed: UIImage?          // rasterised `strokes` at contentScaleFactor

    private let baseWidth: CGFloat = 2.6
    private let inkColor = UIColor(white: 0.08, alpha: 1)

    /// The in-progress stroke. Vector → crisp; GPU-composited → cheap per frame.
    private let liveLayer = CAShapeLayer()

    var onChange: (() -> Void)?
    var strokeCount: Int { strokes.count }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        isOpaque = true
        contentScaleFactor = UIScreen.main.scale
        liveLayer.fillColor = nil
        liveLayer.strokeColor = inkColor.cgColor
        liveLayer.lineWidth = baseWidth
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
        liveLayer.frame = bounds
        layer.addSublayer(liveLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        liveLayer.frame = bounds
    }

    // MARK: Zoom — re-rasterise the committed cache at the new resolution.

    func setRasterScale(for zoom: CGFloat) {
        let want = zoom * UIScreen.main.scale
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        let budget: CGFloat = 110 * 1_048_576           // ~110 MB (A3 replaces this with tiling)
        let maxScale = (budget / (4 * w * h)).squareRoot()
        let scale = min(want, maxScale)
        guard abs(scale - contentScaleFactor) > 0.05 else { return }
        contentScaleFactor = scale
        rebuildCommitted()
        setNeedsDisplay()
    }

    // MARK: Pencil input — exact touch points in our own coordinate space.

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        current = [sample(t)]
        updateLiveLayer()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        for ct in event?.coalescedTouches(for: t) ?? [t] { current.append(sample(ct)) }
        updateLiveLayer()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if current.count > 1 {
            strokes.append(current)
            appendToCommitted(current)              // bake into the cache (high-res)
            setNeedsDisplay(strokeBounds(current))  // show the baked version…
            onChange?()
        }
        current = []
        liveLayer.path = nil                        // …and drop the wet stroke
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        current = []
        liveLayer.path = nil
    }

    /// Update the wet-ink layer to the current stroke, with no implicit animation
    /// so it tracks the pen instantly.
    private func updateLiveLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.path = current.isEmpty ? nil : livePath()
        CATransaction.commit()
    }

    private func sample(_ t: UITouch) -> InkSample {
        let force = t.maximumPossibleForce > 0 ? t.force / t.maximumPossibleForce : 0
        let pressure = force > 0 ? force : 0.5
        return InkSample(location: t.location(in: self), width: baseWidth * (0.55 + pressure))
    }

    private func strokeBounds(_ pts: [InkSample]) -> CGRect {
        guard let first = pts.first else { return .zero }
        var r = CGRect(origin: first.location, size: .zero)
        for p in pts { r = r.union(CGRect(origin: p.location, size: .zero)) }
        return r.insetBy(dx: -baseWidth * 3, dy: -baseWidth * 3)
    }

    // MARK: Stress test

    func addRandomStrokes(_ n: Int) {
        for _ in 0..<n {
            let start = CGPoint(x: .random(in: 0...bounds.width), y: .random(in: 0...bounds.height))
            var s: [InkSample] = []
            var p = start
            for _ in 0..<Int.random(in: 6...18) {
                p = CGPoint(x: p.x + .random(in: -14...14), y: p.y + .random(in: -14...14))
                s.append(InkSample(location: p, width: baseWidth * .random(in: 0.6...1.4)))
            }
            strokes.append(s)
        }
        rebuildCommitted()
        setNeedsDisplay()
        onChange?()
    }

    func clearAll() {
        strokes = []; current = []; committed = nil
        liveLayer.path = nil
        setNeedsDisplay()
        onChange?()
    }

    // MARK: Render

    private func committedRenderer() -> UIGraphicsImageRenderer {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = contentScaleFactor
        fmt.opaque = false
        return UIGraphicsImageRenderer(bounds: bounds, format: fmt)
    }

    private func rebuildCommitted() {
        guard bounds.width > 0, !strokes.isEmpty else { committed = nil; return }
        committed = committedRenderer().image { c in
            for s in strokes { drawStroke(s, in: c.cgContext) }
        }
    }

    private func appendToCommitted(_ stroke: [InkSample]) {
        let old = committed
        committed = committedRenderer().image { c in
            old?.draw(in: bounds)
            drawStroke(stroke, in: c.cgContext)
        }
    }

    override func draw(_ rect: CGRect) {
        UIColor.white.setFill()
        UIRectFill(rect)
        committed?.draw(in: bounds)     // cached committed ink only; the wet stroke is liveLayer
    }

    /// Variable-width committed stroke (used to bake into the cache).
    private func drawStroke(_ pts: [InkSample], in ctx: CGContext) {
        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setFillColor(inkColor.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        guard pts.count > 1 else {
            if let p = pts.first {
                ctx.fillEllipse(in: CGRect(x: p.location.x - p.width / 2, y: p.location.y - p.width / 2,
                                           width: p.width, height: p.width))
            }
            return
        }
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let mid = CGPoint(x: (a.location.x + b.location.x) / 2, y: (a.location.y + b.location.y) / 2)
            ctx.setLineWidth((a.width + b.width) / 2)
            ctx.move(to: a.location)
            ctx.addQuadCurve(to: mid, control: a.location)
            ctx.addLine(to: b.location)
            ctx.strokePath()
        }
    }

    /// Single smoothed path for the wet-ink layer (constant width; it bakes to a
    /// variable-width stroke on lift).
    private func livePath() -> CGPath {
        let pts = current
        let path = CGMutablePath()
        guard pts.count > 1 else {
            if let p = pts.first {
                path.addEllipse(in: CGRect(x: p.location.x - baseWidth / 2, y: p.location.y - baseWidth / 2,
                                           width: baseWidth, height: baseWidth))
            }
            return path
        }
        path.move(to: pts[0].location)
        for i in 1..<pts.count {
            let a = pts[i - 1].location, b = pts[i].location
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            path.addQuadCurve(to: mid, control: a)
            path.addLine(to: b)
        }
        return path
    }
}

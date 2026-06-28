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
    /// Strokes finished but not yet baked into the committed bitmap — shown as a
    /// cheap vector layer and flushed into the bitmap in BATCHES, so drawing fast
    /// doesn't re-render the whole ~100 MB high-res page on every single stroke.
    private let pendingLayer = CAShapeLayer()
    private var bakedCount = 0          // strokes baked into the committed IMAGE
    private var displayedBakedCount = 0 // strokes the on-screen bitmap has actually drawn
    private var flushWork: DispatchWorkItem?
    private var warmedUp = false
    private var rasterWork: DispatchWorkItem?
    private let bakeQueue = DispatchQueue(label: "studyink.ink.bake", qos: .userInitiated)
    private var isBaking = false
    private var bakeGeneration = 0      // invalidates in-flight off-main bakes on clear/zoom

    var onChange: (() -> Void)?
    var strokeCount: Int { strokes.count }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        isOpaque = true
        contentScaleFactor = UIScreen.main.scale
        // Pending (not-yet-baked) strokes — filled outlines, beneath the wet stroke.
        pendingLayer.fillColor = inkColor.cgColor
        pendingLayer.strokeColor = nil
        pendingLayer.frame = bounds
        layer.addSublayer(pendingLayer)
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
        pendingLayer.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !warmedUp, bounds.width > 0 else { return }
        warmedUp = true
        // Warm the two pipelines that otherwise hitch on the FIRST stroke: allocate
        // the wet-layer backing store (off-bounds, invisible) and spin up the image
        // renderer so the first commit isn't delayed.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.path = CGPath(rect: CGRect(x: -100, y: -100, width: 1, height: 1), transform: nil)
        CATransaction.commit()
        _ = committedRenderer().image { _ in }
    }

    // MARK: Zoom — re-rasterise the committed cache at the new resolution.

    func setRasterScale(for zoom: CGFloat) {
        // Debounce: rapid zoom in/out fires this repeatedly, and each rebuild
        // re-renders every stroke at the new scale. Only re-render once the zoom
        // settles (the bitmap just scales — briefly soft — until then).
        rasterWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyRasterScale(zoom) }
        rasterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func applyRasterScale(_ zoom: CGFloat) {
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
            rebuildPending()        // show it immediately via the cheap vector layer
            scheduleFlush()         // bake into the bitmap in a batch when drawing pauses
            onChange?()
        }
        current = []
        liveLayer.path = nil        // drop the wet stroke (now held by the pending layer)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        current = []
        liveLayer.path = nil
    }

    /// Update the wet-ink layer to the current stroke, with no implicit animation
    /// so it tracks the pen instantly.
    private func updateLiveLayer() {
        guard !current.isEmpty else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            liveLayer.path = nil
            CATransaction.commit()
            return
        }
        // Match the wet stroke's width to the committed stroke's AVERAGE width
        // (committed uses per-point pressure widths), so the line doesn't jump
        // thinner when you lift.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.lineWidth = avgWidth(current)
        liveLayer.path = livePath()
        CATransaction.commit()
    }

    private func sample(_ t: UITouch) -> InkSample {
        let force = t.maximumPossibleForce > 0 ? t.force / t.maximumPossibleForce : 0
        let pressure = force > 0 ? force : 0.5
        return InkSample(location: t.location(in: self), width: baseWidth * (0.55 + pressure))
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
        flushWork?.cancel(); flushWork = nil
        bakeGeneration += 1     // invalidate any in-flight off-main bake
        strokes = []; current = []; committed = nil; bakedCount = 0; displayedBakedCount = 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        liveLayer.path = nil; pendingLayer.path = nil
        CATransaction.commit()
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
        flushWork?.cancel(); flushWork = nil
        guard bounds.width > 0, !strokes.isEmpty else {
            committed = nil; bakedCount = 0; displayedBakedCount = 0
            setPending(nil)
            return
        }
        let color = inkColor
        committed = committedRenderer().image { c in
            for s in strokes { Self.drawStroke(s, color: color, in: c.cgContext) }
        }
        bakedCount = strokes.count
        bakeGeneration += 1     // supersede any in-flight off-main bake
        // Pending is kept until a full draw advances displayedBakedCount, so the
        // strokes never flash out between this rebuild and the async redraw.
    }

    /// Draw the strokes the on-screen bitmap hasn't confirmed yet, as filled
    /// outlines. Keyed off displayedBakedCount (not bakedCount) so a stroke stays
    /// visible via this layer until draw() proves the bitmap has rendered it — no
    /// flash-out in the gap between baking and the async redraw.
    private func rebuildPending() {
        guard displayedBakedCount < strokes.count else { setPending(nil); return }
        let combined = CGMutablePath()
        for i in displayedBakedCount..<strokes.count {
            let s = strokes[i]
            let outline = smoothedCenterline(s).copy(strokingWithWidth: avgWidth(s),
                                                     lineCap: .round, lineJoin: .round, miterLimit: 10)
            combined.addPath(outline)
        }
        setPending(combined.isEmpty ? nil : combined)
    }

    private func setPending(_ path: CGPath?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pendingLayer.path = path
        CATransaction.commit()
    }

    private func scheduleFlush() {
        flushWork?.cancel()
        // Cap how many strokes pile up unbaked so the pending layer + its rebuild
        // can't grow without bound during continuous drawing.
        if strokes.count - bakedCount >= 40 { flushPending(); return }
        let work = DispatchWorkItem { [weak self] in self?.flushPending() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Bake all pending strokes into the committed bitmap in ONE pass. Pending is
    /// NOT cleared here — draw() advances displayedBakedCount once the bitmap shows
    /// the baked strokes, and only then is pending rebuilt to drop them. (Clearing
    /// pending here raced the async redraw and made strokes flash out.)
    private func flushPending() {
        flushWork = nil
        // One bake at a time. If one is in flight, just return — its completion
        // reschedules a flush for any strokes that arrived meanwhile.
        guard !isBaking else { return }
        guard bakedCount < strokes.count, bounds.width > 0 else { return }
        isBaking = true
        let target = strokes.count
        let newOnes = Array(strokes[bakedCount..<target])
        let old = committed
        let scale = contentScaleFactor
        let bnds = bounds
        let color = inkColor
        let generation = bakeGeneration
        // Bake OFF the main thread so continuous fast drawing never stalls on the
        // full-page re-render; apply the result back on main.
        bakeQueue.async { [weak self] in
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = scale
            fmt.opaque = false
            let img = UIGraphicsImageRenderer(bounds: bnds, format: fmt).image { c in
                old?.draw(in: bnds)
                for s in newOnes { VectorInkView.drawStroke(s, color: color, in: c.cgContext) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBaking = false
                // Discard if a clear/zoom happened while we were baking.
                guard generation == self.bakeGeneration,
                      abs(self.contentScaleFactor - scale) < 0.01 else {
                    if self.bakedCount < self.strokes.count { self.scheduleFlush() }
                    return
                }
                self.committed = img
                self.bakedCount = target
                self.setNeedsDisplay()
                // More strokes arrived during the bake → schedule the next batch.
                if self.bakedCount < self.strokes.count { self.scheduleFlush() }
            }
        }
    }

    override func draw(_ rect: CGRect) {
        UIColor.white.setFill()
        UIRectFill(rect)
        committed?.draw(in: bounds)     // cached committed ink only; wet/pending are layers
        // After a FULL redraw the bitmap is proven to show everything baked, so the
        // pending layer can safely drop those strokes (no flash-out gap).
        if displayedBakedCount != bakedCount,
           rect.width >= bounds.width - 0.5, rect.height >= bounds.height - 0.5 {
            displayedBakedCount = bakedCount
            DispatchQueue.main.async { [weak self] in self?.rebuildPending() }
        }
    }

    /// Variable-width committed stroke (used to bake into the cache). Static so it
    /// is safe to call from the off-main bake queue (reads no instance state).
    private static func drawStroke(_ pts: [InkSample], color: UIColor, in ctx: CGContext) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
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

    private func livePath() -> CGPath { smoothedCenterline(current) }

    private func avgWidth(_ pts: [InkSample]) -> CGFloat {
        guard !pts.isEmpty else { return baseWidth }
        return pts.reduce(0) { $0 + $1.width } / CGFloat(pts.count)
    }

    /// Midpoint-smoothed centerline through the sample points (no width).
    private func smoothedCenterline(_ pts: [InkSample]) -> CGPath {
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

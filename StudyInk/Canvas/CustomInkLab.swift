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

/// Custom vector ink surface. Committed strokes live in a cached bitmap at the
/// current zoom resolution; only the live stroke is redrawn per frame, so drawing
/// cost is independent of how many strokes the page holds.
final class VectorInkView: UIView {
    private var strokes: [[InkSample]] = []
    private var current: [InkSample] = []
    private var committed: UIImage?          // rasterised `strokes` at contentScaleFactor

    private let baseWidth: CGFloat = 2.6
    private let inkColor = UIColor(white: 0.08, alpha: 1)

    var onChange: (() -> Void)?
    var strokeCount: Int { strokes.count }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        isOpaque = true
        contentScaleFactor = UIScreen.main.scale
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let start = current.last?.location
        for ct in event?.coalescedTouches(for: t) ?? [t] { current.append(sample(ct)) }
        // Only invalidate the region the new segment touched → cheap live redraw.
        if let a = start, let b = current.last?.location {
            setNeedsDisplay(segmentRect(a, b))
        } else {
            setNeedsDisplay()
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if current.count > 1 {
            strokes.append(current)
            appendToCommitted(current)      // bake just this stroke into the cache
            onChange?()
        }
        current = []
        setNeedsDisplay()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        current = []
        setNeedsDisplay()
    }

    private func sample(_ t: UITouch) -> InkSample {
        let force = t.maximumPossibleForce > 0 ? t.force / t.maximumPossibleForce : 0
        let pressure = force > 0 ? force : 0.5
        return InkSample(location: t.location(in: self), width: baseWidth * (0.55 + pressure))
    }

    private func segmentRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            .insetBy(dx: -baseWidth * 3, dy: -baseWidth * 3)
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
        committed?.draw(in: bounds)                       // cached committed ink (clipped to `rect` by CG)
        if !current.isEmpty {
            drawStroke(current, in: UIGraphicsGetCurrentContext()!)   // live stroke only
        }
    }

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
}

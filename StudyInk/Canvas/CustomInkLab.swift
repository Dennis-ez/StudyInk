import SwiftUI
import UIKit

/// PHASE A1 of the custom ink engine (the user chose path A — a Notability-style
/// custom renderer — over living with the PencilKit sharp-vs-offset tradeoff).
///
/// This is an ISOLATED proof of concept. It touches nothing in the real app. It
/// validates the one thesis the whole engine rests on, before we invest in the
/// full build-out (tiling, eraser, selection, data model, editor integration):
///
///   A custom VECTOR ink renderer gives BOTH —
///   • sharp ink at any zoom (we re-rasterize the vector strokes at the current
///     zoom resolution, instead of scaling a fixed bitmap like PencilKit), AND
///   • a pen-accurate live stroke (we draw through the exact touch points in our
///     own coordinate space — no PencilKit transform black box to mis-render it).
///
/// HOW TO TEST: write a few small letters, pinch to zoom in, RELEASE, then look —
/// the ink should be crisp (it re-renders on release), and while writing the line
/// should sit exactly under the pen. If both hold, path A is proven.
///
/// NOT in A1 (deliberately): tiling for unbounded zoom/memory (here the re-render
/// resolution is budget-capped), erasing, color/tool choice, undo, persistence.
struct CustomInkLabView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            CustomInkScroll().ignoresSafeArea()
            HStack(spacing: 10) {
                Text(verbatim: "Write, pinch to zoom, release — crisp? pen-accurate?")
                    .font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                Button { dismiss() } label: {
                    Text(verbatim: "Done").fontWeight(.semibold)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }
}

struct CustomInkScroll: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let page = CGSize(width: 820, height: 1100)
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true
        scroll.backgroundColor = UIColor(white: 0.98, alpha: 1)
        scroll.delegate = context.coordinator
        scroll.contentInsetAdjustmentBehavior = .never
        // Notes-app behaviour: ONE finger / pencil draws, TWO fingers pan & pinch
        // zooms. Without this the scroll view's pan eats single-finger drags and
        // the page "just slides" instead of drawing.
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.delaysContentTouches = false

        let ink = VectorInkView(frame: CGRect(origin: .zero, size: page))
        ink.backgroundColor = .white
        scroll.contentSize = page
        scroll.addSubview(ink)
        context.coordinator.inkView = ink
        return scroll
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {}

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var inkView: VectorInkView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { inkView }
        // PencilKit-on-an-external-transform blurs because the bitmap is scaled and
        // never re-rendered. We OWN the renderer, so on zoom we just re-rasterize
        // the vector strokes at the new resolution → crisp. (During the live pinch
        // the layer scales—briefly soft—then snaps crisp here on release, exactly
        // like Notability.)
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            inkView?.setRasterScale(for: scale)
        }
    }
}

/// A point sampled from the pen: where it was and how hard it pressed.
private struct InkSample {
    let location: CGPoint
    let width: CGFloat
}

/// The custom vector ink surface. Strokes are stored as point/width arrays and
/// RE-DRAWN with Core Graphics at the view's current contentScaleFactor, so they
/// stay crisp at any zoom (unlike a fixed-resolution bitmap). The live stroke is
/// drawn through the exact touch points, so it lands under the pen by construction.
final class VectorInkView: UIView {
    private var strokes: [[InkSample]] = []
    private var current: [InkSample] = []

    private let baseWidth: CGFloat = 2.6
    private let inkColor = UIColor(white: 0.08, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        isOpaque = true
        contentScaleFactor = UIScreen.main.scale
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-rasterize the vector strokes at the zoom resolution, BUDGET-BOUNDED so a
    /// single page's backing store can't blow memory (real engine: tile instead).
    func setRasterScale(for zoom: CGFloat) {
        let want = zoom * UIScreen.main.scale
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        let budget: CGFloat = 110 * 1_048_576           // ~110 MB ceiling
        let maxScale = (budget / (4 * w * h)).squareRoot()
        let scale = min(want, maxScale)
        if abs(scale - contentScaleFactor) > 0.05 {
            contentScaleFactor = scale
            setNeedsDisplay()
        }
    }

    // MARK: Pencil input — exact touch points in our own coordinate space.

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        current = [sample(t)]
        setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        // Coalesced touches = every input sample since the last frame → smooth lines.
        for ct in event?.coalescedTouches(for: t) ?? [t] { current.append(sample(ct)) }
        setNeedsDisplay()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if current.count > 1 { strokes.append(current) }
        current = []
        setNeedsDisplay()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        current = []
        setNeedsDisplay()
    }

    private func sample(_ t: UITouch) -> InkSample {
        // Apple Pencil reports force; finger (simulator) reports 0 → fall back to 1.
        let force = t.maximumPossibleForce > 0 ? t.force / t.maximumPossibleForce : 0
        let pressure = force > 0 ? force : 0.5
        return InkSample(location: t.location(in: self), width: baseWidth * (0.55 + pressure))
    }

    // MARK: Render — vector → crisp at any contentScaleFactor.

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(inkColor.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for s in strokes { drawStroke(s, in: ctx) }
        drawStroke(current, in: ctx)
    }

    /// Variable-width freehand: each segment is stroked at the local pen width,
    /// round caps blending them, over a midpoint-smoothed path.
    private func drawStroke(_ pts: [InkSample], in ctx: CGContext) {
        guard pts.count > 1 else {
            if let p = pts.first {   // a dot
                ctx.setFillColor(inkColor.cgColor)
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
            // Quadratic through the previous point smooths the corners.
            ctx.addQuadCurve(to: mid, control: a.location)
            ctx.addLine(to: b.location)
            ctx.strokePath()
        }
    }
}

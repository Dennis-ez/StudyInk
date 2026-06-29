import SwiftUI
import UIKit

/// Custom ink engine lab — TILED renderer (phase A3).
///
/// Committed strokes are rendered by a CATiledLayer: the page is a grid of tiles,
/// each rendered (off the main thread, by Core Animation) only when invalidated or
/// when the zoom changes. So:
///   • committing/erasing a stroke re-renders ONLY the tiles it touches — fast no
///     matter how many strokes are on the page,
///   • zooming re-renders only the VISIBLE tiles at the zoom resolution — crisp at
///     ANY zoom with flat memory (no full-page budget cap), and
///   • the live stroke is a separate "wet" CAShapeLayer — instant, never blocked.
///
/// Isolated — touches nothing in the real app. Settings → Developer → "Custom ink lab".
enum InkTool { case pen, eraser }

struct CustomInkLabView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lab = InkLabController()

    var body: some View {
        ZStack(alignment: .top) {
            CustomInkScroll(controller: lab).ignoresSafeArea()
            HStack(spacing: 8) {
                Button { lab.setTool(.pen) } label: { toolChip("Pen", on: lab.tool == .pen) }
                Button { lab.setTool(.eraser) } label: { toolChip("Eraser", on: lab.tool == .eraser) }
                ForEach([("S", CGFloat(1.6)), ("M", CGFloat(2.6)), ("L", CGFloat(4.5))], id: \.0) { label, w in
                    Button { lab.setWidth(w) } label: {
                        toolChip(label, on: lab.tool == .pen && abs(lab.penWidth - w) < 0.01)
                    }
                }
                Button { lab.undo() } label: { chip("Undo") }.disabled(!lab.canUndo).opacity(lab.canUndo ? 1 : 0.4)
                Button { lab.redo() } label: { chip("Redo") }.disabled(!lab.canRedo).opacity(lab.canRedo ? 1 : 0.4)
                Button { lab.addRandom(300) } label: { chip("+300") }
                Button { lab.clear() } label: { chip("Clear") }
                if lab.strokeCount > 0 {
                    Text(verbatim: "\(lab.strokeCount)")
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

    private func toolChip(_ text: String, on: Bool) -> some View {
        Text(verbatim: text)
            .font(.footnote.weight(on ? .semibold : .regular))
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
    }
}

/// Bridges SwiftUI buttons to the UIKit ink view.
final class InkLabController: ObservableObject {
    weak var view: VectorInkView?
    @Published var strokeCount = 0
    @Published var tool: InkTool = .pen
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var penWidth: CGFloat = 2.6
    func addRandom(_ n: Int) { view?.addRandomStrokes(n) }
    func clear() { view?.clearAll() }
    func setTool(_ t: InkTool) { tool = t; view?.tool = t }
    func setWidth(_ w: CGFloat) { penWidth = w; view?.penWidth = w; if tool != .pen { setTool(.pen) } }
    func undo() { view?.undo() }
    func redo() { view?.redo() }
    func syncState() {
        strokeCount = view?.strokeCount ?? 0
        canUndo = view?.canUndo ?? false
        canRedo = view?.canRedo ?? false
    }
}

struct CustomInkScroll: UIViewRepresentable {
    let controller: InkLabController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let page = CGSize(width: 820, height: 1100)
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 8
        scroll.bouncesZoom = true
        scroll.backgroundColor = UIColor(white: 0.98, alpha: 1)
        scroll.delegate = context.coordinator
        scroll.contentInsetAdjustmentBehavior = .never
        // Notes-app split: ONE finger/pencil draws, TWO fingers pan, pinch zooms.
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.delaysContentTouches = false

        let ink = VectorInkView(frame: CGRect(origin: .zero, size: page))
        ink.backgroundColor = .white
        ink.onChange = { [weak controller] in controller?.syncState() }
        scroll.contentSize = page
        scroll.addSubview(ink)
        controller.view = ink
        context.coordinator.inkView = ink
        return scroll
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {}

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var inkView: VectorInkView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { inkView }
        // No raster bookkeeping on zoom — the CATiledLayer re-renders visible tiles
        // at the new scale by itself.
    }
}

private struct InkSample {
    let location: CGPoint
    let width: CGFloat
}

/// A tiled layer that re-renders invalidated tiles instantly (no fade-in).
final class TiledInkLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

final class VectorInkView: UIView {
    override class var layerClass: AnyClass { TiledInkLayer.self }
    private var tiled: TiledInkLayer { layer as! TiledInkLayer }

    // Model lives on the main thread; an immutable snapshot (+ per-stroke bounds)
    // is what the off-main tile renderer reads, under a lock. `bboxes` is kept in
    // sync with `strokes` so erase/cull never recompute bounds (the erase perf fix).
    private var strokes: [[InkSample]] = []
    private var bboxes: [CGRect] = []
    private var current: [InkSample] = []
    private let modelLock = NSLock()
    private var renderStrokes: [[InkSample]] = []
    private var renderBoxes: [CGRect] = []

    var penWidth: CGFloat = 2.6
    private let inkColor = UIColor(white: 0.08, alpha: 1)

    /// The in-progress "wet" stroke — instant, GPU-composited, never blocks.
    private let liveLayer = CAShapeLayer()
    /// Bridges the wet→tile handoff: a just-committed stroke stays shown here for a
    /// beat (the CATiledLayer re-renders its tile async with no completion callback),
    /// so the stroke doesn't flash out between lifting and the tile appearing.
    private let bridgeLayer = CAShapeLayer()
    private var bridgeStrokes: [[InkSample]] = []
    private var bridgeWork: DispatchWorkItem?
    private var warmedUp = false

    var tool: InkTool = .pen
    private let eraserRadius: CGFloat = 16
    private var erasedThisGesture = false

    // Undo/redo: snapshots of `strokes` (COW — cheap until mutated).
    private var undoStack: [[[InkSample]]] = []
    private var redoStack: [[[InkSample]]] = []
    private let maxUndo = 60
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // Super-sample the base tile resolution (crisper than plain retina even at 1×).
    private let oversample: CGFloat = 2
    private var baseScale: CGFloat { UIScreen.main.scale * oversample }

    var onChange: (() -> Void)?
    var strokeCount: Int { strokes.count }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        isOpaque = true
        // Tiles render at the displayed zoom resolution; levelsOfDetailBias lets it
        // render crisp deep into a zoom-in. Small tiles → each re-render is cheap.
        tiled.tileSize = CGSize(width: 512, height: 512)
        tiled.levelsOfDetail = 5
        tiled.levelsOfDetailBias = 4
        tiled.contentsScale = baseScale

        // Bridge layer (committed-but-maybe-not-yet-tiled strokes), beneath the wet.
        bridgeLayer.fillColor = inkColor.cgColor
        bridgeLayer.strokeColor = nil
        bridgeLayer.frame = bounds
        bridgeLayer.contentsScale = baseScale
        layer.addSublayer(bridgeLayer)

        liveLayer.fillColor = nil
        liveLayer.strokeColor = inkColor.cgColor
        liveLayer.lineWidth = penWidth
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
        liveLayer.frame = bounds
        liveLayer.contentsScale = baseScale
        layer.addSublayer(liveLayer)
        publishModel()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        liveLayer.frame = bounds
        bridgeLayer.frame = bounds
        warmUp()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        warmUp()
    }

    /// Allocate the wet-layer backing store up front (off-bounds, invisible) so the
    /// FIRST stroke doesn't hitch while CA lazily allocates it.
    private func warmUp() {
        guard window != nil, !warmedUp, bounds.width > 0 else { return }
        warmedUp = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        liveLayer.path = CGPath(rect: CGRect(x: -100, y: -100, width: 1, height: 1), transform: nil)
        liveLayer.path = nil
        CATransaction.commit()
    }

    // MARK: Model snapshot for the off-main tile renderer

    private func publishModel() {
        modelLock.lock()
        renderStrokes = strokes      // bboxes kept in sync with strokes (no recompute)
        renderBoxes = bboxes
        modelLock.unlock()
    }

    private func rebuildBBoxes() { bboxes = strokes.map { strokeBounds($0) } }

    // MARK: Bridge layer (wet→tile handoff)

    private func rebuildBridge() {
        let combined = CGMutablePath()
        for s in bridgeStrokes {
            combined.addPath(Self.inkPath(s).copy(strokingWithWidth: Self.avgWidth(s),
                                                  lineCap: .round, lineJoin: .round, miterLimit: 10))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bridgeLayer.path = combined.isEmpty ? nil : combined
        CATransaction.commit()
    }
    private func scheduleBridgeClear() {
        bridgeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.clearBridge() }
        bridgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    private func clearBridge() {
        bridgeWork?.cancel(); bridgeWork = nil
        bridgeStrokes = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bridgeLayer.path = nil
        CATransaction.commit()
    }

    /// Publish the model, then re-render the affected tiles (or all, if `rect` nil).
    private func invalidate(_ rect: CGRect? = nil) {
        publishModel()
        if let rect, !rect.isNull { tiled.setNeedsDisplay(rect) } else { tiled.setNeedsDisplay() }
    }

    // MARK: Tile render — called OFF the main thread by CATiledLayer

    override func draw(_ rect: CGRect) {
        modelLock.lock()
        let snap = renderStrokes
        let boxes = renderBoxes
        modelLock.unlock()
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(rect)
        let color = inkColor
        for i in snap.indices where boxes[i].intersects(rect) {
            Self.drawStroke(snap[i], color: color, in: ctx)
        }
    }

    // MARK: Pencil input

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        if tool == .eraser {
            erasedThisGesture = false
            let dirty = eraseAt(t.location(in: self))
            if !dirty.isNull { invalidate(dirty); onChange?() }
            return
        }
        current = [sample(t)]
        updateLiveLayer()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        if tool == .eraser {
            var dirty = CGRect.null
            for ct in event?.coalescedTouches(for: t) ?? [t] { dirty = dirty.union(eraseAt(ct.location(in: self))) }
            if !dirty.isNull { invalidate(dirty); onChange?() }
            return
        }
        for ct in event?.coalescedTouches(for: t) ?? [t] { current.append(sample(ct)) }
        updateLiveLayer()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if tool == .eraser { return }
        if current.count > 1 {
            pushUndo()
            let box = strokeBounds(current)
            strokes.append(current)
            bboxes.append(box)
            bridgeStrokes.append(current)   // hold it on the bridge until the tile renders
            rebuildBridge()
            invalidate(box)
            scheduleBridgeClear()
            onChange?()
        }
        current = []
        liveLayer.path = nil    // committed stroke now held by the bridge, then the tiles
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        current = []
        liveLayer.path = nil
    }

    private func sample(_ t: UITouch) -> InkSample {
        let force = t.maximumPossibleForce > 0 ? t.force / t.maximumPossibleForce : 0
        let pressure = force > 0 ? force : 0.5
        return InkSample(location: t.location(in: self), width: penWidth * (0.55 + pressure))
    }

    private func updateLiveLayer() {
        guard !current.isEmpty else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            liveLayer.path = nil
            CATransaction.commit()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.lineWidth = Self.avgWidth(current)
        liveLayer.path = Self.inkPath(current)
        CATransaction.commit()
    }

    // MARK: Eraser — whole-stroke. Returns the union bounds of removed strokes.

    @discardableResult
    private func eraseAt(_ p: CGPoint) -> CGRect {
        let r = eraserRadius
        // Broad-phase on the CACHED bbox (no per-point bounds recompute), then a
        // point scan only for strokes whose box is under the eraser.
        func hits(_ i: Int) -> Bool {
            bboxes[i].insetBy(dx: -r, dy: -r).contains(p)
                && strokes[i].contains { hypot($0.location.x - p.x, $0.location.y - p.y) <= r + $0.width / 2 }
        }
        guard strokes.indices.contains(where: hits) else { return .null }   // nothing under the eraser

        let snapshot = strokes
        var removed = CGRect.null
        var keepStrokes: [[InkSample]] = []
        var keepBoxes: [CGRect] = []
        keepStrokes.reserveCapacity(strokes.count)
        keepBoxes.reserveCapacity(strokes.count)
        for i in strokes.indices {
            if hits(i) { removed = removed.union(bboxes[i]) }
            else { keepStrokes.append(strokes[i]); keepBoxes.append(bboxes[i]) }
        }
        if !erasedThisGesture {     // one undo step per gesture
            erasedThisGesture = true
            undoStack.append(snapshot)
            if undoStack.count > maxUndo { undoStack.removeFirst() }
            redoStack.removeAll()
            clearBridge()           // a bridged stroke may be among those erased
        }
        strokes = keepStrokes
        bboxes = keepBoxes
        return removed.isNull ? .null : removed.insetBy(dx: -r, dy: -r)
    }

    // MARK: Undo / redo

    private func pushUndo() {
        undoStack.append(strokes)
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(strokes)
        strokes = prev
        afterHistoryChange()
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(strokes)
        strokes = next
        afterHistoryChange()
    }
    private func afterHistoryChange() {
        current = []
        liveLayer.path = nil
        clearBridge()
        rebuildBBoxes()
        invalidate()
        onChange?()
    }

    // MARK: Stress test + clear

    func addRandomStrokes(_ n: Int) {
        pushUndo()
        for _ in 0..<n {
            let start = CGPoint(x: .random(in: 0...bounds.width), y: .random(in: 0...bounds.height))
            var s: [InkSample] = []
            var p = start
            for _ in 0..<Int.random(in: 6...18) {
                p = CGPoint(x: p.x + .random(in: -14...14), y: p.y + .random(in: -14...14))
                s.append(InkSample(location: p, width: penWidth * .random(in: 0.6...1.4)))
            }
            strokes.append(s)
            bboxes.append(strokeBounds(s))
        }
        invalidate()
        onChange?()
    }

    func clearAll() {
        if !strokes.isEmpty { pushUndo() }   // clearing is undoable
        strokes = []
        bboxes = []
        current = []
        liveLayer.path = nil
        clearBridge()
        invalidate()
        onChange?()
    }

    // MARK: Geometry helpers

    private func strokeBounds(_ pts: [InkSample]) -> CGRect {
        guard let first = pts.first else { return .null }
        var r = CGRect(origin: first.location, size: .zero)
        for s in pts { r = r.union(CGRect(origin: s.location, size: .zero)) }
        let w = (pts.map(\.width).max() ?? penWidth)
        return r.insetBy(dx: -w, dy: -w)   // pad for the pen width so cull/invalidate cover the ink
    }

    /// ONE width for the whole stroke. The wet preview, the bridge, and the committed
    /// render all use this, so what you draw is exactly what lands (no per-segment
    /// width change the instant you lift).
    private static func avgWidth(_ pts: [InkSample]) -> CGFloat {
        guard !pts.isEmpty else { return 2.6 }
        return pts.reduce(0) { $0 + $1.width } / CGFloat(pts.count)
    }

    /// Midpoint-smoothed centerline. Static → also safe from the off-main tile render.
    private static func inkPath(_ pts: [InkSample]) -> CGPath {
        let path = CGMutablePath()
        guard pts.count > 1 else {
            if let p = pts.first {
                path.addEllipse(in: CGRect(x: p.location.x - p.width / 2, y: p.location.y - p.width / 2,
                                           width: p.width, height: p.width))
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

    /// Committed render: stroke the SAME centerline at the SAME width as the preview.
    private static func drawStroke(_ pts: [InkSample], color: UIColor, in ctx: CGContext) {
        guard pts.count > 1 else {
            if let p = pts.first {
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: CGRect(x: p.location.x - p.width / 2, y: p.location.y - p.width / 2,
                                           width: p.width, height: p.width))
            }
            return
        }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(avgWidth(pts))
        ctx.addPath(inkPath(pts))
        ctx.strokePath()
    }
}

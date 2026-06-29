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
enum InkTool { case pen, eraser, shape }

struct CustomInkLabView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lab = InkLabController()

    var body: some View {
        ZStack(alignment: .top) {
            CustomInkScroll(controller: lab).ignoresSafeArea()
            HStack(spacing: 8) {
                Button { lab.setTool(.pen) } label: { toolChip("Pen", on: lab.tool == .pen) }
                Button { lab.setTool(.eraser) } label: { toolChip("Eraser", on: lab.tool == .eraser) }
                Button { lab.setTool(.shape) } label: { toolChip("Shape", on: lab.tool == .shape) }
                ForEach([("S", CGFloat(1.6)), ("M", CGFloat(2.6)), ("L", CGFloat(4.5))], id: \.0) { label, w in
                    Button { lab.setWidth(w) } label: {
                        toolChip(label, on: lab.tool == .pen && abs(lab.penWidth - w) < 0.01)
                    }
                }
                ForEach(Array(lab.palette.enumerated()), id: \.offset) { i, c in
                    Button { lab.setColor(i) } label: {
                        Circle().fill(Color(c)).frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(
                                lab.tool == .pen && lab.colorIndex == i ? Color.primary : Color.black.opacity(0.15),
                                lineWidth: lab.tool == .pen && lab.colorIndex == i ? 2.5 : 1))
                    }
                }
                Button { lab.undo() } label: { chip("Undo") }.disabled(!lab.canUndo).opacity(lab.canUndo ? 1 : 0.4)
                Button { lab.redo() } label: { chip("Redo") }.disabled(!lab.canRedo).opacity(lab.canRedo ? 1 : 0.4)
                Button { lab.addRandom(300) } label: { chip("+300") }
                Button { lab.cyclePaper() } label: { chip(lab.paperName) }
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
    @Published var colorIndex = 0
    @Published var paperName = "Ruled"
    private let papers: [(PageTemplate?, String)] = [(.wideRuled, "Ruled"), (.squareGrid, "Grid"), (.dotGrid, "Dots"), (nil, "Blank")]
    private var paperIdx = 0
    let palette: [UIColor] = [UIColor(white: 0.08, alpha: 1), .systemBlue, .systemRed, .systemGreen]
    func cyclePaper() {
        paperIdx = (paperIdx + 1) % papers.count
        view?.paperTemplate = papers[paperIdx].0
        paperName = papers[paperIdx].1
    }
    func addRandom(_ n: Int) { view?.addRandomStrokes(n) }
    func clear() { view?.clearAll() }
    func setTool(_ t: InkTool) { tool = t; view?.tool = t }
    func setWidth(_ w: CGFloat) { penWidth = w; view?.penWidth = w; if tool != .pen { setTool(.pen) } }
    func setColor(_ i: Int) { colorIndex = i; view?.setColor(palette[i]); if tool != .pen { setTool(.pen) } }
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
        // Dynamic "desk" colour — auto-adapts to dark mode with the trait collection.
        scroll.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.06, alpha: 1) : UIColor(white: 0.98, alpha: 1) }
        scroll.delegate = context.coordinator
        scroll.contentInsetAdjustmentBehavior = .never
        // Notes-app split: ONE finger/pencil draws, TWO fingers pan, pinch zooms.
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.delaysContentTouches = false

        let ink = VectorInkView(frame: CGRect(origin: .zero, size: page))
        ink.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.12, alpha: 1) : .white }
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

// InkSample + Stroke are shared (defined in VectorInk.swift).
private typealias Stroke = VectorInk.Stroke

/// A tiled layer that re-renders invalidated tiles instantly (no fade-in).
final class TiledInkLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

final class VectorInkView: UIView {
    override class var layerClass: AnyClass { TiledInkLayer.self }
    private var tiled: TiledInkLayer { layer as! TiledInkLayer }

    // Model lives on the main thread; an immutable snapshot is what the off-main
    // tile renderer reads, under a lock. Each Stroke carries its own colour + bounds.
    private var strokes: [Stroke] = []
    private var current: [InkSample] = []
    private let modelLock = NSLock()
    private var renderStrokes: [Stroke] = []

    var penWidth: CGFloat = 2.6
    var inkColor = UIColor(white: 0.08, alpha: 1)   // current pen colour (selectable)

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
    private var undoStack: [[Stroke]] = []
    private var redoStack: [[Stroke]] = []
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
        contentBounds = bounds        // captured for the off-main tile draw
        warmUp()
    }

    /// Ruled paper toggle — proves real backgrounds (the editor's `PageTemplate`)
    /// render under the vector ink. nil = plain paper.
    var paperTemplate: PageTemplate? = .wideRuled { didSet { tiled.setNeedsDisplay() } }
    private var contentBounds: CGRect = .zero

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyAppearance()
        warmUp()
        loadFromDisk()
    }

    // MARK: Persistence (proves the VectorInk encode/decode round-trip end-to-end)

    private var loadedFromDisk = false
    private var saveWork: DispatchWorkItem?
    private static var saveURL: URL {
        let dir = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("inklab.vink")
    }

    private func loadFromDisk() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let data = try? Data(contentsOf: Self.saveURL),
              let s = VectorInk.decode(data), !s.isEmpty else { return }
        strokes = s
        undoStack.removeAll(); redoStack.removeAll()
        invalidate()
        onChange?()
    }

    /// Debounced autosave, off the main thread.
    private func scheduleSave() {
        guard loadedFromDisk else { return }   // don't overwrite the file before we've loaded it
        saveWork?.cancel()
        let snapshot = strokes
        let url = Self.saveURL
        let work = DispatchWorkItem {
            if let data = VectorInk.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { applyAppearance() }
    }

    /// Allocate the wet-layer backing store up front so the FIRST stroke doesn't
    /// hitch while CA lazily allocates it: keep an off-screen 1px path for ONE
    /// runloop (so CA actually renders/allocates), then clear it.
    private func warmUp() {
        guard window != nil, !warmedUp, bounds.width > 0 else { return }
        warmedUp = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        liveLayer.path = CGPath(rect: CGRect(x: -10, y: -10, width: 1, height: 1), transform: nil)
        CATransaction.commit()
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self?.liveLayer.path = nil
            CATransaction.commit()
        }
    }

    // MARK: Appearance (dark mode) — we own rendering, so adaptation is render-time.

    private var displayDark = false
    private var paperColor: UIColor { displayDark ? UIColor(white: 0.12, alpha: 1) : .white }

    private func applyAppearance() {
        displayDark = traitCollection.userInterfaceStyle == .dark
        backgroundColor = paperColor
        refreshPenDisplay()      // wet + bridge to the adapted pen colour
        invalidate()             // re-render tiles with the new paper + adapted ink
    }

    /// Map a stored (canonical) colour to its on-screen colour for the current
    /// appearance — black ink shows light on a dark page; colours brighten a touch.
    private static func displayColor(_ c: UIColor, dark: Bool) -> UIColor {
        guard dark else { return c }
        var w: CGFloat = 0, a: CGFloat = 0
        if c.getWhite(&w, alpha: &a) { return UIColor(white: 1 - w, alpha: a) }   // black↔white
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: s * 0.85, brightness: min(1, b + 0.22), alpha: a)
    }

    private func refreshPenDisplay() {
        let cg = Self.displayColor(inkColor, dark: displayDark).cgColor
        liveLayer.strokeColor = cg
        bridgeLayer.fillColor = cg
    }

    // MARK: Model snapshot for the off-main tile renderer

    private func publishModel() {
        modelLock.lock()
        renderStrokes = strokes
        modelLock.unlock()
    }

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
        scheduleSave()
        if let rect, !rect.isNull { tiled.setNeedsDisplay(rect) } else { tiled.setNeedsDisplay() }
    }

    // MARK: Tile render — called OFF the main thread by CATiledLayer

    override func draw(_ rect: CGRect) {
        modelLock.lock()
        let snap = renderStrokes
        modelLock.unlock()
        let dark = displayDark
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor((dark ? UIColor(white: 0.12, alpha: 1) : .white).cgColor)
        ctx.fill(rect)
        // Real ruled paper under the ink — the editor's own template renderer, so
        // the lab is an authentic note surface (clipped to the tile by the context).
        if let template = paperTemplate, !contentBounds.isEmpty {
            let lineColor = (dark ? UIColor(red: 0.227, green: 0.227, blue: 0.235, alpha: 1)
                                  : UIColor(red: 0.82, green: 0.82, blue: 0.839, alpha: 1)).cgColor
            let accent = (dark ? UIColor(red: 0.039, green: 0.518, blue: 1, alpha: 1)
                               : UIColor(red: 0, green: 0.478, blue: 1, alpha: 1)).cgColor
            template.drawCG(in: ctx, rect: contentBounds, scale: 1, lineColor: lineColor, accentColor: accent, spacing: 36)
        }
        for s in snap where s.bbox.intersects(rect) {
            Self.drawStroke(s.samples, color: Self.displayColor(s.color, dark: dark), in: ctx)
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
            // Shape tool: snap a rough drawing to clean geometry. ShapeRecognizer is
            // engine-agnostic (takes [CGPoint]) → the recognised shape becomes a clean
            // vector stroke, rendered crisply by the tiles like any other stroke.
            if tool == .shape, let shape = ShapeRecognizer.recognize(points: current.map(\.location)) {
                commit(samples: Self.shapeSamples(shape, width: Self.avgWidth(current)))
            } else {
                commit(samples: current)
            }
        }
        current = []
        liveLayer.path = nil    // committed stroke now held by the bridge, then the tiles
    }

    private func commit(samples: [InkSample]) {
        pushUndo()
        let stroke = Stroke(color: inkColor, samples: samples)
        strokes.append(stroke)
        bridgeStrokes.append(samples)   // hold it on the bridge until the tile renders
        rebuildBridge()
        invalidate(stroke.bbox)
        scheduleBridgeClear()
        onChange?()
    }

    /// A recognised shape → a dense polyline of samples (so the existing renderer
    /// draws it as a clean stroke).
    private static func shapeSamples(_ shape: ShapeRecognizer.Shape, width: CGFloat) -> [InkSample] {
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
        func hits(_ s: Stroke) -> Bool {
            s.bbox.insetBy(dx: -r, dy: -r).contains(p)
                && s.samples.contains { hypot($0.location.x - p.x, $0.location.y - p.y) <= r + $0.width / 2 }
        }
        guard strokes.contains(where: hits) else { return .null }   // nothing under the eraser

        let snapshot = strokes
        var removed = CGRect.null
        var keep: [Stroke] = []
        keep.reserveCapacity(strokes.count)
        for s in strokes {
            if hits(s) { removed = removed.union(s.bbox) }
            else { keep.append(s) }
        }
        if !erasedThisGesture {     // one undo step per gesture
            erasedThisGesture = true
            undoStack.append(snapshot)
            if undoStack.count > maxUndo { undoStack.removeFirst() }
            redoStack.removeAll()
            clearBridge()           // a bridged stroke may be among those erased
        }
        strokes = keep
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
            strokes.append(Stroke(color: inkColor, samples: s))
        }
        invalidate()
        onChange?()
    }

    func clearAll() {
        if !strokes.isEmpty { pushUndo() }   // clearing is undoable
        strokes = []
        current = []
        liveLayer.path = nil
        clearBridge()
        invalidate()
        onChange?()
    }

    /// Pen colour for NEW strokes (stored canonical). Existing strokes keep their own
    /// colour in the tiles; the wet preview + bridge switch to the new colour (adapted
    /// for the current appearance).
    func setColor(_ c: UIColor) {
        inkColor = c
        refreshPenDisplay()
    }

    // MARK: Geometry helpers

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

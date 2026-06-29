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
enum InkTool { case pen, eraser, shape, lasso }

struct CustomInkLabView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lab = InkLabController()

    // One height + radius for EVERY control, so the row never looks ragged.
    private let controlHeight: CGFloat = 34
    private let controlRadius: CGFloat = 9

    var body: some View {
        ZStack(alignment: .top) {
            CustomInkScroll(controller: lab).ignoresSafeArea()
            HStack(spacing: 10) {
                // Tools
                HStack(spacing: 4) {
                    toolButton("Pen", on: lab.tool == .pen) { lab.setTool(.pen) }
                    toolButton("Eraser", on: lab.tool == .eraser) { lab.setTool(.eraser) }
                    toolButton("Shape", on: lab.tool == .shape) { lab.setTool(.shape) }
                    toolButton("Lasso", on: lab.tool == .lasso) { lab.setTool(.lasso) }
                }

                separator

                // Widths
                HStack(spacing: 4) {
                    ForEach([("S", CGFloat(1.6)), ("M", CGFloat(2.6)), ("L", CGFloat(4.5))], id: \.0) { label, w in
                        toolButton(label, on: lab.tool == .pen && abs(lab.penWidth - w) < 0.01, fixedWidth: controlHeight) {
                            lab.setWidth(w)
                        }
                    }
                }

                separator

                // Colours
                HStack(spacing: 6) {
                    ForEach(Array(lab.palette.enumerated()), id: \.offset) { i, c in
                        let selected = lab.tool == .pen && lab.colorIndex == i
                        Button { lab.setColor(i) } label: {
                            Circle().fill(Color(c)).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(
                                    selected ? Color.accentColor : Color.primary.opacity(0.18),
                                    lineWidth: selected ? 2.5 : 1))
                                .frame(width: controlHeight, height: controlHeight)
                        }
                        .buttonStyle(.plain)
                    }
                }

                separator

                // Undo / redo
                HStack(spacing: 4) {
                    actionButton("Undo") { lab.undo() }.disabled(!lab.canUndo).opacity(lab.canUndo ? 1 : 0.4)
                    actionButton("Redo") { lab.redo() }.disabled(!lab.canRedo).opacity(lab.canRedo ? 1 : 0.4)
                }

                separator

                // Page actions
                HStack(spacing: 4) {
                    actionButton("+300") { lab.addRandom(300) }
                    actionButton(lab.paperName) { lab.cyclePaper() }
                    actionButton("Clear") { lab.clear() }
                }

                if lab.strokeCount > 0 {
                    Text(verbatim: "\(lab.strokeCount)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(height: controlHeight)
                }

                Spacer(minLength: 8)

                actionButton("Done", bold: true) { dismiss() }
            }
            .padding(.horizontal, 14).padding(.top, 10)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: controlHeight - 12)
    }

    /// Tool / width chip — fills the shared height, tints when selected.
    private func toolButton(_ text: String, on: Bool, fixedWidth: CGFloat? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: text)
                .font(.footnote.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, fixedWidth == nil ? 12 : 0)
                .frame(width: fixedWidth, height: controlHeight)
                .frame(minWidth: controlHeight)
                .background(
                    on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Neutral action chip (undo/redo/page actions/done) — same height + radius.
    private func actionButton(_ text: String, bold: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: text)
                .font(.footnote.weight(bold ? .semibold : .regular))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: controlHeight)
                .frame(minWidth: controlHeight)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
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

/// Floating layer for a lifted lasso selection: draws the selected strokes (in the
/// layer's LOCAL coords, sized to the selection bbox so the backing store stays small)
/// and is moved via its transform — so dragging a selection never re-renders any tile.
final class FloatingInkLayer: CALayer {
    var strokes: [VectorInk.Stroke] = []
    override func draw(in ctx: CGContext) {
        for s in strokes { VectorInk.drawStroke(s.samples, color: s.color, in: ctx) }
    }
    // No implicit position/transform animations — the selection must track the finger.
    override func action(forKey event: String) -> CAAction? { NSNull() }
}

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

    // Lasso selection. lassoLayer draws the dashed outline (in-progress loop + the
    // selection box); selectionLayer floats the lifted strokes (moved via transform);
    // handleLayer draws the corner + rotate handles (Apple-style transform UI).
    private let lassoLayer = CAShapeLayer()
    private let selectionLayer = FloatingInkLayer()
    private let handleLayer = CAShapeLayer()
    private var lassoPoints: [CGPoint] = []
    private var selectionStrokes: [Stroke] = []     // lifted from the model (canonical colour)
    private var selectionBBox: CGRect = .null        // union bbox in content coords (untransformed)
    /// The live selection transform (translate + uniform scale + rotate), in CONTENT
    /// coords. Identity right after a lift; baked into the model on commit.
    private var selectionTransform: CGAffineTransform = .identity

    /// Which handle the current gesture is dragging.
    private enum SelectionGesture {
        case move(start: CGPoint, base: CGAffineTransform)
        /// Uniform scale about the FIXED (opposite) corner.
        case scale(fixed: CGPoint, grabbed: CGPoint, base: CGAffineTransform)
        /// Rotate about the box centre.
        case rotate(center: CGPoint, startAngle: CGFloat, base: CGAffineTransform)
    }
    private var selectionGesture: SelectionGesture?
    private let handleHitRadius: CGFloat = 22
    private let rotateHandleGap: CGFloat = 28      // rotate handle sits this far above the top edge
    private let handleDotRadius: CGFloat = 6

    var tool: InkTool = .pen {
        didSet { if oldValue == .lasso, tool != .lasso { commitSelection() } }
    }
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

    /// Editor-config: when FALSE the view never autosaves to `inklab.vink` and never
    /// loads it — the host (real editor) owns persistence via `loadStrokes`/`onChange`.
    var persistsToDisk = true

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

        // Floating selection ink (below the dashed outline). Bbox-sized on lift.
        // Anchor at (0,0) so its `transform` is interpreted about its frame ORIGIN
        // (see selectionLayerTransform(for:)), not its centre.
        selectionLayer.anchorPoint = .zero
        selectionLayer.contentsScale = baseScale
        selectionLayer.isHidden = true
        layer.addSublayer(selectionLayer)
        // Dashed lasso loop / selection box on top of everything. Anchor at (0,0) +
        // a full-bounds frame (origin 0) so its `transform` is the content-space affine
        // directly.
        lassoLayer.anchorPoint = .zero
        lassoLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        lassoLayer.strokeColor = UIColor.systemBlue.cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineDashPattern = [6, 4]
        lassoLayer.frame = bounds
        lassoLayer.contentsScale = baseScale
        layer.addSublayer(lassoLayer)
        // Transform handles (corner scale dots + rotate dot) — drawn in content coords
        // at the already-transformed positions, so this layer needs no transform.
        handleLayer.anchorPoint = .zero
        handleLayer.frame = bounds
        handleLayer.lineWidth = 1
        handleLayer.contentsScale = baseScale
        handleLayer.isHidden = true
        layer.addSublayer(handleLayer)
        publishModel()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        liveLayer.frame = bounds
        bridgeLayer.frame = bounds
        lassoLayer.frame = bounds
        handleLayer.frame = bounds
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
        if persistsToDisk { loadFromDisk() }
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
        guard persistsToDisk else { return }   // host owns persistence
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
        if tool == .lasso {
            let p = t.location(in: self)
            if !selectionStrokes.isEmpty, let g = selectionGesture(at: p) {
                selectionGesture = g          // grab a handle (scale/rotate) or the box (move)
            } else {
                commitSelection()             // bake any existing selection, then start a new loop
                lassoPoints = [p]
                updateLassoLayer()
            }
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
        if tool == .lasso {
            let p = t.location(in: self)
            if let g = selectionGesture {
                selectionTransform = transform(for: g, finger: p)
                applySelectionTransform()
            } else if !lassoPoints.isEmpty {
                for ct in event?.coalescedTouches(for: t) ?? [t] { lassoPoints.append(ct.location(in: self)) }
                updateLassoLayer()
            }
            return
        }
        for ct in event?.coalescedTouches(for: t) ?? [t] { current.append(sample(ct)) }
        updateLiveLayer()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if tool == .eraser { return }
        if tool == .lasso {
            if selectionGesture != nil {
                selectionGesture = nil        // selection stays floating at its new transform
            } else if lassoPoints.count > 2 {
                finishLasso()
            } else {
                lassoPoints = []; lassoLayer.path = nil   // a tap: any selection was already committed in began
            }
            return
        }
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
        if tool == .lasso { selectionGesture = nil; lassoPoints = []; if selectionStrokes.isEmpty { lassoLayer.path = nil } }
    }

    // MARK: Lasso selection

    // MARK: Selection handle geometry (Apple-style transform box)

    /// The selection box (untransformed, content coords) — the dashed outline rect.
    private var selectionBoxBase: CGRect { selectionBBox.insetBy(dx: -6, dy: -6) }

    /// The 4 corners of the UNTRANSFORMED box: [TL, TR, BR, BL].
    private var baseCorners: [CGPoint] {
        let b = selectionBoxBase
        return [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
    }
    /// The rotate-handle anchor in the UNTRANSFORMED box: above the top edge centre.
    private var baseRotateHandle: CGPoint {
        let b = selectionBoxBase
        return CGPoint(x: b.midX, y: b.minY - rotateHandleGap)
    }

    /// Corners after the live transform (content coords).
    private var transformedCorners: [CGPoint] { baseCorners.map { $0.applying(selectionTransform) } }
    private var transformedRotateHandle: CGPoint { baseRotateHandle.applying(selectionTransform) }
    private var transformedCenter: CGPoint {
        CGPoint(x: selectionBoxBase.midX, y: selectionBoxBase.midY).applying(selectionTransform)
    }

    /// Hit-test the handles first (within handleHitRadius), then the box interior.
    /// Returns the gesture to drive, or nil for "start a new lasso".
    private func selectionGesture(at p: CGPoint) -> SelectionGesture? {
        let base = selectionTransform
        // Rotate handle.
        let rot = transformedRotateHandle
        if hypot(p.x - rot.x, p.y - rot.y) <= handleHitRadius {
            let c = transformedCenter
            return .rotate(center: c, startAngle: atan2(p.y - c.y, p.x - c.x), base: base)
        }
        // Corner handles → uniform scale about the OPPOSITE corner.
        let corners = transformedCorners
        for (i, corner) in corners.enumerated() where hypot(p.x - corner.x, p.y - corner.y) <= handleHitRadius {
            return .scale(fixed: corners[(i + 2) % 4], grabbed: corner, base: base)
        }
        // Inside the (transformed) box → move.
        if pointInQuad(p, corners) {
            return .move(start: p, base: base)
        }
        return nil
    }

    /// New transform for the in-progress gesture given the current finger point.
    /// Each case applies its world-space delta AFTER the gesture's base transform.
    private func transform(for g: SelectionGesture, finger p: CGPoint) -> CGAffineTransform {
        switch g {
        case let .move(start, base):
            let d = CGPoint(x: p.x - start.x, y: p.y - start.y)
            return base.concatenating(CGAffineTransform(translationX: d.x, y: d.y))
        case let .scale(fixed, grabbed, base):
            // Uniform scale about the fixed (opposite) corner. Project the finger onto
            // the diagonal so off-axis motion stays stable.
            let gx = grabbed.x - fixed.x, gy = grabbed.y - fixed.y
            let denom = gx * gx + gy * gy
            guard denom > 0.0001 else { return base }
            let fx = p.x - fixed.x, fy = p.y - fixed.y
            let k = max(0.1, (fx * gx + fy * gy) / denom)   // clamp so it can't collapse/flip
            let scaleAboutFixed = CGAffineTransform(translationX: fixed.x, y: fixed.y)
                .scaledBy(x: k, y: k)
                .translatedBy(x: -fixed.x, y: -fixed.y)
            return base.concatenating(scaleAboutFixed)
        case let .rotate(center, startAngle, base):
            let now = atan2(p.y - center.y, p.x - center.x)
            let dAngle = now - startAngle
            let rotateAboutCenter = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: dAngle)
                .translatedBy(x: -center.x, y: -center.y)
            return base.concatenating(rotateAboutCenter)
        }
    }

    /// Is `p` inside the (possibly rotated) quad [TL, TR, BR, BL]? Winding test.
    private func pointInQuad(_ p: CGPoint, _ q: [CGPoint]) -> Bool {
        guard q.count == 4 else { return false }
        var sign = 0
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if cross > 0 { if sign < 0 { return false }; sign = 1 }
            else if cross < 0 { if sign > 0 { return false }; sign = -1 }
        }
        return true
    }

    private func updateLassoLayer() {
        let path = CGMutablePath()
        if let f = lassoPoints.first {
            path.move(to: f)
            for p in lassoPoints.dropFirst() { path.addLine(to: p) }
            path.closeSubpath()
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        lassoLayer.transform = CATransform3DIdentity
        lassoLayer.path = path
        CATransaction.commit()
    }

    /// Close the loop, lift the strokes whose majority of samples fall inside it onto
    /// the floating layer, and box them — the tiles re-render without them.
    private func finishLasso() {
        let poly = lassoPoints
        lassoPoints = []
        guard poly.count > 2 else { lassoLayer.path = nil; return }
        var selected: [Stroke] = [], remaining: [Stroke] = []
        for s in strokes {
            if Self.strokeMostlyInside(s, polygon: poly) { selected.append(s) } else { remaining.append(s) }
        }
        guard !selected.isEmpty else { lassoLayer.path = nil; return }

        pushUndo()                                   // captures the ORIGINAL positions (transform bakes without re-pushing)
        strokes = remaining
        selectionStrokes = selected
        selectionBBox = selected.reduce(CGRect.null) { $0.union($1.bbox) }
        selectionTransform = .identity

        // Float the selection on a bbox-sized layer (small backing), strokes in LOCAL
        // coords (offset by -origin), display-coloured for the current appearance.
        let frame = selectionBBox.insetBy(dx: -2, dy: -2)
        let origin = frame.origin
        selectionLayer.frame = frame
        selectionLayer.strokes = selected.map { s in
            Stroke(color: Self.displayColor(s.color, dark: displayDark),
                   samples: s.samples.map { InkSample(location: CGPoint(x: $0.location.x - origin.x, y: $0.location.y - origin.y), width: $0.width) })
        }
        selectionLayer.isHidden = false
        selectionLayer.setNeedsDisplay()
        // Dashed box around the selection (in content coords; follows the transform).
        lassoLayer.path = CGPath(roundedRect: selectionBoxBase, cornerWidth: 8, cornerHeight: 8, transform: nil)
        handleLayer.isHidden = false
        applySelectionTransform()
        invalidate()                                  // tiles drop the lifted strokes
        onChange?()
    }

    /// The selection layer's `transform` for content-space affine `T`. The layer's
    /// anchor is (0,0) and its frame sits at the bbox origin, so CA evaluates
    /// `super = origin + L·(c − origin)`; we want `super = T(c)`, hence
    /// `L = translate(origin) · T · translate(−origin)` (about the frame origin).
    private func selectionLayerTransform(for T: CGAffineTransform) -> CATransform3D {
        let o = selectionLayer.frame.origin
        let L = CGAffineTransform(translationX: o.x, y: o.y)
            .concatenating(T)
            .concatenating(CGAffineTransform(translationX: -o.x, y: -o.y))
        return CATransform3DMakeAffineTransform(L)
    }

    /// Apply the live `selectionTransform` to the floating ink + the dashed box, and
    /// redraw the corner/rotate handles at their transformed positions.
    private func applySelectionTransform() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        selectionLayer.transform = selectionLayerTransform(for: selectionTransform)
        // lassoLayer has anchor (0,0) + a full-bounds frame (origin 0) → its transform
        // is the content-space affine directly.
        lassoLayer.transform = CATransform3DMakeAffineTransform(selectionTransform)
        handleLayer.path = handlesPath()
        let accent = Self.displayColor(.systemBlue, dark: displayDark)
        handleLayer.fillColor = accent.cgColor
        handleLayer.strokeColor = (displayDark ? UIColor(white: 0.12, alpha: 1) : UIColor.white).cgColor
        CATransaction.commit()
    }

    /// Filled dots for the 4 corner handles + the rotate handle (drawn in content coords
    /// at the already-transformed positions; the handle layer itself is untransformed).
    private func handlesPath() -> CGPath {
        let path = CGMutablePath()
        func dot(_ c: CGPoint, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        for c in transformedCorners { dot(c, handleDotRadius) }
        dot(transformedRotateHandle, handleDotRadius)
        return path
    }

    /// Bake the floating selection back into the model at its moved position. The
    /// floating layer stays visible (at its offset) for a beat so the moved ink doesn't
    /// flash out in the gap before CATiledLayer re-renders (no completion callback).
    private func commitSelection() {
        guard !selectionStrokes.isEmpty else { return }
        let T = selectionTransform
        let widthScale = sqrt(abs(T.a * T.d - T.b * T.c))   // uniform scale factor → stroke width
        for s in selectionStrokes {
            strokes.append(Stroke(color: s.color,
                                  samples: s.samples.map {
                                      InkSample(location: $0.location.applying(T), width: $0.width * widthScale)
                                  }))
        }
        // Clear the model-side selection now, but keep the floating LAYER showing.
        selectionStrokes = []
        lassoPoints = []
        selectionGesture = nil
        selectionBBox = .null
        lassoLayer.path = nil
        invalidate()
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.selectionStrokes.isEmpty else { return }   // a new selection took over
            self.selectionTransform = .identity
            self.selectionLayer.strokes = []
            self.selectionLayer.isHidden = true
            self.handleLayer.isHidden = true
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.selectionLayer.transform = CATransform3DIdentity
            self.lassoLayer.transform = CATransform3DIdentity
            self.handleLayer.path = nil
            CATransaction.commit()
        }
    }

    /// Drop the floating selection WITHOUT baking (used by undo/redo/clear, which
    /// restore the model directly).
    private func discardSelection() {
        guard !selectionStrokes.isEmpty || !lassoPoints.isEmpty else { return }
        clearSelectionState()
    }

    private func clearSelectionState() {
        selectionStrokes = []
        lassoPoints = []
        selectionGesture = nil
        selectionTransform = .identity
        selectionBBox = .null
        selectionLayer.strokes = []
        selectionLayer.isHidden = true
        handleLayer.isHidden = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        selectionLayer.transform = CATransform3DIdentity
        lassoLayer.transform = CATransform3DIdentity
        handleLayer.path = nil
        lassoLayer.path = nil
        CATransaction.commit()
    }

    private static func strokeMostlyInside(_ s: Stroke, polygon: [CGPoint]) -> Bool {
        guard !s.samples.isEmpty else { return false }
        var inside = 0
        for sm in s.samples where pointInPolygon(sm.location, polygon) { inside += 1 }
        return Double(inside) / Double(s.samples.count) >= 0.5
    }

    private static func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        guard poly.count > 2 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
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
        discardSelection()      // a floating selection's original is what the snapshot holds
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(strokes)
        strokes = prev
        afterHistoryChange()
    }
    func redo() {
        discardSelection()
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
        discardSelection()
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

    // MARK: Editor-config API (the real editor drives the same view through these)

    /// Replace the model with `newStrokes` (e.g. when opening a page). Clears history
    /// and re-renders, but does NOT fire `onChange` — loading must not trigger a save.
    func loadStrokes(_ newStrokes: [VectorInk.Stroke]) {
        discardSelection()
        strokes = newStrokes
        current = []
        liveLayer.path = nil
        clearBridge()
        undoStack.removeAll()
        redoStack.removeAll()
        invalidate()            // re-render; scheduleSave() no-ops when persistsToDisk == false
    }

    /// The current committed model (canonical colours) — for the host to persist.
    func currentStrokes() -> [VectorInk.Stroke] { strokes }

    /// Append strokes (e.g. AI ink insertion): undoable, re-rendered, and `onChange`
    /// fires so the host saves.
    func insert(_ newStrokes: [VectorInk.Stroke]) {
        guard !newStrokes.isEmpty else { return }
        pushUndo()
        strokes.append(contentsOf: newStrokes)
        clearBridge()
        invalidate()
        onChange?()
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

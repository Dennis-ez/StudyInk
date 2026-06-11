import SwiftUI
import PencilKit

/// The document engine: one vertical UIScrollView containing every page of the
/// note, stitched with small gaps — continuous scrolling across page
/// boundaries, Notability-style. Pages stay separate entities: the page under
/// the viewport center hosts the single live PKCanvasView; all other pages
/// show cached full renders. Centering is done the UIKit-native way in
/// layoutSubviews, so the document is always centered at any zoom.
final class DocumentScrollView: UIScrollView, UIScrollViewDelegate, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    private let controller: CanvasController
    private let documentView = UIView()
    private var containers: [PageContainerView] = []
    private var pageFrames: [CGRect] = []   // document space (zoom 1)
    private var pageSizes: [CGSize] = []
    private var layoutSignature = ""
    private let pageGap: CGFloat = 0

    let canvas = PKCanvasView()
    private var activeIndex = 0
    private var isProgrammaticChange = false
    private var saveWorkItem: DispatchWorkItem?
    private var didSetInitialZoom = false
    /// Cached-render resolution multiplier, raised when zoomed in.
    private var imageRenderScale: CGFloat = 1
    private var rasterWorkItem: DispatchWorkItem?
    private var shapeWorkItem: DispatchWorkItem?
    private var lastStrokeCount = 0
    private var lastPublishedOrigins: [CGPoint] = []
    private var keyboardObservers: [NSObjectProtocol] = []
    private weak var holdRecognizer: UILongPressGestureRecognizer?
    private let addPageButton = UIButton(type: .system)

    init(controller: CanvasController) {
        self.controller = controller
        super.init(frame: .zero)

        delegate = self
        // The pencil belongs to ink (draw/lasso/erase) — never to scrolling.
        // Without this, the scroll pan races PencilKit's gestures and lasso
        // strokes intermittently drag the page instead of selecting.
        panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        minimumZoomScale = 0.4
        maximumZoomScale = 5
        bouncesZoom = true
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        backgroundColor = UIColor(named: "deskBackground")

        addSubview(documentView)

        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        controller.attach(canvas)
        controller.engine = self

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        addInteraction(pencilInteraction)

        // Apple-Notes-style: pause mid-stroke and the shape snaps while the
        // pencil is still touching the page.
        let holdSnap = StationaryStrokeRecognizer(target: nil, action: nil)
        holdSnap.cancelsTouchesInView = false
        holdSnap.delegate = self
        holdSnap.onHold = { [weak self] points in
            self?.handleHoldSnap(rawPoints: points)
        }
        canvas.addGestureRecognizer(holdSnap)

        // Finger-tap a committed shape to re-select it for move/rotate/reshape.
        let shapeTap = UITapGestureRecognizer(target: self, action: #selector(canvasTapped(_:)))
        shapeTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        shapeTap.cancelsTouchesInView = false
        shapeTap.delegate = self
        canvas.addGestureRecognizer(shapeTap)

        // Standard iPad editing gestures: two-finger tap undoes, three redoes.
        let undoTap = UITapGestureRecognizer(target: self, action: #selector(multiFingerUndo(_:)))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        undoTap.cancelsTouchesInView = false
        undoTap.delegate = self
        canvas.addGestureRecognizer(undoTap)

        let redoTap = UITapGestureRecognizer(target: self, action: #selector(multiFingerRedo(_:)))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        redoTap.cancelsTouchesInView = false
        redoTap.delegate = self
        canvas.addGestureRecognizer(redoTap)
        undoTap.require(toFail: redoTap)

        // Eraser cursor: ride along with the system drawing gesture so the
        // circle tracks exactly where erasing happens, sized like the eraser.
        canvas.drawingGestureRecognizer.addTarget(self, action: #selector(drawingGestureMoved(_:)))
        eraserCursor.isUserInteractionEnabled = false
        eraserCursor.isHidden = true
        eraserCursor.layer.borderWidth = 1.5
        eraserCursor.backgroundColor = UIColor.systemGray.withAlphaComponent(0.12)
        canvas.addSubview(eraserCursor)

        // Circle & Ask trigger: hold the Pencil still for ~1s.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(pencilHeld(_:)))
        hold.minimumPressDuration = 1.0
        hold.allowableMovement = 8
        hold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hold.delegate = self
        addGestureRecognizer(hold)
        holdRecognizer = hold

        var addConfig = UIButton.Configuration.gray()
        addConfig.image = UIImage(systemName: "plus")
        addConfig.title = NSLocalizedString("page.add", comment: "")
        addConfig.imagePadding = 6
        addConfig.cornerStyle = .capsule
        addPageButton.configuration = addConfig
        addPageButton.addAction(UIAction { [weak self] _ in self?.controller.onAddPage?() }, for: .touchUpInside)
        documentView.addSubview(addPageButton)

        observeKeyboard()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Page layout

    /// (Re)builds the page stack when the page list/template/sizes change.
    func apply(pageSizes sizes: [CGSize], signature: String) {
        guard signature != layoutSignature else { return }
        // Never tear down with unsaved ink on the live canvas — but only when
        // the page under the canvas is still the same one. Saves resolve by
        // index, so flushing across a reorder/insert/delete would stamp this
        // canvas's ink onto whatever page just moved into our slot (ink
        // duplication on one page, loss on the other). Page mutations commit
        // up front instead (see PageNavigatorStrip / commitPendingInk).
        abortStrokeEditIfNeeded()
        let samePageAtActiveIndex = pageID(at: activeIndex, in: layoutSignature) == pageID(at: activeIndex, in: signature)
        if !containers.isEmpty, samePageAtActiveIndex { flushPendingSave() }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        layoutSignature = signature
        pageSizes = sizes

        let restoreZoom = didSetInitialZoom ? zoomScale : 1
        setZoomScale(1, animated: false)

        containers.forEach { $0.removeFromSuperview() }
        containers = []
        pageFrames = []

        let docWidth = sizes.map(\.width).max() ?? 800
        var y: CGFloat = pageGap
        for (index, size) in sizes.enumerated() {
            let frame = CGRect(x: (docWidth - size.width) / 2, y: y, width: size.width, height: size.height)
            pageFrames.append(frame)
            let container = PageContainerView(pageIndex: index)
            container.frame = frame
            container.snapshot = controller.snapshotProvider?(index)
            documentView.addSubview(container)
            containers.append(container)
            y += size.height + pageGap
        }

        addPageButton.sizeToFit()
        addPageButton.frame.origin = CGPoint(x: (docWidth - addPageButton.frame.width) / 2, y: y + 6)
        let docHeight = y + addPageButton.frame.height + 48

        documentView.frame = CGRect(x: 0, y: 0, width: docWidth, height: docHeight)
        contentSize = documentView.frame.size
        setZoomScale(restoreZoom, animated: false)

        activeIndex = min(activeIndex, max(0, sizes.count - 1))
        mountCanvas(on: activeIndex)
        refreshAllInactiveImages()
        setNeedsLayout()
        publishGeometry()
    }

    /// The editor wires its content providers in onAppear, which can land
    /// AFTER makeUIView built the engine — leaving pages snapshot-less (gray)
    /// and the live canvas empty. Re-pull anything missing on each update.
    func ensureContent() {
        guard controller.snapshotProvider != nil else { return }
        for (index, container) in containers.enumerated() where container.snapshot == nil {
            container.snapshot = controller.snapshotProvider?(index)
            container.setNeedsDisplay()
            if index != activeIndex {
                container.imageView.isHidden = false
                renderImage(for: index)
            }
        }
        if canvas.drawing.strokes.isEmpty,
           let drawing = controller.drawingProvider?(activeIndex),
           !drawing.strokes.isEmpty {
            isProgrammaticChange = true
            canvas.drawing = drawing
            isProgrammaticChange = false
            lastStrokeCount = drawing.strokes.count
        }
    }

    /// Re-render one page's cached image + template (after template/page edits).
    func refreshPage(_ index: Int) {
        guard containers.indices.contains(index) else { return }
        containers[index].snapshot = controller.snapshotProvider?(index)
        containers[index].setNeedsDisplay()
        if index != activeIndex { renderImage(for: index) }
    }

    // MARK: - Centering (the UIKit-native way)

    override func layoutSubviews() {
        super.layoutSubviews()
        applyInitialZoomIfNeeded()
        centerDocument()
        publishGeometry()
    }

    private func centerDocument() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        if documentView.frame.origin != CGPoint(x: dx, y: dy) {
            documentView.frame.origin = CGPoint(x: dx, y: dy)
        }
    }

    private func applyInitialZoomIfNeeded() {
        guard !didSetInitialZoom, bounds.width > 0, documentView.frame.width > 0 else { return }
        didSetInitialZoom = true
        let fit = bounds.width / (documentView.frame.width / zoomScale)
        setZoomScale(min(max(fit, minimumZoomScale), 1.5), animated: false)
        contentOffset = CGPoint(x: max(0, (contentSize.width - bounds.width) / 2), y: 0)
    }

    // MARK: - Active page management

    private func mountCanvas(on index: Int) {
        guard containers.indices.contains(index) else { return }
        activeIndex = index
        let container = containers[index]
        canvas.frame = CGRect(origin: .zero, size: pageSizes[index])
        container.addSubview(canvas)
        isProgrammaticChange = true
        canvas.drawing = controller.drawingProvider?(index) ?? PKDrawing()
        isProgrammaticChange = false
        // PencilKit renders the swapped-in drawing asynchronously; the canvas
        // would briefly show the PREVIOUS page's ink. Hide the live canvas and
        // show this page's cached render until PencilKit has caught up.
        container.imageView.isHidden = false
        canvas.alpha = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self, weak container] in
            guard let self, self.activeIndex == index else { return }
            self.canvas.alpha = 1
            container?.imageView.isHidden = true
        }
        // The undo stack is per-canvas, not per-page: undoing after a page
        // switch would resurrect the previous page's ink on this one.
        canvas.undoManager?.removeAllActions()
        shapeWorkItem?.cancel()
        lastStrokeCount = canvas.drawing.strokes.count
        DispatchQueue.main.async { [controller] in controller.refreshUndoState() }
    }

    private func activatePage(_ index: Int) {
        guard index != activeIndex, containers.indices.contains(index) else { return }
        abortStrokeEditIfNeeded()
        flushPendingSave()
        let oldIndex = activeIndex
        if containers.indices.contains(oldIndex) {
            // Reveal the old page only once its fresh render (with the just-
            // saved ink) is ready — never a stale cache.
            renderImage(for: oldIndex, revealWhenReady: true)
        }
        mountCanvas(on: index)
    }

    private func flushPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        controller.onDrawingChanged?(activeIndex, canvas.drawing)
    }

    /// Saves are debounced and keyed by page *index* — reordering, duplicating,
    /// or deleting pages while one is pending would write the live ink onto
    /// whatever page ends up at that index. Callers mutating the page list must
    /// commit first.
    func commitPendingInk() {
        flushPendingSave()
    }

    /// First component of a page's entry in the layout signature is its UUID
    /// (see NoteEditorView.layoutSignature).
    private func pageID(at index: Int, in signature: String) -> Substring? {
        let entries = signature.split(separator: ",")
        guard entries.indices.contains(index) else { return nil }
        return entries[index].split(separator: "|").first
    }

    private func renderImage(for index: Int, revealWhenReady: Bool = false) {
        guard containers.indices.contains(index),
              let snapshot = controller.snapshotProvider?(index) else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        let container = containers[index]
        let renderScale = imageRenderScale
        Task.detached(priority: .utility) {
            let image = PageRenderer.render(snapshot, darkMode: dark, scale: renderScale)
            await MainActor.run { [weak self] in
                guard container.pageIndex == index else { return }
                container.imageView.image = image
                if revealWhenReady, self?.activeIndex != index {
                    container.imageView.isHidden = false
                }
            }
        }
    }

    private func refreshAllInactiveImages() {
        for index in containers.indices where index != activeIndex {
            containers[index].imageView.isHidden = false
            renderImage(for: index)
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        containers.forEach { $0.setNeedsDisplay() }
        refreshAllInactiveImages()
    }

    // MARK: - Scrolling & paging

    func scrollToPage(_ index: Int, animated: Bool) {
        guard pageFrames.indices.contains(index) else { return }
        let y = documentView.frame.origin.y + (pageFrames[index].minY - pageGap) * zoomScale
        let maxY = max(-adjustedContentInset.top, contentSize.height - bounds.height)
        setContentOffset(CGPoint(x: contentOffset.x, y: min(max(y, 0), maxY)), animated: animated)
        activatePage(index)
        if controller.currentPageIndex != index {
            DispatchQueue.main.async { [controller] in controller.currentPageIndex = index }
        }
    }

    private func updateCurrentIndex() {
        guard !pageFrames.isEmpty, zoomScale > 0 else { return }
        // Don't steal the live canvas while the pen is on the page.
        let drawingState = canvas.drawingGestureRecognizer.state
        guard drawingState != .began, drawingState != .changed else { return }
        let centerY = (contentOffset.y + bounds.height / 2 - documentView.frame.origin.y) / zoomScale
        var nearest = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, frame) in pageFrames.enumerated() {
            if frame.minY...frame.maxY ~= centerY {
                nearest = index
                bestDistance = 0
                break
            }
            let distance = min(abs(frame.minY - centerY), abs(frame.maxY - centerY))
            if distance < bestDistance {
                bestDistance = distance
                nearest = index
            }
        }
        if nearest != activeIndex {
            activatePage(nearest)
            DispatchQueue.main.async { [controller] in
                if controller.currentPageIndex != nearest {
                    controller.currentPageIndex = nearest
                }
            }
        }
    }

    private func publishGeometry() {
        let zoom = zoomScale
        let origin = documentView.frame.origin
        let offset = contentOffset
        let origins = pageFrames.map { frame in
            CGPoint(
                x: origin.x + frame.origin.x * zoom - offset.x,
                y: origin.y + frame.origin.y * zoom - offset.y
            )
        }
        guard origins != lastPublishedOrigins || zoom != controller.zoomScale else { return }
        lastPublishedOrigins = origins
        DispatchQueue.main.async { [weak controller] in
            guard let controller else { return }
            if controller.zoomScale != zoom { controller.zoomScale = zoom }
            if controller.pageScreenOrigins != origins { controller.pageScreenOrigins = origins }
        }
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { documentView }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        publishGeometry()
        updateCurrentIndex()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerDocument()
        publishGeometry()
        // Programmatic/snap zooms never call didEndZooming — debounce a raster
        // pass after the last zoom tick so sharpness always lands.
        rasterWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateRasterScale() }
        rasterWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Releasing a pinch near fit-width snaps the page to exactly fill the screen.
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard documentView.frame.width > 0, zoomScale > 0 else { return }
        let fit = bounds.width / (documentView.frame.width / zoomScale)
        if fit >= minimumZoomScale, fit <= maximumZoomScale,
           abs(zoomScale - fit) / fit < 0.12, zoomScale != fit {
            setZoomScale(fit, animated: true)
        }
        updateRasterScale()
    }

    /// The document zooms by transform, which magnifies 1x rasterizations into
    /// blur. After a pinch settles, re-rasterize templates, cached renders,
    /// and the live canvas layer tree at the effective zoom (capped at 3x).
    private func updateRasterScale() {
        // Sharpen as far as Metal allows: a layer's backing store must stay
        // under the ~8192px texture limit or it silently renders NOTHING
        // (which presented as "no ink at all"). Cap the raster zoom so
        // pageMaxDimension × zoom × screenScale stays inside the limit.
        let maxPageDimension = pageSizes.map { max($0.width, $0.height) }.max() ?? 800
        let textureCap = 8192 / (maxPageDimension * UIScreen.main.scale)
        let effectiveZoom = min(max(zoomScale, 1), min(maximumZoomScale, textureCap))
        let raster = effectiveZoom * UIScreen.main.scale
        for container in containers {
            container.contentScaleFactor = raster
            container.layer.contentsScale = raster
            container.imageView.layer.contentsScale = raster
            container.setNeedsDisplay()
        }
        // PencilKit renders ink in nested internal views — the scale bump must
        // reach the whole tree or zoomed ink stays soft.
        applyRasterScale(raster, to: canvas)
        // Cached full-page bitmaps of inactive pages are NOT tiled — cap their
        // render scale to keep memory sane (zoomed that far, you're looking at
        // the live page anyway).
        let imageZoom = min(effectiveZoom, 4)
        if abs(imageZoom - imageRenderScale) > 0.5 {
            imageRenderScale = imageZoom
            for index in containers.indices where index != activeIndex {
                renderImage(for: index)
            }
        }
    }

    private func applyRasterScale(_ scale: CGFloat, to view: UIView) {
        view.contentScaleFactor = scale
        view.layer.contentsScale = scale
        for subview in view.subviews {
            applyRasterScale(scale, to: subview)
        }
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isProgrammaticChange else { return }
        let drawing = canvasView.drawing
        let index = activeIndex
        DispatchQueue.main.async { [controller] in
            controller.refreshUndoState()
            if let stroke = drawing.strokes.last {
                controller.onStroke?(index, stroke)
            }
        }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [controller] in
            controller.onDrawingChanged?(index, drawing)
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)

        scheduleShapeRecognition(canvasView)

        // Momentary eraser: once the erase gesture has fully ended, hop back
        // to the tool that was active before the Pencil double-tap.
        if controller.toolState.kind == .eraserPixel || controller.toolState.kind == .eraserObject {
            let state = canvasView.drawingGestureRecognizer.state
            if state != .began && state != .changed {
                DispatchQueue.main.async { [controller] in
                    controller.eraseGestureFinished()
                }
            }
        }
    }

    /// Auto-shapes: shortly after a stroke ends (and no new stroke begins),
    /// try to recognize it as a line/circle/polygon and snap it clean.
    private func scheduleShapeRecognition(_ canvas: PKCanvasView) {
        let count = canvas.drawing.strokes.count
        defer { lastStrokeCount = count }
        shapeWorkItem?.cancel()
        guard controller.autoShapes,
              controller.toolState.kind.isInking,
              count > lastStrokeCount,
              let last = canvas.drawing.strokes.last else { return }

        let work = DispatchWorkItem { [weak self, weak canvas] in
            guard let self, let canvas, canvas.drawing.strokes.count == count else { return }
            guard var shape = ShapeRecognizer.recognize(last) else { return }
            // Align the clean shape with the page's lines/grid.
            if self.controller.snapToGrid,
               let snapshot = self.controller.snapshotProvider?(self.activeIndex),
               let metrics = SnapMetrics.metrics(for: snapshot.template, spacing: snapshot.templateSpacing) {
                shape = ShapeRecognizer.snapped(shape, to: metrics)
            }
            let old = canvas.drawing
            var replaced = old
            replaced.strokes[count - 1] = ShapeRecognizer.idealStroke(for: shape, like: last)
            canvas.undoManager?.registerUndo(withTarget: canvas) { target in
                target.drawing = old
            }
            canvas.drawing = replaced
            Haptics.tap()
            self.controller.onShapeCreated?(
                self.activeIndex,
                count - 1,
                shape,
                last.ink,
                Double(self.averageWidth(of: last)),
                self.displayHex(for: last.ink)
            )
        }
        shapeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// Mid-stroke hold detected: recognize from raw touch points, cancel the
    /// in-flight PencilKit stroke, and lay down the clean shape immediately.
    private func handleHoldSnap(rawPoints: [CGPoint]) {
        guard controller.autoShapes, controller.toolState.kind.isInking else { return }
        guard var shape = ShapeRecognizer.recognize(points: rawPoints) else { return }
        if controller.snapToGrid,
           let snapshot = controller.snapshotProvider?(activeIndex),
           let metrics = SnapMetrics.metrics(for: snapshot.template, spacing: snapshot.templateSpacing) {
            shape = ShapeRecognizer.snapped(shape, to: metrics)
        }
        guard let inkingTool = controller.toolState.pkTool(darkMode: controller.isDarkMode) as? PKInkingTool else { return }

        let countBeforeCancel = canvas.drawing.strokes.count
        shapeWorkItem?.cancel()
        // Toggling the drawing recognizer cancels the live stroke.
        canvas.drawingGestureRecognizer.isEnabled = false
        canvas.drawingGestureRecognizer.isEnabled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let old = self.canvas.drawing
            var replaced = old
            if replaced.strokes.count > countBeforeCancel, let partial = old.strokes.last {
                // Cancellation still committed a partial stroke — swap it out,
                // copying its real (pressure-driven) point size so the shape
                // matches the user's handwriting weight.
                replaced.strokes[replaced.strokes.count - 1] = ShapeRecognizer.idealStroke(for: shape, like: partial)
            } else {
                // No partial stroke to copy from: the tool's nominal width
                // renders heavier than pressure-modulated handwriting, so
                // take it down to handwriting weight.
                replaced.strokes.append(ShapeRecognizer.idealStroke(
                    for: shape, ink: inkingTool.ink, width: CGFloat(controller.toolState.width) * 0.7
                ))
            }
            self.canvas.undoManager?.registerUndo(withTarget: self.canvas) { target in
                target.drawing = old
            }
            self.isProgrammaticChange = true
            self.canvas.drawing = replaced
            self.isProgrammaticChange = false
            self.lastStrokeCount = replaced.strokes.count
            self.controller.onDrawingChanged?(self.activeIndex, replaced)
            Haptics.tap()
            self.controller.onShapeCreated?(
                self.activeIndex,
                replaced.strokes.count - 1,
                shape,
                inkingTool.ink,
                self.controller.toolState.width,
                self.controller.toolState.colorHex
            )
        }
    }

    /// Circle the size of the eraser stroke, following the touch while erasing.
    private let eraserCursor = UIView()

    @objc private func drawingGestureMoved(_ recognizer: UIGestureRecognizer) {
        guard controller.toolState.kind == .eraserPixel || controller.toolState.kind == .eraserObject else {
            eraserCursor.isHidden = true
            return
        }
        switch recognizer.state {
        case .began, .changed:
            // Pixel eraser uses its real width; the object eraser gets a small
            // fixed reticle (it erases whole strokes, not an area).
            let diameter = controller.toolState.kind == .eraserPixel ? max(controller.toolState.width, 6) : 14
            let location = recognizer.location(in: canvas)
            eraserCursor.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            eraserCursor.layer.cornerRadius = CGFloat(diameter) / 2
            eraserCursor.layer.borderColor = UIColor.systemGray.cgColor
            eraserCursor.center = location
            canvas.bringSubviewToFront(eraserCursor)
            eraserCursor.isHidden = false
        default:
            eraserCursor.isHidden = true
        }
    }

    @objc private func multiFingerUndo(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        Haptics.tap()
        controller.undo()
    }

    @objc private func multiFingerRedo(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        Haptics.tap()
        controller.redo()
    }

    /// Finger tap: if it lands on a stroke that reads as a clean shape,
    /// reopen it for editing (move / rotate / reshape via nodes).
    @objc private func canvasTapped(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: canvas)
        let drawing = canvas.drawing
        let tolerance: CGFloat = max(14, 10 / max(zoomScale, 0.1))

        for (index, stroke) in drawing.strokes.enumerated().reversed() {
            guard stroke.renderBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(location) else { continue }
            guard strokeDistance(from: stroke, to: location) <= tolerance else { continue }
            guard let shape = ShapeRecognizer.recognize(stroke) else { return }
            Haptics.selection()
            controller.onShapeTapped?(
                activeIndex,
                index,
                shape,
                stroke.ink,
                Double(averageWidth(of: stroke)),
                displayHex(for: stroke.ink)
            )
            return
        }
    }

    private func strokeDistance(from stroke: PKStroke, to point: CGPoint) -> CGFloat {
        let path = stroke.path
        let step = max(1, path.count / 80)
        var best = CGFloat.greatestFiniteMagnitude
        for i in stride(from: 0, to: path.count, by: step) {
            let p = path[i].location.applying(stroke.transform)
            best = min(best, hypot(p.x - point.x, p.y - point.y))
        }
        return best
    }

    private func averageWidth(of stroke: PKStroke) -> CGFloat {
        let path = stroke.path
        guard path.count > 0 else { return 4 }
        let step = max(1, path.count / 16)
        var total: CGFloat = 0
        var count: CGFloat = 0
        for i in stride(from: 0, to: path.count, by: step) {
            total += path[i].size.width
            count += 1
        }
        return total / max(count, 1)
    }

    /// PencilKit stores light-variant colors; report what's actually on screen.
    private func displayHex(for ink: PKInk) -> String {
        var color = ink.color
        if traitCollection.userInterfaceStyle == .dark {
            color = PKInkingTool.convertColor(color, from: .light, to: .dark)
        }
        return color.hexString
    }

    // MARK: - Node editing of created shapes

    private var editSession: (index: Int, originalDrawing: PKDrawing)?

    /// Starts a shape-edit session by LIFTING the stroke out of the ink: the
    /// overlay's instant preview is the only visible copy while dragging, so
    /// there's no async-PencilKit lag ghosting behind the nodes.
    func beginStrokeEdit(at index: Int) {
        guard editSession == nil, canvas.drawing.strokes.indices.contains(index) else { return }
        let original = canvas.drawing
        editSession = (index, original)
        var lifted = original
        lifted.strokes.remove(at: index)
        isProgrammaticChange = true
        canvas.drawing = lifted
        isProgrammaticChange = false
    }

    /// A shape edit lifts its stroke OUT of the ink — if the page is about to
    /// be saved/switched/rebuilt mid-session, put the original stroke back
    /// first or the lifted state gets persisted and the shape "disappears".
    private func abortStrokeEditIfNeeded() {
        guard let session = editSession else { return }
        editSession = nil
        isProgrammaticChange = true
        canvas.drawing = session.originalDrawing
        isProgrammaticChange = false
        lastStrokeCount = canvas.drawing.strokes.count
    }

    /// Commits the edited shape back into the ink — one drawing write, one undo.
    func endStrokeEdit(with stroke: PKStroke) {
        guard let session = editSession else { return }
        editSession = nil
        var drawing = canvas.drawing
        drawing.strokes.insert(stroke, at: min(session.index, drawing.strokes.count))
        canvas.undoManager?.registerUndo(withTarget: canvas) { target in
            target.drawing = session.originalDrawing
        }
        isProgrammaticChange = true
        canvas.drawing = drawing
        isProgrammaticChange = false
        lastStrokeCount = drawing.strokes.count
        controller.onDrawingChanged?(activeIndex, drawing)
        DispatchQueue.main.async { [controller] in controller.refreshUndoState() }
    }

    // MARK: - Pencil interactions

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard UIPencilInteraction.preferredTapAction == .switchEraser else { return }
        controller.toggleEraser()
    }

    @objc private func pencilHeld(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        controller.onPencilHold?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: - Scribble mitigation

    /// While any keyboard is up, suspend the drawing + pencil-hold recognizers:
    /// iPadOS's handwriting daemon otherwise fights the canvas for the text
    /// input session and freezes the app for ~3s on focus.
    private func observeKeyboard() {
        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                self?.canvas.drawingGestureRecognizer.isEnabled = false
                self?.holdRecognizer?.isEnabled = false
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                self?.canvas.drawingGestureRecognizer.isEnabled = true
                self?.holdRecognizer?.isEnabled = true
            },
        ]
    }
}

/// One sheet of paper in the document: draws its own background + template and
/// shows a cached full render whenever it isn't hosting the live canvas.
final class PageContainerView: UIView {
    let pageIndex: Int
    let imageView = UIImageView()
    var snapshot: PageRenderer.Snapshot? {
        didSet { setNeedsDisplay() }
    }

    init(pageIndex: Int) {
        self.pageIndex = pageIndex
        super.init(frame: .zero)
        contentMode = .redraw
        isOpaque = false
        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }

    override func draw(_ rect: CGRect) {
        guard let snapshot, let cg = UIGraphicsGetCurrentContext() else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        PageRenderer.drawBackground(snapshot, in: cg, darkMode: dark)
        // Hairline seam where stitched pages meet (pages are gapless).
        let seam = (UIColor(named: "templateLine") ?? .separator).resolvedColor(with: traitCollection)
        cg.setFillColor(seam.withAlphaComponent(0.8).cgColor)
        cg.fill(CGRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5))
    }
}

/// SwiftUI wrapper for the document engine.
struct NoteCanvasView: UIViewRepresentable {
    @ObservedObject var controller: CanvasController
    let pageSizes: [CGSize]
    let layoutSignature: String
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> DocumentScrollView {
        let engine = DocumentScrollView(controller: controller)
        controller.isDarkMode = colorScheme == .dark
        engine.apply(pageSizes: pageSizes, signature: layoutSignature)
        return engine
    }

    func updateUIView(_ engine: DocumentScrollView, context: Context) {
        if controller.isDarkMode != (colorScheme == .dark) {
            controller.isDarkMode = colorScheme == .dark
        }
        engine.apply(pageSizes: pageSizes, signature: layoutSignature)
        engine.ensureContent()
    }
}


import UIKit.UIGestureRecognizerSubclass

/// Observes an in-progress stroke and fires once the touch has been stationary
/// for ~0.45s (without ever claiming the gesture — PencilKit keeps drawing).
final class StationaryStrokeRecognizer: UIGestureRecognizer {
    var onHold: (([CGPoint]) -> Void)?

    private var samples: [CGPoint] = []
    private var lastMoveAt = Date()
    private var lastLocation = CGPoint.zero
    private var fired = false
    private var timer: Timer?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        samples = [touch.location(in: view)]
        lastLocation = samples[0]
        lastMoveAt = Date()
        fired = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkHold()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: view)
        samples.append(location)
        if hypot(location.x - lastLocation.x, location.y - lastLocation.y) > 2.5 {
            lastLocation = location
            lastMoveAt = Date()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { reset() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { reset() }

    override func reset() {
        timer?.invalidate()
        timer = nil
        samples = []
        fired = false
        state = .failed
    }

    private func checkHold() {
        guard !fired, samples.count >= 12,
              Date().timeIntervalSince(lastMoveAt) > 0.45 else { return }
        // Ignore dots/taps — require some drawn extent before snapping.
        let xs = samples.map(\.x), ys = samples.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              hypot(maxX - minX, maxY - minY) > 40 else { return }
        fired = true
        timer?.invalidate()
        timer = nil
        onHold?(samples)
    }
}

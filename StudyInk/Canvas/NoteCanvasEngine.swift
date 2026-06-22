import SwiftUI
import PencilKit

/// The document engine, Notability-style: the PKCanvasView IS the scroll view
/// (it subclasses UIScrollView), so PencilKit owns scrolling AND zooming. That's
/// the supported way to drive a document-sized canvas — ink renders reliably
/// (PencilKit tracks its own visible rect) and native zoom re-tessellates vector
/// ink sharply at any scale, with no supersampling and no transform-zoom blur.
/// ONE drawing spans every page (so writing works across page boundaries and on
/// a peeking neighbour); page backgrounds ride in `documentView`, the canvas's
/// zooming content view; ink is split back to per-page drawings on save.
final class DocumentScrollView: PKCanvasView, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    private let controller: CanvasController
    /// The zooming content view that holds the page backgrounds. Returned from
    /// viewForZooming so backgrounds scale in lock-step with the native ink zoom.
    private let documentView = UIView()
    private var containers: [PageContainerView] = []
    private var pageFrames: [CGRect] = []   // document space (zoom 1)
    private var pageSizes: [CGSize] = []
    private var layoutSignature = ""
    private let pageGap: CGFloat = 0

    /// `self` IS the canvas now; this alias keeps the (many) `canvas.…` call sites
    /// unchanged after collapsing the old outer-scrollview + inner-canvas split.
    private var canvas: PKCanvasView { self }

    // MARK: System edit-menu suppression (the app has its own paste menu).
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
    override func didMoveToWindow() { super.didMoveToWindow(); stripEditMenuInteractions() }
    override func addInteraction(_ interaction: any UIInteraction) {
        if interaction is UIEditMenuInteraction { return }   // PencilKit's edit menu
        super.addInteraction(interaction)
    }
    private func stripEditMenuInteractions() {
        func strip(_ view: UIView) {
            for i in view.interactions where i is UIEditMenuInteraction { view.removeInteraction(i) }
            view.subviews.forEach(strip)
        }
        strip(self)
    }
    private var activeIndex = 0
    private var isProgrammaticChange = false
    /// True once the active page's real drawing has been loaded into the live
    /// canvas. Stops ensureContent() from re-seeding (and resurrecting erased
    /// strokes) on a re-render after the user has erased the whole page — the
    /// canvas being empty then is intentional, not "not loaded yet".
    private var seededActiveDrawing = false
    /// Appearance the live canvas is currently displaying ink for. iOS 26
    /// renders colors literally, so loaded ink is mapped storage→display and
    /// saved ink display→storage against this. Kept in sync via appearanceChanged().
    private var displayDark = false
    private var saveWorkItem: DispatchWorkItem?
    private var didSetInitialZoom = false
    /// Supersample factor for native-sharp zoom. The live canvas renders at
    /// `inkScale`× and counter-scales to fit. With the UNIFIED canvas (one canvas
    /// spanning the WHOLE document, not a single page) inkScale MUST stay 1:
    /// supersampling a multi-page document blows PencilKit's backing store past
    /// the point where it "silently stops rendering ink entirely" (ink vanishes
    /// the moment a new stroke forces a re-render). The per-page canvas could
    /// afford inkScale=4 because it was bounded to one page; the document-spanning
    /// canvas cannot. Sharp deep-zoom now needs a bounded supersampled WINDOW, a
    /// separate change. The ×1/÷1 scaling at the load/save/AI-insert boundaries
    /// (displayIntoCanvas / canonicalFromCanvas) is a no-op at inkScale=1.
    private let inkScale: CGFloat = 1
    /// Cached-render resolution in PIXELS per point, raised when zoomed in.
    /// Starts at the screen scale so adjacent (inactive) pages are retina-sharp
    /// at default zoom, not a soft 1x bitmap.
    private var imageRenderScale: CGFloat = UIScreen.main.scale
    private var rasterWorkItem: DispatchWorkItem?
    private var shapeWorkItem: DispatchWorkItem?
    private var lastStrokeCount = 0
    /// Per-page stroke signatures from the last split-save, so re-saving only
    /// touches pages whose ink actually changed (no OCR / Core Data churn).
    private var pageSaveSignatures: [String] = []
    private var lastPublishedOrigins: [CGPoint] = []
    private var keyboardObservers: [NSObjectProtocol] = []
    private weak var holdRecognizer: UILongPressGestureRecognizer?
    private let addPageButton = UIButton(type: .system)

    init(controller: CanvasController) {
        self.controller = controller
        super.init(frame: .zero)

        delegate = self
        // Pencil belongs to ink (draw/lasso/erase); fingers scroll. Keep the
        // scroll pan off the pencil so the pen never drags the page.
        panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        // PencilKit drives scrolling AND zooming natively now (it IS the scroll
        // view). Native zoom re-tessellates vector ink, so it stays sharp at any
        // scale — no supersampling, no transform-zoom raster wall.
        minimumZoomScale = 0.4
        maximumZoomScale = 5
        bouncesZoom = true
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        // self is pinned to .light (below), so resolve the desk for the REAL
        // appearance or a dark-mode desk would render light.
        backgroundColor = AppTheme.current.deskUIColor.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: controller.isDarkMode ? .dark : .light))

        // documentView is the canvas's zooming CONTENT view (page backgrounds);
        // returned from viewForZooming so paper/lines scale with the ink.
        addSubview(documentView)

        // Pin the CANVAS (self) to light so PencilKit renders the pre-adapted
        // (InkColorAdapter) display ink colours LITERALLY — on iOS 26 it would
        // otherwise re-darken a near-white pen in dark mode. The page backgrounds
        // must still follow the REAL appearance, so documentView overrides back.
        overrideUserInterfaceStyle = .light
        documentView.overrideUserInterfaceStyle = controller.isDarkMode ? .dark : .light
        controller.inkScale = inkScale
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
        // After the snap, the pen keeps dragging the shape's last node live.
        holdSnap.onAdjust = { [weak self] point in
            self?.adjustLiveShape(to: point)
        }
        holdSnap.onAdjustEnd = { [weak self] in
            self?.endLiveShape()
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

        // UIKit-level dismiss tap: while a SwiftUI drawer/panel is open, the
        // editor arms this to catch the first tap anywhere on the canvas area
        // (SwiftUI tap catchers lose to the canvas's UIKit hit-testing).
        let intercept = UITapGestureRecognizer(target: self, action: #selector(interceptTapFired(_:)))
        intercept.cancelsTouchesInView = true
        intercept.delegate = self
        intercept.isEnabled = false
        addGestureRecognizer(intercept)
        interceptTap = intercept

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
        mountUnifiedCanvas()
        setNeedsLayout()
        publishGeometry()
    }

    /// Y range (document points) the live ink canvas covers: from the top of the
    /// first page to the bottom of the last — NOT the trailing "add page" button,
    /// so that button stays tappable under the transparent canvas.
    private var pagesBottom: CGFloat { pageFrames.last?.maxY ?? 0 }

    /// The editor wires its content providers in onAppear, which can land
    /// AFTER makeUIView built the engine — leaving pages snapshot-less (gray)
    /// and the live canvas empty. Re-pull anything missing on each update.
    func ensureContent() {
        guard controller.snapshotProvider != nil else { return }
        // Page backgrounds (paper/template/PDF) are drawn by each container; the
        // ink imageViews stay hidden — all ink lives in the unified canvas, which
        // spans every page and paints them all.
        for (index, container) in containers.enumerated() where container.snapshot == nil {
            container.snapshot = controller.snapshotProvider?(index)
        }
        // The providers can connect AFTER the first apply() built the (empty)
        // canvas. Once ink is available, merge it in — exactly once.
        if !seededActiveDrawing, controller.drawingProvider != nil {
            loadUnifiedDrawing()
        }
        if containers.indices.contains(activeIndex), containers[activeIndex].snapshot != nil {
            DispatchQueue.main.async { [controller] in controller.markReady() }
        }
    }

    /// Re-render one page's background/template (after template/page edits). Ink
    /// is the live unified canvas, so there's nothing else to refresh.
    func refreshPage(_ index: Int) {
        guard containers.indices.contains(index) else { return }
        containers[index].snapshot = controller.snapshotProvider?(index)
        containers[index].setNeedsDisplay()
    }

    // MARK: - Centering (the UIKit-native way)

    /// Gutter above page 1, below the status bar: clears the floating toolbar
    /// row AND leaves room for the larger two-line note title, plus comfortable
    /// drag space so the page never tucks under the clock or the tools.
    private let topGutter: CGFloat = 112

    override func layoutSubviews() {
        super.layoutSubviews()
        applyInitialZoomIfNeeded()
        centerDocument()
        restorePageIfNeeded()
        publishGeometry()
    }

    /// Native-scroll centering: keep the document under the top gutter and
    /// horizontally — and vertically, when it's shorter than the viewport —
    /// centered via contentInset. documentView itself stays at the content origin
    /// (it's the zooming content view), so it's PencilKit's clean zoom target.
    private func centerDocument() {
        guard contentSize.width > 0 else { return }
        let scaledW = contentSize.width * zoomScale
        let scaledH = contentSize.height * zoomScale
        let side = max(0, (bounds.width - scaledW) / 2)
        let top = safeAreaInsets.top + topGutter
        let extraTop = max(0, (bounds.height - top - scaledH) / 2)
        let inset = UIEdgeInsets(top: top + extraTop, left: side, bottom: 40, right: side)
        if abs(inset.top - contentInset.top) > 0.5 || abs(inset.left - contentInset.left) > 0.5 {
            let wasAtTop = contentOffset.y <= -contentInset.top + 1
            contentInset = inset
            verticalScrollIndicatorInsets.top = top
            if wasAtTop { contentOffset.y = -inset.top }
        }
    }

    private func applyInitialZoomIfNeeded() {
        guard !didSetInitialZoom, bounds.width > 0, contentSize.width > 0 else { return }
        didSetInitialZoom = true
        let fit = bounds.width / contentSize.width
        setZoomScale(min(max(fit, minimumZoomScale), 1.5), animated: false)
        centerDocument()
        // Rest at the top-left of the (now centered) content.
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    private var didRestorePage = false
    /// Scroll to the page the user last left off on — once, after the stack is
    /// laid out. Runs from layoutSubviews so it lands even if the editor sets
    /// the restore index slightly after the first layout pass.
    private func restorePageIfNeeded() {
        guard !didRestorePage, didSetInitialZoom else { return }
        let restore = controller.initialPageIndex
        guard restore > 0, pageFrames.indices.contains(restore) else { return }
        didRestorePage = true
        scrollToPage(restore, animated: false)
    }

    // MARK: - Active page management

    /// One live canvas spans the whole page stack (top of page 0 → bottom of the
    /// last page), so the pen writes anywhere — on a peeking neighbour and across
    /// a page boundary. Page backgrounds stay per-container; ink lives here and
    /// is split back into per-page drawings on save.
    /// Load the merged ink. `self` IS the canvas now, so there's no separate
    /// canvas view to size or mount — the drawing lives in the scroll view's
    /// content (document) coordinates, sharp at any native zoom.
    private func mountUnifiedCanvas() {
        loadUnifiedDrawing()
        undoManager?.removeAllActions()
        shapeWorkItem?.cancel()
        DispatchQueue.main.async { [controller] in controller.refreshUndoState() }
    }

    /// Merge every page's stored (canonical, page-local) ink into the single
    /// drawing, each page offset to its document position and appearance-adapted.
    private func loadUnifiedDrawing() {
        guard controller.drawingProvider != nil else { return }
        var merged = PKDrawing()
        for index in pageFrames.indices {
            guard let pageDrawing = controller.drawingProvider?(index), !pageDrawing.strokes.isEmpty else { continue }
            var moved = pageDrawing
            let origin = pageFrames[index].origin
            if origin != .zero { moved.transform(using: CGAffineTransform(translationX: origin.x, y: origin.y)) }
            merged = merged.appending(moved)
        }
        isProgrammaticChange = true
        canvas.drawing = displayIntoCanvas(merged)
        isProgrammaticChange = false
        seededActiveDrawing = true
        lastStrokeCount = canvas.drawing.strokes.count
        // Seed per-page save signatures from the stored state so the first edit
        // only writes the page that actually changed (no whole-document churn).
        pageSaveSignatures = pageFrames.indices.map {
            saveSignature(controller.drawingProvider?($0) ?? PKDrawing())
        }
        DispatchQueue.main.async { [controller] in controller.markReady() }
    }

    private func flushPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        persistUnified()
    }

    private func scheduleUnifiedSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistUnified() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Split the unified canvas back into per-page drawings (by each stroke's
    /// document-space vertical midpoint) and persist only the pages whose ink
    /// changed. A stroke straddling a boundary is assigned to the page its middle
    /// falls in and keeps its full shape (it overhangs visually — fine, and on
    /// reload it still straddles since it's offset from that page's origin).
    private func persistUnified() {
        guard !pageFrames.isEmpty, seededActiveDrawing else { return }
        let canonicalDoc = canonicalFromCanvas(canvas.drawing)   // document-space, canonical colors
        var perPage: [[PKStroke]] = Array(repeating: [], count: pageFrames.count)
        for stroke in canonicalDoc.strokes {
            perPage[pageIndex(forDocumentY: stroke.renderBounds.midY)].append(stroke)
        }
        if pageSaveSignatures.count != pageFrames.count {
            pageSaveSignatures = Array(repeating: "", count: pageFrames.count)
        }
        for index in pageFrames.indices {
            var pageDrawing = PKDrawing(strokes: perPage[index])
            let origin = pageFrames[index].origin
            if origin != .zero { pageDrawing.transform(using: CGAffineTransform(translationX: -origin.x, y: -origin.y)) }
            let signature = saveSignature(pageDrawing)
            guard signature != pageSaveSignatures[index] else { continue }
            pageSaveSignatures[index] = signature
            controller.onDrawingChanged?(index, pageDrawing)
        }
    }

    /// Cheap change-detector for a page's ink: stroke count + rounded bounds.
    private func saveSignature(_ drawing: PKDrawing) -> String {
        guard !drawing.strokes.isEmpty else { return "0" }
        let b = drawing.bounds
        return "\(drawing.strokes.count):\(Int(b.minX)):\(Int(b.minY)):\(Int(b.width)):\(Int(b.height))"
    }

    /// The page whose vertical band contains a document-space Y (clamped to ends).
    private func pageIndex(forDocumentY y: CGFloat) -> Int {
        for (index, frame) in pageFrames.enumerated() where y < frame.maxY { return index }
        return max(0, pageFrames.count - 1)
    }

    /// Document-space origin of a page — for page-local ↔ document conversions
    /// (AI ink insertion, paste, finger-tap, insert-space).
    func pageDocumentOrigin(_ index: Int) -> CGPoint {
        pageFrames.indices.contains(index) ? pageFrames[index].origin : .zero
    }

    /// Page-local render bounds of a page's current ink (read off the live
    /// canvas), for AI placement that must avoid existing work.
    func pageStrokeBounds(_ index: Int) -> [CGRect] {
        guard pageFrames.indices.contains(index) else { return [] }
        let frame = pageFrames[index]
        let origin = frame.origin
        return canvas.drawing.strokes.compactMap { stroke in
            let r = CGRect(x: stroke.renderBounds.minX / inkScale, y: stroke.renderBounds.minY / inkScale,
                           width: stroke.renderBounds.width / inkScale, height: stroke.renderBounds.height / inkScale)
            guard r.midY >= frame.minY, r.midY < frame.maxY else { return nil }
            return r.offsetBy(dx: -origin.x, dy: -origin.y)
        }
    }

    /// The app appearance flipped while editing. Save under the OLD appearance,
    /// then re-adapt the live canvas ink to the NEW one so nothing vanishes,
    /// and re-render the cached page images.
    func appearanceChanged() {
        let newDark = controller.isDarkMode
        guard newDark != displayDark else { return }
        // Before the page stack is built (initial mount) there's nothing
        // loaded to re-map — just record the appearance so the first load
        // adapts correctly. Flushing here would save the empty canvas over
        // page 0's real ink.
        guard !containers.isEmpty else { displayDark = newDark; return }
        flushPendingSave()                          // persists with old displayDark
        // canvas holds display(old) colors in inkScale space → canonical →
        // display(new) back into inkScale space.
        let canonical = canonicalFromCanvas(canvas.drawing)
        displayDark = newDark
        // Backgrounds follow the real appearance even though the canvas is pinned
        // light for literal ink rendering.
        documentView.overrideUserInterfaceStyle = newDark ? .dark : .light
        backgroundColor = AppTheme.current.deskUIColor.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: newDark ? .dark : .light))
        isProgrammaticChange = true
        canvas.drawing = displayIntoCanvas(canonical)
        isProgrammaticChange = false
        lastStrokeCount = canvas.drawing.strokes.count
        redrawPageBackgrounds()
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

    /// All page backgrounds repaint (paper/template/PDF). There are no cached ink
    /// images any more — ink is the live unified canvas, which spans every page.
    private func redrawPageBackgrounds() {
        containers.forEach { $0.setNeedsDisplay() }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        redrawPageBackgrounds()
    }

    // MARK: - Scrolling & paging

    func scrollToPage(_ index: Int, animated: Bool) {
        guard pageFrames.indices.contains(index) else { return }
        let y = pageFrames[index].minY * zoomScale - contentInset.top
        let minY = -contentInset.top
        let maxY = max(minY, contentSize.height * zoomScale - bounds.height + contentInset.bottom)
        setContentOffset(CGPoint(x: contentOffset.x, y: min(max(y, minY), maxY)), animated: animated)
        activeIndex = index
        if controller.currentPageIndex != index {
            DispatchQueue.main.async { [controller] in controller.currentPageIndex = index }
        }
    }

    private func updateCurrentIndex() {
        guard !pageFrames.isEmpty, zoomScale > 0 else { return }
        // Don't re-activate pages mid-zoom: the center-page math is unstable
        // while the transform is animating, so it can briefly flip to a neighbour
        // and back — which flashes that page's cached low-res ink bitmap (a gray
        // "ghost" double-image) over the live canvas on pinch.
        guard !isZooming, !isZoomBouncing else { return }
        // Don't steal the live canvas while the pen is on the page.
        let drawingState = canvas.drawingGestureRecognizer.state
        guard drawingState != .began, drawingState != .changed else { return }
        let centerY = (contentOffset.y + bounds.height / 2) / zoomScale
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
            // The live canvas spans every page now — switching the "current" page
            // only re-targets paste / insert-space / AI ink; it never remounts.
            activeIndex = nearest
            DispatchQueue.main.async { [controller] in
                if controller.currentPageIndex != nearest {
                    controller.currentPageIndex = nearest
                }
            }
        }
    }

    private func publishGeometry() {
        let zoom = zoomScale
        let offset = contentOffset
        // documentView sits at the content origin; a content point P maps to
        // editor space as P*zoom − contentOffset.
        let origins = pageFrames.map { frame in
            CGPoint(x: frame.origin.x * zoom - offset.x, y: frame.origin.y * zoom - offset.y)
        }
        // Screen position of document (0,0) — the unified ink canvas's top-left.
        // Overlays reading raw canvas geometry (lasso, shape edit) anchor here.
        let canvasOrigin = CGPoint(x: -offset.x, y: -offset.y)
        guard origins != lastPublishedOrigins || zoom != controller.zoomScale else { return }
        lastPublishedOrigins = origins
        DispatchQueue.main.async { [weak controller] in
            guard let controller else { return }
            if controller.zoomScale != zoom { controller.zoomScale = zoom }
            if controller.pageScreenOrigins != origins { controller.pageScreenOrigins = origins }
            if controller.canvasScreenOrigin != canvasOrigin { controller.canvasScreenOrigin = canvasOrigin }
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
        // pass after the last zoom tick so the page backgrounds stay sharp. (The
        // ink is permanently supersampled, so it needs no per-zoom pass.)
        rasterWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateRasterScale() }
        rasterWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Releasing a pinch near fit-width snaps the page to exactly fill the screen.
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard contentSize.width > 0, zoomScale > 0 else { return }
        let fit = bounds.width / contentSize.width
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
        // HARD CAP 3: raising this beyond 3 (attempted twice for sharper deep
        // zoom) makes PencilKit's layer tree allocate enormous backing stores
        // and it silently stops rendering ink entirely. 3 is the proven-safe
        // ceiling for transform-zoom rendering; truly sharp 5x zoom needs the
        // canvas's native zoom instead (bigger restructure).
        let effectiveZoom = min(max(zoomScale, 1), 3)
        let raster = effectiveZoom * UIScreen.main.scale
        for container in containers {
            container.contentScaleFactor = raster
            container.layer.contentsScale = raster
            container.imageView.layer.contentsScale = raster
            container.setNeedsDisplay()
        }
        // The live canvas is permanently supersampled (inkScale× geometry at
        // screen scale), so it's ALREADY native-sharp and never needs a per-zoom
        // raster pass. Re-applying contentScaleFactor here on every zoom-end
        // forced PencilKit to re-rasterize its ink, which showed as a one-frame
        // ink "reposition" glitch on release — so it's gone. The canvas's scale
        // is set once at mount.
        // The active page's BACKGROUND (paper/template/PDF) is drawn by the
        // container's own CGContext — no PencilKit layer tree — so it can render
        // sharper than the 3x ink ceiling without the ink-breakage risk. PDFs
        // are vector, so this keeps them crisp deep into zoom instead of going
        // soft "like an image". Bounded to the single active page for memory.
        if containers.indices.contains(activeIndex) {
            let bg = min(max(zoomScale, 1), 4) * UIScreen.main.scale
            let active = containers[activeIndex]
            if abs(active.contentScaleFactor - bg) > 0.25 {
                active.contentScaleFactor = bg
                active.layer.contentsScale = bg
                active.setNeedsDisplay()
            }
        }
    }
    // NOTE: a "sharp deep-zoom overlay" (rendering the visible ink slice at
    // full zoom resolution over the canvas) was tried here and correlated
    // with ink not rendering at all — removed. Past 3x zoom stays soft until
    // the engine moves to PencilKit-native zooming.


    // MARK: - Native-sharp zoom (permanent supersample)

    /// Canonical (page-coordinate) ink → what the live canvas should display:
    /// appearance-adapted AND scaled up into the canvas's inkScale space.
    private func displayIntoCanvas(_ canonical: PKDrawing) -> PKDrawing {
        var d = InkColorAdapter.displayDrawing(canonical, darkMode: displayDark)
        if inkScale != 1 { d.transform(using: CGAffineTransform(scaleX: inkScale, y: inkScale)) }
        return d
    }

    /// The live canvas's drawing (inkScale space) → canonical page-coordinate ink
    /// for storage: scaled back down AND appearance-unadapted.
    private func canonicalFromCanvas(_ canvasDrawing: PKDrawing) -> PKDrawing {
        var d = canvasDrawing
        if inkScale != 1 { d.transform(using: CGAffineTransform(scaleX: 1 / inkScale, y: 1 / inkScale)) }
        return InkColorAdapter.storageDrawing(d, darkMode: displayDark)
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isProgrammaticChange else { return }
        let drawing = canvasView.drawing
        let scale = inkScale
        DispatchQueue.main.async { [weak self, controller] in
            controller.refreshUndoState()
            if let stroke = drawing.strokes.last {
                // Report the stroke on the page it actually landed on.
                let page = self?.pageIndex(forDocumentY: stroke.renderBounds.midY / scale) ?? 0
                controller.onStroke?(page, stroke)
            }
        }
        scheduleUnifiedSave()

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
        // Only recognise a SINGLE just-finished hand stroke. A bulk insert (AI ink
        // writes a whole expression — many strokes — in one drawing change) jumps
        // the count by more than one, and must never be snapped to a shape (that's
        // why an AI "1" was turning into a line).
        guard controller.autoShapes,
              controller.toolState.kind.isInking,
              count == lastStrokeCount + 1,
              let last = canvas.drawing.strokes.last else { return }

        let work = DispatchWorkItem { [weak self, weak canvas] in
            guard let self, let canvas, canvas.drawing.strokes.count == count else { return }
            // ~60pt (page) floor so handwriting-sized strokes are never snapped —
            // only deliberate, larger shapes. inkScale converts page→canvas space.
            guard var shape = ShapeRecognizer.recognize(last, minDiagonal: 60 * self.inkScale) else { return }
            // The stroke may sit on a peeking neighbour, not the centered page —
            // grade/snap against the page it actually landed on.
            let strokePage = self.pageIndex(forDocumentY: last.renderBounds.midY / self.inkScale)
            // Align the clean shape with the page's lines/grid.
            if self.controller.snapToGrid,
               let snapshot = self.controller.snapshotProvider?(strokePage),
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
                strokePage,
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
        guard var shape = ShapeRecognizer.recognize(points: rawPoints, minDiagonal: 60 * inkScale) else { return }
        // The hold may have happened on a peeking neighbour — resolve the page
        // from where the stroke is (canvas → document → page).
        let ys = rawPoints.map(\.y)
        let snapPage = pageIndex(forDocumentY: ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2 / inkScale)
        if controller.snapToGrid,
           let snapshot = controller.snapshotProvider?(snapPage),
           let metrics = SnapMetrics.metrics(for: snapshot.template, spacing: snapshot.templateSpacing) {
            // rawPoints (and `shape`) are in the canvas's inkScale× space, so the
            // page-space grid metrics must be scaled to match.
            let canvasMetrics = SnapMetrics(stepX: metrics.stepX.map { $0 * inkScale },
                                            stepY: metrics.stepY.map { $0 * inkScale })
            shape = ShapeRecognizer.snapped(shape, to: canvasMetrics)
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
                    for: shape, ink: inkingTool.ink,
                    width: CGFloat(controller.toolState.width) * 0.7 * inkScale
                ))
            }
            self.canvas.undoManager?.registerUndo(withTarget: self.canvas) { target in
                target.drawing = old
            }
            self.isProgrammaticChange = true
            self.canvas.drawing = replaced
            self.isProgrammaticChange = false
            self.lastStrokeCount = replaced.strokes.count
            Haptics.tap()
            // Keep this shape live so the pen (still down) can drag its last node;
            // endLiveShape() persists when the pen lifts.
            let index = replaced.strokes.count - 1
            let size = replaced.strokes.indices.contains(index) ? self.averageWidth(of: replaced.strokes[index]) : 4
            self.liveShape = LiveShape(shape: shape, index: index, ink: inkingTool.ink, size: size, original: old)
            self.controller.onShapeCreated?(
                snapPage,
                index,
                shape,
                inkingTool.ink,
                self.controller.toolState.width,
                self.controller.toolState.colorHex
            )
        }
    }

    // MARK: - Live shape adjust (drag the last node with the pen after a snap)

    private struct LiveShape {
        var shape: ShapeRecognizer.Shape
        var index: Int
        var ink: PKInk
        var size: CGFloat
        var original: PKDrawing
    }
    private var liveShape: LiveShape?

    /// The pen moved after the snap — drag the shape's last node to follow it and
    /// re-render the clean shape live (all in canvas coordinates).
    private func adjustLiveShape(to penPoint: CGPoint) {
        guard var live = liveShape, canvas.drawing.strokes.indices.contains(live.index) else { return }
        live.shape = ShapeRecognizer.Shape.movingLastNode(live.shape, to: penPoint)
        liveShape = live
        var drawing = canvas.drawing
        drawing.strokes[live.index] = ShapeRecognizer.idealStroke(for: live.shape, ink: live.ink, width: live.size)
        isProgrammaticChange = true
        canvas.drawing = drawing
        isProgrammaticChange = false
    }

    /// The pen lifted — commit the adjusted shape (undoable back to before the snap).
    private func endLiveShape() {
        guard let live = liveShape else { return }
        liveShape = nil
        let final = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: canvas) { [original = live.original] target in
            target.drawing = original
        }
        lastStrokeCount = final.strokes.count
        persistUnified()
        DispatchQueue.main.async { [controller] in controller.refreshUndoState() }
    }

    /// Circle the size of the eraser stroke, following the touch while erasing.
    private let eraserCursor = UIView()

    @objc private func drawingGestureMoved(_ recognizer: UIGestureRecognizer) {
        if recognizer.state == .began {
            // Starting to write dismisses transient chrome: the notes drawer
            // (when the intercept is armed) and the toolbar's color strip.
            if interceptTap?.isEnabled == true { controller.onInterceptedTap?() }
            controller.noteDrawingGestureBegan()
        }
        guard controller.toolState.kind == .eraserPixel || controller.toolState.kind == .eraserObject else {
            eraserCursor.isHidden = true
            return
        }
        switch recognizer.state {
        case .began, .changed:
            // Pixel eraser uses its real width; the object eraser gets a small
            // fixed reticle (it erases whole strokes, not an area). The cursor
            // lives in the canvas's inkScale× space, so scale it to match.
            let pageDiameter = controller.toolState.kind == .eraserPixel ? max(controller.toolState.width, 6) : 14
            let diameter = pageDiameter * inkScale
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
            // Shape + width stay in the canvas's inkScale× space; the editor
            // overlay maps them with the unified-canvas transform.
            controller.onShapeTapped?(
                pageIndex(forDocumentY: stroke.renderBounds.midY / inkScale),
                index,
                shape,
                stroke.ink,
                Double(averageWidth(of: stroke)),
                displayHex(for: stroke.ink)
            )
            return
        }
        // No shape under the tap — report it in the CURRENT page's coordinates
        // (canvas → document → page-local) so the editor can hit-test that page's
        // media / place the paste menu.
        let docPoint = CGPoint(x: location.x / inkScale, y: location.y / inkScale)
        let origin = pageDocumentOrigin(activeIndex)
        controller.onCanvasFingerTap?(CGPoint(x: docPoint.x - origin.x, y: docPoint.y - origin.y))
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
    /// The editor works in the canvas's coordinate space (via canvasTransform),
    /// so `stroke` is already in canvas coordinates.
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
        persistUnified()
        DispatchQueue.main.async { [controller] in controller.refreshUndoState() }
    }

    // MARK: - Lasso selection (lift while transforming)

    /// The drawing as it was before a lasso selection lifted its strokes out, so
    /// the moving preview isn't shadowed by the originals.
    private var selectionOriginal: PKDrawing?

    /// Remove the selected strokes from the live canvas — their snapshot rides in
    /// the transform overlay — so dragging the selection doesn't leave a ghost of
    /// the originals behind.
    func liftStrokeSelection(_ indices: [Int]) {
        guard selectionOriginal == nil else { return }
        let original = canvas.drawing
        selectionOriginal = original
        var lifted = original
        for index in indices.sorted(by: >) where lifted.strokes.indices.contains(index) {
            lifted.strokes.remove(at: index)
        }
        isProgrammaticChange = true
        canvas.drawing = lifted
        isProgrammaticChange = false
    }

    /// Commit the lasso transform onto the original (un-lifted) strokes.
    func commitStrokeSelection(rotation: Double, scale: CGFloat, translation: CGSize, selection: StrokeSelection) {
        guard let original = selectionOriginal else { return }
        selectionOriginal = nil
        let transformed = StrokeSelector.applyTransform(
            rotation: rotation, scale: scale, translation: translation, selection: selection, to: original)
        canvas.undoManager?.registerUndo(withTarget: canvas) { [original] target in
            target.drawing = original
        }
        canvas.drawing = transformed   // not programmatic → auto-persists via delegate
    }

    /// Cancel a lasso transform: drop the originals back in unchanged.
    func cancelStrokeSelection() {
        guard let original = selectionOriginal else { return }
        selectionOriginal = nil
        isProgrammaticChange = true
        canvas.drawing = original
        isProgrammaticChange = false
        lastStrokeCount = original.strokes.count
    }

    /// Delete the selection — the strokes are already lifted out, so just make
    /// that permanent (undoably).
    func deleteStrokeSelection() {
        guard let original = selectionOriginal else { return }
        selectionOriginal = nil
        let lifted = canvas.drawing   // already without the selected strokes
        canvas.undoManager?.registerUndo(withTarget: canvas) { target in target.drawing = original }
        persistUnified()
        DispatchQueue.main.async { [controller] in controller.refreshUndoState() }
    }

    /// Duplicate: commit the current move/rotate/scale onto the originals (so the
    /// item stays where the user dragged it), then add an offset copy.
    func duplicateStrokeSelection(rotation: Double, scale: CGFloat, translation: CGSize, selection: StrokeSelection) {
        guard let original = selectionOriginal else { return }
        selectionOriginal = nil
        let moved = StrokeSelector.applyTransform(
            rotation: rotation, scale: scale, translation: translation, selection: selection, to: original)
        let picked = selection.strokeIndices.compactMap {
            moved.strokes.indices.contains($0) ? moved.strokes[$0] : nil
        }
        var copies = PKDrawing(strokes: picked)
        copies.transform(using: CGAffineTransform(translationX: 26 * inkScale, y: 26 * inkScale))
        canvas.undoManager?.registerUndo(withTarget: canvas) { target in target.drawing = original }
        canvas.drawing = moved.appending(copies)   // not programmatic → persists
    }

    /// Copy: a screenshot of the page region under the lasso goes to the system
    /// pasteboard (captures non-ink content too); the editable strokes go to the
    /// in-app clipboard. The selection stays where the user left it (the current
    /// move/rotate/scale is committed, so it doesn't snap back).
    func copyStrokeSelection(rotation: Double, scale: CGFloat, translation: CGSize, selection: StrokeSelection) {
        writeClipboards(selection)
        commitStrokeSelection(rotation: rotation, scale: scale, translation: translation, selection: selection)
    }

    /// Cut: copy to the clipboards, then leave the strokes deleted.
    func cutStrokeSelection(_ selection: StrokeSelection) {
        writeClipboards(selection)
        deleteStrokeSelection()
    }

    private func writeClipboards(_ selection: StrokeSelection) {
        // Cross-app: render the page crop under the selection (background, media,
        // PDF, ink) and put it on the system pasteboard.
        if let snap = controller.snapshotProvider?(activeIndex) {
            let scale: CGFloat = 3
            let full = PageRenderer.render(snap, darkMode: displayDark, scale: scale)
            let page = CGRect(x: selection.bounds.minX / inkScale, y: selection.bounds.minY / inkScale,
                              width: selection.bounds.width / inkScale, height: selection.bounds.height / inkScale)
                .insetBy(dx: -8, dy: -8)
            let px = CGRect(x: page.minX * scale, y: page.minY * scale,
                            width: page.width * scale, height: page.height * scale)
                .intersection(CGRect(origin: .zero, size: CGSize(width: full.size.width * scale, height: full.size.height * scale)))
            if !px.isEmpty, let cg = full.cgImage?.cropping(to: px) {
                UIPasteboard.general.image = UIImage(cgImage: cg)
            }
        }
        // In-app: the editable strokes (canvas coordinates) for stroke paste.
        if let original = selectionOriginal {
            controller.strokeClipboard = selection.strokeIndices.compactMap {
                original.strokes.indices.contains($0) ? original.strokes[$0] : nil
            }
        }
    }

    /// Shifts every stroke BELOW `pageY` down by `amount` (page points) — the
    /// "Insert Space" action, undoable.
    func insertSpace(belowPageY pageY: CGFloat, amount: CGFloat) {
        guard pageFrames.indices.contains(activeIndex) else { return }
        // pageY is current-page-local → document. Only shift strokes ON this page
        // and below the line, so later pages' work isn't dragged down too.
        let frame = pageFrames[activeIndex]
        let lineCanvasY = (frame.minY + pageY) * inkScale
        let bandTop = frame.minY * inkScale
        let bandBottom = frame.maxY * inkScale
        let dy = amount * inkScale
        var strokes = canvas.drawing.strokes
        var changed = false
        for i in strokes.indices {
            let r = strokes[i].renderBounds
            guard r.minY > lineCanvasY, r.midY >= bandTop, r.midY < bandBottom else { continue }
            strokes[i].transform = strokes[i].transform.concatenating(CGAffineTransform(translationX: 0, y: dy))
            changed = true
        }
        guard changed else { return }
        let old = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: canvas) { $0.drawing = old }
        canvas.drawing = PKDrawing(strokes: strokes)
    }

    /// Paste the in-app stroke clipboard. With a page point (finger-tap paste) the
    /// clipboard is centred there; otherwise it's nudged off the original. Returns
    /// the pasted strokes' bounds (CANVAS space) so the editor can select them.
    @discardableResult
    func pasteStrokes(at pagePoint: CGPoint? = nil) -> CGRect? {
        guard let strokes = controller.strokeClipboard, !strokes.isEmpty else { return nil }
        var paste = PKDrawing(strokes: strokes)
        if let pagePoint {
            // pagePoint is page-local on the current page → document → canvas.
            let origin = pageDocumentOrigin(activeIndex)
            let target = CGPoint(x: (pagePoint.x + origin.x) * inkScale, y: (pagePoint.y + origin.y) * inkScale)
            let b = paste.bounds
            paste.transform(using: CGAffineTransform(translationX: target.x - b.midX, y: target.y - b.midY))
        } else {
            paste.transform(using: CGAffineTransform(translationX: 30 * inkScale, y: 30 * inkScale))
        }
        let old = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: canvas) { target in target.drawing = old }
        canvas.drawing = old.appending(paste)
        return paste.bounds
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

    // MARK: - Dismiss-tap intercept

    private weak var interceptTap: UITapGestureRecognizer?

    /// While enabled, the first tap (finger or pencil) anywhere on the canvas
    /// area fires `controller.onInterceptedTap` and swallows the touch.
    func setTapIntercept(enabled: Bool) {
        interceptTap?.isEnabled = enabled
    }

    @objc private func interceptTapFired(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        controller.onInterceptedTap?()
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
        // Paper follows appearance — dark page in dark mode. The iOS 26 SDK
        // renders PencilKit colors literally, so ink is adapted at display
        // time (black ↔ near-white) via InkColorAdapter; storage stays
        // canonical. See CanvasController.isDarkMode / engine.appearanceChanged.
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
    /// After the snap fires, keep reporting the pen so the shape's last node can
    /// be dragged live; `onAdjustEnd` fires when the pen lifts.
    var onAdjust: ((CGPoint) -> Void)?
    var onAdjustEnd: (() -> Void)?

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
        // Once snapped, the pen keeps dragging the shape's last node.
        if fired { onAdjust?(location); return }
        samples.append(location)
        if hypot(location.x - lastLocation.x, location.y - lastLocation.y) > 2.5 {
            lastLocation = location
            lastMoveAt = Date()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if fired { onAdjustEnd?() }
        reset()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if fired { onAdjustEnd?() }
        reset()
    }

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

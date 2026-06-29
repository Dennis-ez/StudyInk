import SwiftUI
import PencilKit

/// PKCanvasView that suppresses the system "Select All / Insert Space / Paste"
/// edit menu — the app provides its own themed finger-tap paste menu, so the
/// built-in one (which pastes a screenshot, not ink) must not appear. PencilKit's
/// menu rides a UIEditMenuInteraction that ignores canPerformAction, so we strip
/// the interaction outright (and keep re-stripping, since PencilKit re-adds it).
final class InkCanvasView: PKCanvasView {
    /// The real ink surface — AI ink insertion routes here (PencilKit is inert).
    weak var vectorCanvas: VectorInkView?
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    // PencilKit shifts this scroll view's contentOffset mid-stroke (it tries to
    // keep the active stroke "visible"), which slid the WHOLE drawing down under
    // the pen and snapped it back on lift — the "ink is offset under the pen"
    // bug. Our geometry shows the ENTIRE page at once (bounds = page × inkScale)
    // and scrolling is disabled, so the offset must always be zero — pin it.
    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set { super.contentOffset = .zero }
    }
    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        super.setContentOffset(.zero, animated: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        stripEditMenuInteractions()
    }

    override func addInteraction(_ interaction: any UIInteraction) {
        // Drop the edit-menu interaction the moment PencilKit tries to add it.
        if interaction is UIEditMenuInteraction { return }
        super.addInteraction(interaction)
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        stripEditMenuInteractions()
    }

    private func stripEditMenuInteractions() {
        func strip(_ view: UIView) {
            for interaction in view.interactions where interaction is UIEditMenuInteraction {
                view.removeInteraction(interaction)
            }
            view.subviews.forEach(strip)
        }
        strip(self)
    }
}

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

    let canvas = InkCanvasView()   // inert — PencilKit is being removed
    /// The live custom vector ink canvas (the real ink surface).
    let vectorCanvas = VectorInkView()
    /// NOTE-LEVEL (shared) undo/redo — ONE history across ALL pages. Each entry is a
    /// page's strokes BEFORE an edit; undo reverts it (switching to that page).
    private var noteUndo: [(index: Int, strokes: [VectorInk.Stroke])] = []
    private var noteRedo: [(index: Int, strokes: [VectorInk.Stroke])] = []
    /// Last committed strokes per page — the "before" source for undo AND a mount cache
    /// (skips re-converting the PKDrawing when re-opening a page → smoother swiping).
    private var lastStrokes: [Int: [VectorInk.Stroke]] = [:]
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
    /// Native-sharp zoom: the live canvas ALWAYS renders at `inkScale`× the page
    /// size (counter-scaled to fit), so transform-zoom up to maximumZoomScale
    /// never magnifies below native resolution — ink is sharp at every moment,
    /// including mid-pinch. PencilKit tiles its rendering, so memory stays
    /// bounded to the viewport. The cost: the canvas's internal coordinates are
    /// inkScale×, so ink is scaled at the load/save/AI-insert boundaries (see
    /// displayIntoCanvas / canonicalFromCanvas). KILL SWITCH: set to 1 to fully
    /// revert to plain page-coordinate, transform-zoom behaviour.
    ///
    /// HISTORY (the supersample ⇄ live-offset tradeoff, settled by user choice):
    /// • 4 → 1 (2026-06-25): inkScale=1 = no transform = the live stroke lands
    ///   exactly under the pen, but ALL zoom (incl. fit-zoom on PDFs) renders ink
    ///   soft, because at 1× the canvas only renders at screen scale and the
    ///   transform-zoom magnifies it.
    /// • 1 → 4 (2026-06-27): the user explicitly asked for the SHARP ink back
    ///   ("we already had good sharp ink, bring that back"), and the native-zoom
    ///   prototype (NativeZoomLab) confirmed PencilKit's own zoom does NOT
    ///   re-tessellate crisply on this SDK — so supersampling is the only way to
    ///   sharp ink. inkScale=4 renders ink at 4× resolution → crisp through zoom.
    ///   KNOWN COST: the 4× canvas is counter-scaled by a transform, and iOS 26
    ///   PencilKit can render the IN-PROGRESS stroke offset under the pen (snaps
    ///   correct on lift), most visibly on PDF pages. Sharp-ink and zero-offset are
    ///   mutually exclusive here until the canvas gets true native zoom; the user
    ///   prioritised sharpness. (OOM-on-deep-zoom that plagued inkScale=4 before is
    ///   now bounded by the budget caps in updateRasterScale.)
    /// USER-CHOSEN TRADEOFF (settings.canvas.smoothInk, default sharp = 4). On the
    /// iOS 26 SDK these two are mutually exclusive and there is no universally right
    /// answer, so the user picks:
    ///   • 4 (sharp): ink rendered at 4× resolution → crisp at every zoom; the cost
    ///     is the live in-progress stroke can sit slightly offset under the pen on
    ///     imported-PDF pages (snaps correct on lift), because PencilKit mis-renders
    ///     the active stroke through the canvas's counter-scale transform.
    ///   • 1 (smooth): no transform → the live stroke lands exactly under the pen,
    ///     but zoomed-in ink goes soft (rendered at screen scale, magnified).
    /// Read once at engine construction; takes effect on the next note open.
    private let inkScale: CGFloat =
        UserDefaults.standard.bool(forKey: "settings.canvas.smoothInk") ? 1 : 4
    /// Cached-render resolution in PIXELS per point, raised when zoomed in.
    /// Inactive pages render at screen scale — retina-sharp at rest, not a soft
    /// 1x bitmap. They are intentionally NOT bumped with zoom: re-rasterizing
    /// every page's full-page bitmap on pinch OOM-hung long notes. Only the
    /// active page gets zoom-resolution rasterization (see updateRasterScale).
    // Off-screen / scrolling page images are rendered by our CPU vector renderer, whose
    // cost scales with pixel count. These images are only shown while a page is INACTIVE
    // or mid-scroll — the live page you draw on is the crisp tiled vector canvas — so
    // render them at ~1.5× instead of full retina: far cheaper to stroke (helps dense
    // notes), and they sharpen the instant you settle on a page (the live canvas takes
    // over). Capped at 2 for low-DPI safety.
    private let imageRenderScale: CGFloat = min(UIScreen.main.scale, 1.5)
    private var rasterWorkItem: DispatchWorkItem?
    private var shapeWorkItem: DispatchWorkItem?
    private var lastStrokeCount = 0
    /// True from a stroke's first touch until pen-up. While true, layoutSubviews
    /// must NOT move the document (re-inset / recentre) — that slid the page under
    /// the pen mid-stroke. Reset triggers one settling layout on lift.
    private var strokeInFlight = false
    /// Snap a shape WHILE the pen is still down? Disabled: doing so requires turning
    /// off PencilKit's drawing gesture mid-stroke, which cancels the live touch — the
    /// snapped shape was dropped before it persisted ("ink disappears" on hold) and
    /// the live node-adjust never tracked. Shapes still snap reliably ON LIFT
    /// (scheduleShapeRecognition). Re-enable only with on-device gesture testing.
    private let holdSnapEnabled = false
    /// Bumped on each active-page reveal; the delayed reveal only fires if its
    /// token is still current (so a re-bridge supersedes an in-flight one).
    private var revealToken = 0
    private var lastPublishedOrigins: [CGPoint] = []
    private var keyboardObservers: [NSObjectProtocol] = []
    private weak var holdRecognizer: UILongPressGestureRecognizer?
    private weak var lassoPan: UIPanGestureRecognizer?

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
        // Cap at the raster ceiling (transform-zoom rasterizes ink to a bitmap;
        // past 3x it can't get sharper without breaking PencilKit — see
        // updateRasterScale). So all reachable zoom stays crisp instead of
        // letting the user zoom into blur.
        // Ink is permanently supersampled at inkScale×, so zoom stays native-
        // sharp up to that factor (no transform-zoom raster wall any more).
        maximumZoomScale = 4
        bouncesZoom = true
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        // A status-bar tap must NOT fling the page to the top mid-writing.
        scrollsToTop = false
        // The desk follows the active theme so the canvas backdrop matches the
        // rest of the app (the page itself stays its own paper colour).
        backgroundColor = AppTheme.current.deskUIColor

        addSubview(documentView)

        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        // PKCanvasView is itself a UIScrollView; left on .automatic it folds the
        // safe-area inset into its drawing space, so ink landed BELOW the pen
        // (worst on tall imported-PDF pages reaching into the top inset). Pin it.
        canvas.contentInsetAdjustmentBehavior = .never
        // Pin ONLY the PKCanvasView to light so PencilKit renders ink colors
        // LITERALLY (no appearance adaptation of the live tool — which on iOS
        // 26 still turns a near-white pen dark). The PAGE container stays on
        // the real (dark) appearance and draws a dark page; the canvas is
        // transparent, so dark page + the literal light ink show correctly.
        // Ink colors are pre-adapted by appearance via InkColorAdapter.
        canvas.overrideUserInterfaceStyle = .light
        controller.inkScale = inkScale
        controller.attach(canvas)
        // The real ink surface: transparent over the page container, page-coordinate
        // (no inkScale — the tiled layer re-renders sharp at any zoom).
        vectorCanvas.backgroundColor = .clear
        canvas.vectorCanvas = vectorCanvas   // AI ink routes through the inert canvas → here
        vectorCanvas.onChange = { [weak self] in self?.vectorCanvasChanged() }
        // The editor's TransformLassoOverlay owns selection — the engine just captures
        // the loop and reports it (in canvas/inkScale space, matching the projection the
        // existing lasso pipeline reads).
        vectorCanvas.externalLasso = true
        vectorCanvas.onLassoBeganExternal = { [weak self] in self?.controller.onLassoBegan?() }
        vectorCanvas.onLassoChangedExternal = { [weak self] pts in
            self?.controller.lassoPoints = pts   // PAGE space — overlays use transform(forPage:)
        }
        vectorCanvas.onLassoEndedExternal = { [weak self] pts in
            guard let self else { return }
            self.controller.onLassoComplete?(pts)
            // Clear the LIVE loop so its marching-ants outline doesn't linger once the
            // selection overlay takes over.
            self.controller.lassoPoints = []
        }
        controller.attachVector(vectorCanvas)
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
        addGestureRecognizer(undoTap)   // on the scroll view (canvas is inert), no stray strokes

        let redoTap = UITapGestureRecognizer(target: self, action: #selector(multiFingerRedo(_:)))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        redoTap.cancelsTouchesInView = false
        redoTap.delegate = self
        addGestureRecognizer(redoTap)
        undoTap.require(toFail: redoTap)

        // Eraser cursor: ride along with the system drawing gesture so the
        // circle tracks exactly where erasing happens, sized like the eraser.
        canvas.drawingGestureRecognizer.addTarget(self, action: #selector(drawingGestureMoved(_:)))
        eraserCursor.isUserInteractionEnabled = false
        eraserCursor.isHidden = true
        eraserCursor.layer.borderWidth = 1.5
        eraserCursor.backgroundColor = UIColor.systemGray.withAlphaComponent(0.12)
        canvas.addSubview(eraserCursor)

        // DEBUG pen tracker: a red dot at the EXACT touch point. A screen recording
        // can't show the physical Pencil, so this is the only way to see a gap
        // between the pen and the rendered ink. Off unless Settings → debug toggle.
        penTracker.isUserInteractionEnabled = false
        penTracker.isHidden = true
        penTracker.layer.borderWidth = 2 * inkScale
        penTracker.layer.borderColor = UIColor.systemRed.cgColor
        penTracker.backgroundColor = UIColor.systemRed.withAlphaComponent(0.22)
        canvas.addSubview(penTracker)

        // Circle & Ask trigger: hold the Pencil still for ~1s.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(pencilHeld(_:)))
        hold.minimumPressDuration = 1.0
        hold.allowableMovement = 8
        hold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hold.delegate = self
        addGestureRecognizer(hold)
        holdRecognizer = hold

        // Lasso loop capture: a PENCIL-only pan that records the loop points. It
        // lives on the canvas alongside the scroll view's finger pan, so a finger
        // still scrolls/zooms the page while the lasso tool is armed. Disabled
        // until the lasso tool is selected (controller.applyTool → setLassoGestureActive).
        let lasso = UIPanGestureRecognizer(target: self, action: #selector(lassoPanned(_:)))
        lasso.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        lasso.maximumNumberOfTouches = 1
        lasso.isEnabled = false
        lasso.delegate = self
        canvas.addGestureRecognizer(lasso)
        lassoPan = lasso

        // UIKit-level dismiss tap: while a SwiftUI drawer/panel is open, the
        // editor arms this to catch the first tap anywhere on the canvas area
        // (SwiftUI tap catchers lose to the canvas's UIKit hit-testing).
        let intercept = UITapGestureRecognizer(target: self, action: #selector(interceptTapFired(_:)))
        intercept.cancelsTouchesInView = true
        intercept.delegate = self
        intercept.isEnabled = false
        addGestureRecognizer(intercept)
        interceptTap = intercept

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
        noteUndo.removeAll(); noteRedo.removeAll(); lastStrokes.removeAll()   // page list changed → indices stale
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

        // No "add page" button — the document auto-grows a fresh page when the
        // last one is inked. Just leave a little breathing room below the stack.
        let docHeight = y + 40

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
        if !seededActiveDrawing,
           canvas.drawing.strokes.isEmpty,
           let drawing = controller.drawingProvider?(activeIndex),
           !drawing.strokes.isEmpty {
            isProgrammaticChange = true
            canvas.drawing = displayIntoCanvas(drawing)
            isProgrammaticChange = false
            lastStrokeCount = drawing.strokes.count
            seededActiveDrawing = true
            // The drawing only just arrived (cold open: providers wire AFTER mount),
            // so the canvas was revealed empty. Re-bridge: show the cached ink now
            // and re-reveal once PencilKit has drawn the seeded strokes.
            bridgeActiveReveal(index: activeIndex)
        }
        // Active page's content (cached render incl. ink) is up → drop the loader.
        if containers.indices.contains(activeIndex), containers[activeIndex].snapshot != nil {
            DispatchQueue.main.async { [controller] in controller.markReady() }
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

    /// Gutter above page 1, below the status bar: clears the floating toolbar
    /// row AND leaves room for the larger two-line note title, plus comfortable
    /// drag space so the page never tucks under the clock or the tools.
    private let topGutter: CGFloat = 112

    override func layoutSubviews() {
        super.layoutSubviews()
        // While a stroke is in flight, leave the document exactly where it is — a
        // re-inset/recenter here slides the page out from under the pen (and snaps
        // back on lift). The lift triggers a settling layout.
        guard !strokeInFlight else { publishGeometry(); return }
        let top = safeAreaInsets.top + topGutter
        if abs(contentInset.top - top) > 0.5 {
            let restingAtTop = contentOffset.y <= -contentInset.top + 1
            contentInset.top = top
            verticalScrollIndicatorInsets.top = top
            // Keep the page pinned just below the gutter if we were at the top.
            if restingAtTop { contentOffset.y = -top }
        }
        applyInitialZoomIfNeeded()
        centerDocument()
        restorePageIfNeeded()
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
        // Rest just below the top gutter so page 1 clears the status bar.
        contentOffset = CGPoint(x: max(0, (contentSize.width - bounds.width) / 2), y: -contentInset.top)
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

    private func mountCanvas(on index: Int) {
        guard containers.indices.contains(index) else { return }
        unfreezeInkAfterScroll()   // restore the live canvas before reparenting it
        PerfMonitor.shared.setActivity("page-mount")
        activeIndex = index
        activeImageDirty = false   // the bridge renders this page's image fresh
        let container = containers[index]
        // Hide the live canvas (still holding the PREVIOUS page's ink) and reveal
        // the destination page's cached render BEFORE reparenting it — otherwise
        // the old ink shows for one frame at the new page (the flash when swiping
        // to the first/last page). PencilKit also renders the swapped-in drawing
        // asynchronously, so the canvas stays hidden until it catches up.
        vectorCanvas.alpha = 0
        container.imageView.isHidden = false
        applyVectorGeometry(pageSize: pageSizes[index])
        container.addSubview(vectorCanvas)
        seededActiveDrawing = controller.drawingProvider != nil
        // Load the page's CANONICAL strokes (the engine adapts colour at render time).
        if let cached = lastStrokes[index] {
            isProgrammaticChange = true
            vectorCanvas.loadStrokes(cached)
            isProgrammaticChange = false
            bridgeActiveReveal(index: index)
        } else {
            // Convert PKDrawing → vectors OFF the main thread. On a DENSE page this takes
            // hundreds of ms–seconds; on main it froze the UI (the multi-second hitches
            // and the laggy first stroke). The cached page image bridges the gap; reveal
            // the live canvas once the conversion lands.
            let data = (controller.drawingProvider?(index) ?? PKDrawing()).dataRepresentation()
            isProgrammaticChange = true
            vectorCanvas.loadStrokes([])
            isProgrammaticChange = false
            container.imageView.isHidden = false
            Task.detached(priority: .userInitiated) {
                let pk = (try? PKDrawing(data: data)) ?? PKDrawing()
                let converted = VectorInk.strokes(from: pk)
                await MainActor.run { [weak self] in
                    guard let self, self.activeIndex == index else { return }
                    self.lastStrokes[index] = converted
                    self.isProgrammaticChange = true
                    self.vectorCanvas.loadStrokes(converted)
                    self.isProgrammaticChange = false
                    self.bridgeActiveReveal(index: index)
                }
            }
        }
        shapeWorkItem?.cancel()
        DispatchQueue.main.async { [controller] in controller.refreshUndoState() }
    }

    /// Bridge a page's reveal: show its cached render (background + ink) and keep
    /// the live canvas hidden behind it for `delay`, until PencilKit has rendered
    /// the swapped-in drawing. Token-guarded so a later bridge (e.g. once the
    /// drawing provider connects on a cold open) supersedes an earlier one instead
    /// of revealing a still-empty canvas.
    private func bridgeActiveReveal(index: Int, delay: TimeInterval = 0.22) {
        guard containers.indices.contains(index) else { return }
        let container = containers[index]
        revealToken += 1
        let token = revealToken
        vectorCanvas.alpha = 0
        container.imageView.isHidden = false
        // Render the active page's cached ink at high priority (it's the thing the
        // user is waiting to see). Only inactive pages are pre-rendered elsewhere.
        if container.imageView.image == nil { renderImage(for: index, priority: .userInitiated) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak container] in
            guard let self, self.activeIndex == index, self.revealToken == token else { return }
            self.vectorCanvas.alpha = 1
            container?.imageView.isHidden = true
            if PerfMonitor.shared.activity == "page-mount" { PerfMonitor.shared.setActivity("idle") }
        }
    }

    private func activatePage(_ index: Int) {
        guard index != activeIndex, containers.indices.contains(index) else { return }
        abortStrokeEditIfNeeded()
        flushPendingSave()
        let oldIndex = activeIndex
        if containers.indices.contains(oldIndex) {
            // Show the old page's cached render IMMEDIATELY as the canvas leaves
            // — otherwise it goes blank until the async re-render lands and the
            // ink visibly flashes back in. Then refresh it in place (a seamless
            // image swap) to pick up any strokes added while it was active.
            containers[oldIndex].imageView.isHidden = false
            renderImage(for: oldIndex)
        }
        mountCanvas(on: index)
    }

    private func flushPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        persistVector(at: activeIndex)
    }

    /// Geometry for the vector canvas: 1:1 with the page (no inkScale — the tiled
    /// layer re-renders sharp at any zoom, so no supersample transform is needed).
    private func applyVectorGeometry(pageSize: CGSize) {
        vectorCanvas.transform = .identity
        vectorCanvas.frame = CGRect(origin: .zero, size: pageSize)
    }

    /// The vector canvas changed (commit / erase / move / undo). Debounce a save and
    /// refresh undo state. Strokes carry CANONICAL colour, so the PKDrawing projection
    /// written to Core Data (for OCR / export / AI-vision) is canonical too.
    private func vectorCanvasChanged() {
        guard !isProgrammaticChange else { return }
        activeImageDirty = true   // cached image now stale until the post-edit render lands
        let index = activeIndex
        let after = vectorCanvas.currentStrokes()
        // Shared note-level undo: record this page's BEFORE-state.
        noteUndo.append((index, lastStrokes[index] ?? []))
        if noteUndo.count > 250 { noteUndo.removeFirst() }
        noteRedo.removeAll()
        lastStrokes[index] = after
        controller.refreshUndoState()
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [controller, weak self] in
            controller.onDrawingChanged?(index, VectorInk.pkDrawing(from: after))
            // Refresh the active page's cached image (off-main) so a later scroll-freeze
            // shows current ink without rendering mid-scroll.
            self?.renderImage(for: index)
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Shared (note-level) undo/redo — one history across all pages

    var canNoteUndo: Bool { !noteUndo.isEmpty }
    var canNoteRedo: Bool { !noteRedo.isEmpty }

    func noteUndoAction() {
        guard let (index, before) = noteUndo.popLast() else { return }
        let after = (index == activeIndex) ? vectorCanvas.currentStrokes() : (lastStrokes[index] ?? [])
        noteRedo.append((index, after))
        applyNoteHistory(index: index, strokes: before)
    }
    func noteRedoAction() {
        guard let (index, after) = noteRedo.popLast() else { return }
        let before = (index == activeIndex) ? vectorCanvas.currentStrokes() : (lastStrokes[index] ?? [])
        noteUndo.append((index, before))
        applyNoteHistory(index: index, strokes: after)
    }
    // MARK: Lasso selection — directly on vector strokes (no PencilKit projection)

    private var vectorSelIndices: [Int]?
    private var vectorSelBefore: [VectorInk.Stroke]?

    private func selectionTransform(_ rotation: Double, _ scale: CGFloat, _ translation: CGSize, _ selection: StrokeSelection) -> CGAffineTransform {
        let c = CGPoint(x: selection.bounds.midX, y: selection.bounds.midY)
        return CGAffineTransform(translationX: c.x, y: c.y)
            .rotated(by: rotation * .pi / 180)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(translationX: translation.width, y: translation.height))
    }
    private func transformed(_ strokes: [VectorInk.Stroke], indices: Set<Int>, by t: CGAffineTransform) -> [VectorInk.Stroke] {
        let w = sqrt(abs(t.a * t.d - t.b * t.c))
        return strokes.enumerated().map { i, s in
            guard indices.contains(i) else { return s }
            return VectorInk.Stroke(color: s.color, samples: s.samples.map {
                InkSample(location: $0.location.applying(t), width: $0.width * w) })
        }
    }

    /// Lift the selected vector strokes off the page (they ride in the overlay).
    func liftVectorSelection(_ indices: [Int]) {
        guard vectorSelBefore == nil else { return }
        let all = vectorCanvas.currentStrokes()
        vectorSelBefore = all
        vectorSelIndices = indices
        let set = Set(indices)
        let remaining = all.enumerated().filter { !set.contains($0.offset) }.map(\.element)
        vectorCanvas.setStrokesPreservingHistory(remaining)
        lastStrokes[activeIndex] = remaining
        vectorCanvas.isUserInteractionEnabled = false   // drag → overlay, not a new lasso
    }
    func commitVectorSelection(rotation: Double, scale: CGFloat, translation: CGSize, selection: StrokeSelection) {
        guard let before = vectorSelBefore, let indices = vectorSelIndices else { return }
        vectorSelBefore = nil; vectorSelIndices = nil
        vectorCanvas.isUserInteractionEnabled = true
        let t = selectionTransform(rotation, scale, translation, selection)
        finishVectorSelection(before: before, after: transformed(before, indices: Set(indices), by: t))
    }
    func cancelVectorSelection() {
        guard let before = vectorSelBefore else { return }
        vectorSelBefore = nil; vectorSelIndices = nil
        vectorCanvas.isUserInteractionEnabled = true
        vectorCanvas.setStrokesPreservingHistory(before)
        lastStrokes[activeIndex] = before
    }
    func deleteVectorSelection() {
        guard let before = vectorSelBefore, let indices = vectorSelIndices else { return }
        vectorSelBefore = nil; vectorSelIndices = nil
        vectorCanvas.isUserInteractionEnabled = true
        let set = Set(indices)
        finishVectorSelection(before: before, after: before.enumerated().filter { !set.contains($0.offset) }.map(\.element))
    }
    func duplicateVectorSelection(rotation: Double, scale: CGFloat, translation: CGSize, selection: StrokeSelection) {
        guard let before = vectorSelBefore, let indices = vectorSelIndices else { return }
        vectorSelBefore = nil; vectorSelIndices = nil
        vectorCanvas.isUserInteractionEnabled = true
        let set = Set(indices)
        let moved = transformed(before, indices: set, by: selectionTransform(rotation, scale, translation, selection))
        let off = CGAffineTransform(translationX: 26, y: 26)
        let copies = indices.compactMap { moved.indices.contains($0) ? moved[$0] : nil }.map { s in
            VectorInk.Stroke(color: s.color, samples: s.samples.map { InkSample(location: $0.location.applying(off), width: $0.width) })
        }
        finishVectorSelection(before: before, after: moved + copies)
    }
    private func finishVectorSelection(before: [VectorInk.Stroke], after: [VectorInk.Stroke]) {
        noteUndo.append((activeIndex, before)); if noteUndo.count > 250 { noteUndo.removeFirst() }
        noteRedo.removeAll()
        lastStrokes[activeIndex] = after
        vectorCanvas.setStrokesPreservingHistory(after)
        let index = activeIndex
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [controller] in controller.onDrawingChanged?(index, VectorInk.pkDrawing(from: after)) }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        controller.refreshUndoState()
    }

    private func applyNoteHistory(index: Int, strokes: [VectorInk.Stroke]) {
        lastStrokes[index] = strokes
        controller.onDrawingChanged?(index, VectorInk.pkDrawing(from: strokes))   // persist
        if index == activeIndex {
            vectorCanvas.setStrokesPreservingHistory(strokes)
        } else {
            scrollToPage(index, animated: true)   // mount loads the reverted (cached) data
        }
        if containers.indices.contains(index) { renderImage(for: index) }
        controller.refreshUndoState()
    }

    private func persistVector(at index: Int) {
        controller.onDrawingChanged?(index, VectorInk.pkDrawing(from: vectorCanvas.currentStrokes()))
    }

    /// Display → storage, then hand the canonical drawing to the editor to
    /// persist. ALL save paths go through here so Core Data ink is always
    /// canonical regardless of the canvas's current appearance.
    private func persist(_ displayDrawing: PKDrawing, at index: Int) {
        // displayDrawing is the live canvas's drawing (inkScale space) → scale
        // back to canonical page coordinates AND un-adapt appearance.
        controller.onDrawingChanged?(index, canonicalFromCanvas(displayDrawing))
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
        isProgrammaticChange = true
        canvas.drawing = displayIntoCanvas(canonical)
        isProgrammaticChange = false
        lastStrokeCount = canvas.drawing.strokes.count
        for index in containers.indices where index != activeIndex { renderImage(for: index) }
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

    private func renderImage(for index: Int, revealWhenReady: Bool = false, priority: TaskPriority = .utility) {
        guard containers.indices.contains(index),
              let snapshot = controller.snapshotProvider?(index) else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        let container = containers[index]
        let renderScale = imageRenderScale
        // Pre-rasterize ink on the main actor (we're already on main here), then
        // composite off-main with no main hop — the old main.sync inside the
        // detached render stalled under open-note load (black, ink-less pages).
        let ink = PageRenderer.inkLayer(for: snapshot, darkMode: dark, scale: renderScale)
        Task.detached(priority: priority) {
            let image = PageRenderer.render(snapshot, darkMode: dark, scale: renderScale, inkLayer: ink)
            await MainActor.run { [weak self] in
                guard container.pageIndex == index else { return }
                container.imageView.image = image
                if index == self?.activeIndex { self?.activeImageDirty = false }   // cached image now current
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
        let target = CGPoint(x: contentOffset.x, y: min(max(y, 0), maxY))
        if animated {
            // A single consistent ease, continued from the CURRENT (possibly still
            // animating) offset — so rapid chevron taps glide as one smooth motion
            // instead of UIKit restarting its default scroll animation each tap. A
            // finger can interrupt it mid-flight. The live canvas mounts on settle
            // (completion), so taps don't re-mount the ink once per tap.
            UIView.animate(withDuration: 0.32, delay: 0,
                           options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
                self.setContentOffset(target, animated: false)
            } completion: { [weak self] finished in
                if finished { self?.settleActivePage() }
            }
        } else {
            setContentOffset(target, animated: false)
            settleActivePage()
        }
        if controller.currentPageIndex != index {
            DispatchQueue.main.async { [controller] in controller.currentPageIndex = index }
        }
    }

    /// Nudge the vertical scroll by `dy` points, clamped to the content. Returns
    /// the delta actually applied — used for edge auto-scroll while dragging a
    /// media element toward the top/bottom of the screen.
    func autoScroll(by dy: CGFloat) -> CGFloat {
        let minY = -adjustedContentInset.top
        let maxY = max(minY, contentSize.height - bounds.height)
        let target = min(max(contentOffset.y + dy, minY), maxY)
        let actual = target - contentOffset.y
        if actual != 0 {
            contentOffset.y = target
            publishGeometry(sync: true)
        }
        return actual
    }

    /// The page nearest the viewport center (document space).
    private func nearestPageToCenter() -> Int {
        guard !pageFrames.isEmpty, zoomScale > 0 else { return activeIndex }
        let centerY = (contentOffset.y + bounds.height / 2 - documentView.frame.origin.y) / zoomScale
        var nearest = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, frame) in pageFrames.enumerated() {
            if frame.minY...frame.maxY ~= centerY { return index }
            let distance = min(abs(frame.minY - centerY), abs(frame.maxY - centerY))
            if distance < bestDistance { bestDistance = distance; nearest = index }
        }
        return nearest
    }

    /// Mount the live canvas on the page the user SETTLED on — called when a
    /// scroll/zoom stops, NOT on every page crossed mid-scroll. Re-mounting per
    /// crossing (the old behaviour) re-saved + reloaded + alpha-faded the canvas
    /// against each page's cached image, which produced the page-switch hiccups,
    /// the ink flashing/disappearing, and corrupted background renders.
    /// While actively scrolling/zooming, the live CATiledLayer re-renders its tiles on
    /// the CPU every frame (worst zoomed in) — which tanks the scroll. So hide the live
    /// canvas and show the page's already-cached image (the same cheap path inactive
    /// pages use — no per-drag bitmap allocation), then swap the live canvas back in on
    /// settle (it re-renders crisp at the final scale).
    private var scrollImageActive = false
    /// The active page's cached image is stale (edited since its last render). While
    /// stale we must NOT freeze to it (the just-drawn ink would vanish during the scroll);
    /// keep the live canvas until the post-edit refresh lands.
    private var activeImageDirty = false
    private func freezeInkForScroll() {
        guard !scrollImageActive, !activeImageDirty,
              vectorCanvas.isUserInteractionEnabled,   // not mid lasso-selection
              !vectorCanvas.isHidden, vectorCanvas.alpha > 0,
              containers.indices.contains(activeIndex) else { return }
        scrollImageActive = true
        // Show the page's already-cached image (kept fresh after each edit — see
        // vectorCanvasChanged). NO render here: rendering on every drag-start made
        // repeated slides fight the main thread (the scroll hitches + spikes).
        containers[activeIndex].imageView.isHidden = false
        vectorCanvas.isHidden = true
    }
    private func unfreezeInkAfterScroll() {
        guard scrollImageActive else { return }
        scrollImageActive = false
        vectorCanvas.isHidden = false
        if containers.indices.contains(activeIndex) { containers[activeIndex].imageView.isHidden = true }
    }

    private func settleActivePage() {
        unfreezeInkAfterScroll()
        guard !isZooming, !isZoomBouncing else { return }
        // Don't steal the live canvas while the pen is on the page.
        let drawingState = canvas.drawingGestureRecognizer.state
        guard drawingState != .began, drawingState != .changed else { return }
        let nearest = nearestPageToCenter()
        if nearest != activeIndex { activatePage(nearest) }
        if controller.currentPageIndex != nearest || controller.visiblePageIndex != nearest {
            DispatchQueue.main.async { [controller] in
                if controller.currentPageIndex != nearest { controller.currentPageIndex = nearest }
                if controller.visiblePageIndex != nearest { controller.visiblePageIndex = nearest }
            }
        }
    }

    /// `sync` = publish on THIS runloop (no async hop). Use it from scroll/zoom
    /// delegate callbacks so SwiftUI overlays (media, AI bubbles) track the native
    /// page 1:1 instead of lagging a frame — that lag read as the images "floating"
    /// / repositioning while navigating. The `apply` path (inside a SwiftUI view
    /// update) must stay async to avoid publishing changes from within a view update.
    private func publishGeometry(sync: Bool = false) {
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
        let visible = nearestPageToCenter()
        let apply: () -> Void = { [weak controller] in
            guard let controller else { return }
            if controller.zoomScale != zoom { controller.zoomScale = zoom }
            if controller.pageScreenOrigins != origins { controller.pageScreenOrigins = origins }
            if controller.visiblePageIndex != visible { controller.visiblePageIndex = visible }
        }
        if sync { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { documentView }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Only keep the overlays glued to their pages while scrolling. Activating
        // the live canvas is deferred to scrollViewDidEnd* (settleActivePage) so
        // the canvas isn't re-mounted on every page crossed mid-scroll.
        publishGeometry(sync: true)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        freezeInkForScroll()
        PerfMonitor.shared.setActivity("scroll")
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settleActivePage(); PerfMonitor.shared.setActivity("idle") }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleActivePage()
        PerfMonitor.shared.setActivity("idle")
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settleActivePage() }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        freezeInkForScroll()
        PerfMonitor.shared.setActivity("zoom")
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerDocument()
        publishGeometry(sync: true)
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
        PerfMonitor.shared.setActivity("idle")
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
        let baseScale = UIScreen.main.scale

        // A full-page backing store costs w·h·scale²·4 bytes. The old code
        // re-rasterized EVERY page (this loop AND a renderImage pass) at zoom
        // resolution; on a long note (e.g. 13 pages) that allocated hundreds of
        // MB on a single pinch and OOM-hung the app (logs: repeated "failed to
        // allocate 240648256 bytes"). Fix: only the ACTIVE page is re-rasterized
        // at zoom — inactive pages are peripheral when you've zoomed in, so they
        // stay at base screen scale — and every scaled allocation is bounded by a
        // memory budget so it can never blow up regardless of page size.
        func budgetScale(_ size: CGSize, _ mb: CGFloat) -> CGFloat {
            let w = max(size.width, 1), h = max(size.height, 1)
            return (mb * 1_048_576 / (4 * w * h)).squareRoot()
        }
        for (index, container) in containers.enumerated() where index != activeIndex {
            if abs(container.contentScaleFactor - baseScale) > 0.25 {
                container.contentScaleFactor = baseScale
                container.layer.contentsScale = baseScale
                container.imageView.layer.contentsScale = baseScale
                container.setNeedsDisplay()
            }
        }
        // DO NOT bump the live canvas's contentsScale to chase sharper zoom.
        // PROVEN on the iOS 26 SDK (PR #155 added it; PR #159's budget cap made
        // the allocation succeed, which EXPOSED the failure; reverted here):
        // forcing contentsScale on PencilKit's layer tree makes the COMMITTED ink
        // vanish — only the live in-progress stroke renders while the pen is down,
        // everything already drawn disappears. PencilKit owns its own backing
        // store; mutating it out from under PencilKit breaks rendering. So the
        // canvas keeps its default screen-scale rendering: ink is ALWAYS VISIBLE
        // but transform-zoom magnifies it soft past ~1×. Truly sharp deep-zoom
        // ink needs PencilKit-NATIVE zoom (re-tessellation), not a raster bump —
        // see [[studyink-canvas-zoom-ink]]. (inkScale=1 path; supersampling at
        // inkScale>1 reintroduced the offset-under-pen bug, also a dead end.)

        // The active page's BACKGROUND (paper/template/PDF) is drawn by the
        // container's own CGContext — no PencilKit layer tree — so it can render
        // sharper than the 3x ink ceiling without the ink-breakage risk. PDFs
        // are vector, so this keeps them crisp deep into zoom instead of going
        // soft "like an image". Budget-bounded (a 4× full page was ~240 MB and
        // failing to allocate).
        if containers.indices.contains(activeIndex) {
            let active = containers[activeIndex]
            let bg = min(min(max(zoomScale, 1), 4) * baseScale,
                         budgetScale(active.bounds.size, 96))
            if abs(active.contentScaleFactor - bg) > 0.25 {
                active.contentScaleFactor = bg
                active.layer.contentsScale = bg
                // For a PDF page the redraw rasterizes the PDF — warm that cache
                // OFF the main thread first so the on-main draw is just a blit (no
                // zoom hitch). The container draws at min(max(scale,2),4)× width.
                if let snap = controller.snapshotProvider?(activeIndex), let data = snap.customTemplatePDF {
                    let width = snap.pageSize.width * min(max(bg, 2), 4)
                    let dark = controller.isDarkMode
                    Task.detached(priority: .userInitiated) {
                        _ = PDFTemplateRenderer.image(from: data, targetWidth: width, darkMode: dark)
                        await MainActor.run { active.setNeedsDisplay() }
                    }
                } else {
                    active.setNeedsDisplay()
                }
            }
        }
    }
    // NOTE: a "sharp deep-zoom overlay" (rendering the visible ink slice at
    // full zoom resolution over the canvas) was tried here and correlated
    // with ink not rendering at all — removed. Past 3x zoom stays soft until
    // the engine moves to PencilKit-native zooming.


    // MARK: - Native-sharp zoom (permanent supersample)

    /// Size the live canvas to `inkScale`× the page and counter-scale it 1/inkScale
    /// so it still occupies exactly the page in its container — but renders ink
    /// at inkScale resolution. Call wherever the canvas is (re)mounted on a page.
    private func applyCanvasGeometry(pageSize: CGSize) {
        canvas.transform = .identity
        canvas.bounds = CGRect(origin: .zero,
                               size: CGSize(width: pageSize.width * inkScale, height: pageSize.height * inkScale))
        canvas.center = CGPoint(x: pageSize.width / 2, y: pageSize.height / 2)
        if inkScale != 1 {
            canvas.transform = CGAffineTransform(scaleX: 1 / inkScale, y: 1 / inkScale)
        }
    }

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
        // The PK canvas is inert input-wise; the only NON-programmatic changes to its
        // drawing now are lasso-overlay commits (move/resize/rotate/duplicate/insert-
        // space) the editor computes on the projection. Mirror the result back onto the
        // real vector canvas and persist.
        syncVectorFromCanvas()
        let index = activeIndex
        let strokes = vectorCanvas.currentStrokes()
        // Make the lasso edit part of the shared undo history.
        noteUndo.append((index, lastStrokes[index] ?? []))
        if noteUndo.count > 250 { noteUndo.removeFirst() }
        noteRedo.removeAll()
        lastStrokes[index] = strokes
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [controller] in
            controller.onDrawingChanged?(index, VectorInk.pkDrawing(from: strokes))
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        DispatchQueue.main.async { [controller] in controller.refreshUndoState() }
    }

    /// Keep the inert PK canvas's drawing as a DISPLAY+inkScale projection of the live
    /// vector strokes, so the editor's existing lasso pipeline (StrokeSelector +
    /// TransformLassoOverlay, all canvas-space) works unchanged.
    private func syncCanvasProjection() {
        isProgrammaticChange = true
        canvas.drawing = displayIntoCanvas(VectorInk.pkDrawing(from: vectorCanvas.currentStrokes()))
        isProgrammaticChange = false
    }

    /// Mirror the PK projection (after a lasso lift/commit) back onto the vector canvas,
    /// preserving its undo history.
    private func syncVectorFromCanvas() {
        let strokes = VectorInk.strokes(from: canonicalFromCanvas(canvas.drawing))
        vectorCanvas.setStrokesPreservingHistory(strokes)
        // Keep the mount cache in sync so a re-mount mid-lasso (e.g. a small scroll)
        // doesn't reload the ORIGINAL strokes and duplicate the lifted selection.
        lastStrokes[activeIndex] = strokes
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
        // Mid-stroke snapping is off — it cancelled the live touch and ate the ink.
        // The stroke keeps drawing; scheduleShapeRecognition snaps it on lift.
        guard holdSnapEnabled else { return }
        guard controller.autoShapes, controller.toolState.kind.isInking else { return }
        guard var shape = ShapeRecognizer.recognize(points: rawPoints, minDiagonal: 60 * inkScale) else { return }
        if controller.snapToGrid,
           let snapshot = controller.snapshotProvider?(activeIndex),
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
        // Disabling the drawing recognizer cancels the in-flight stroke AND keeps
        // it off through the live-adjust phase — otherwise the still-down pen
        // immediately starts a NEW scribble that fights the node drag. endLiveShape
        // re-enables it on pen-up. (It used to toggle back on right away, which is
        // why "keep moving the pen to adjust" didn't behave.)
        canvas.drawingGestureRecognizer.isEnabled = false

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
                self.activeIndex,
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
        // Always restore drawing (handleHoldSnap left it off for the adjust phase),
        // even on the no-liveShape path, so the pen can draw again.
        canvas.drawingGestureRecognizer.isEnabled = true
        guard let live = liveShape else { return }
        liveShape = nil
        let final = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: canvas) { [original = live.original] target in
            target.drawing = original
        }
        lastStrokeCount = final.strokes.count
        persist(final, at: activeIndex)
        DispatchQueue.main.async { [controller] in controller.refreshUndoState() }
    }

    /// Circle the size of the eraser stroke, following the touch while erasing.
    private let eraserCursor = UIView()
    /// DEBUG: red dot pinned to the raw touch point (Settings → "Pen tracker").
    private let penTracker = UIView()

    /// Show the debug pen marker at the exact touch point so a screen recording
    /// reveals any offset between the pen and the ink. No-op unless the toggle is on.
    private func updatePenTracker(for recognizer: UIGestureRecognizer) {
        guard UserDefaults.standard.bool(forKey: "debug.penTracker") else {
            if !penTracker.isHidden { penTracker.isHidden = true }
            return
        }
        switch recognizer.state {
        case .began, .changed:
            let d = 18 * inkScale
            penTracker.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            penTracker.layer.cornerRadius = d / 2
            penTracker.center = recognizer.location(in: canvas)
            canvas.bringSubviewToFront(penTracker)
            penTracker.isHidden = false
        default:
            penTracker.isHidden = true
        }
    }

    @objc private func drawingGestureMoved(_ recognizer: UIGestureRecognizer) {
        switch recognizer.state {
        case .began:
            // Freeze the scroll geometry for the duration of the stroke. A stroke
            // fires @Published callbacks (undo state, ambient tutor) that re-render
            // the editor; the resulting layout pass recomputed contentInset and
            // recentred the document, sliding the whole page DOWN under the pen and
            // snapping it back on lift. Don't move the page while writing.
            strokeInFlight = true
        case .ended, .cancelled, .failed:
            if strokeInFlight { strokeInFlight = false; setNeedsLayout() }
        default: break
        }
        if recognizer.state == .began {
            // Starting to write dismisses transient chrome: the notes drawer
            // (when the intercept is armed) and the toolbar's color strip.
            if interceptTap?.isEnabled == true { controller.onInterceptedTap?() }
            controller.noteDrawingGestureBegan()
        }
        updatePenTracker(for: recognizer)
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
            // overlay maps them with canvasTransform (and a canvas-scaled snap).
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
        // No shape under the tap — report it in PAGE coordinates so the editor can
        // select/deselect media (unselected media is non-interactive).
        controller.onCanvasFingerTap?(CGPoint(x: location.x / inkScale, y: location.y / inkScale))
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
        persist(drawing, at: activeIndex)
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
        syncVectorFromCanvas()   // hide the lifted strokes on the real vector canvas
        // Take the vector canvas OUT of the touch path so dragging the selection goes
        // to the transform overlay — not a NEW lasso loop (which would zero-commit the
        // selection and drop the strokes back, the "disappears then reappears" bug).
        vectorCanvas.isUserInteractionEnabled = false
    }

    /// Commit the lasso transform onto the original (un-lifted) strokes.
    func commitStrokeSelection(rotation: Double, scale: CGFloat, translation: CGSize, selection: StrokeSelection) {
        guard let original = selectionOriginal else { return }
        selectionOriginal = nil
        vectorCanvas.isUserInteractionEnabled = true   // selection ended → restore draw/lasso input
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
        vectorCanvas.isUserInteractionEnabled = true   // selection ended → restore draw/lasso input
        isProgrammaticChange = true
        canvas.drawing = original
        isProgrammaticChange = false
        lastStrokeCount = original.strokes.count
        syncVectorFromCanvas()   // restore the lifted strokes on the real vector canvas
    }

    /// Delete the selection — the strokes are already lifted out, so just make
    /// that permanent (undoably).
    func deleteStrokeSelection() {
        guard let original = selectionOriginal else { return }
        selectionOriginal = nil
        vectorCanvas.isUserInteractionEnabled = true   // selection ended → restore draw/lasso input
        let lifted = canvas.drawing   // already without the selected strokes
        canvas.undoManager?.registerUndo(withTarget: canvas) { target in target.drawing = original }
        persist(lifted, at: activeIndex)
        DispatchQueue.main.async { [controller] in controller.refreshUndoState() }
    }

    /// Duplicate: commit the current move/rotate/scale onto the originals (so the
    /// item stays where the user dragged it), then add an offset copy.
    func duplicateStrokeSelection(rotation: Double, scale: CGFloat, translation: CGSize, selection: StrokeSelection) {
        guard let original = selectionOriginal else { return }
        selectionOriginal = nil
        vectorCanvas.isUserInteractionEnabled = true   // selection ended → restore draw/lasso input
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
        let yCanvas = pageY * inkScale
        let dy = amount * inkScale
        var strokes = canvas.drawing.strokes
        var changed = false
        for i in strokes.indices where strokes[i].renderBounds.minY > yCanvas {
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
            let target = CGPoint(x: pagePoint.x * inkScale, y: pagePoint.y * inkScale)
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

    // MARK: - Lasso loop capture (pencil)

    /// Enable the pencil lasso gesture only while the lasso tool is selected.
    func setLassoGestureActive(_ active: Bool) {
        lassoPan?.isEnabled = active
        if !active { controller.lassoPoints = [] }
    }

    @objc private func lassoPanned(_ g: UIPanGestureRecognizer) {
        // CANVAS coordinates (inkScale× page space) — the same conversion
        // canvasTapped uses. The editor maps these to screen via the page's
        // canvasTransform for drawing, and feeds them straight to the selector.
        // Reporting in window space drifted off by the safe-area inset on commit.
        let p = g.location(in: canvas)
        switch g.state {
        case .began:
            controller.onLassoBegan?()
            controller.lassoPoints = [p]
        case .changed:
            controller.lassoPoints.append(p)
        case .ended:
            let pts = controller.lassoPoints
            controller.lassoPoints = []
            controller.onLassoComplete?(pts)
        case .cancelled, .failed:
            controller.lassoPoints = []
        default:
            break
        }
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
        // The cached full-page image (shown on inactive pages and during a scroll freeze)
        // already includes the background + imported PDF. Don't re-rasterize the PDF on
        // the MAIN thread underneath it — that main-thread PDF raster, per page revealed,
        // is what tanked sliding through PDF notes. Only draw the background when this
        // page is the live one (image hidden, transparent ink canvas on top).
        if !imageView.isHidden, imageView.image != nil { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        PageRenderer.drawBackground(snapshot, in: cg, darkMode: dark)
        // Hairline seam where stitched ruled pages meet (pages are gapless). A PDF
        // page is a discrete document, not stitched paper — drawing the light seam
        // on a dark-mode PDF rendered it as a glaring white border at the page edge.
        guard snapshot.customTemplatePDF == nil else { return }
        let seam = (UIColor(named: "templateLine") ?? .separator).resolvedColor(with: traitCollection)
        cg.setFillColor(seam.withAlphaComponent(0.3).cgColor)
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
        let dark = colorScheme == .dark
        if controller.isDarkMode != dark {
            // Mutating an @Published HERE (inside a view-update pass) is undefined
            // behavior ("Publishing changes from within view updates") AND its didSet
            // re-renders every page — defer it out of the update.
            DispatchQueue.main.async { [controller] in
                if controller.isDarkMode != dark { controller.isDarkMode = dark }
            }
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
        // "Still" tolerance is generous: samples are in the supersampled canvas
        // space (×4), and a held pencil always jitters a few points — too tight a
        // threshold (it was 2.5 ≈ 0.6pt) kept resetting the timer so the snap
        // never fired. ~12 canvas pts ≈ 3pt of real movement reads as a hold.
        if hypot(location.x - lastLocation.x, location.y - lastLocation.y) > 12 {
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
        // ~0.4s of holding still after drawing some extent → snap (Apple-Notes feel).
        guard !fired, samples.count >= 8,
              Date().timeIntervalSince(lastMoveAt) > 0.4 else { return }
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

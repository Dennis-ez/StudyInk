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
        // Never tear down with unsaved ink on the live canvas.
        if !containers.isEmpty { flushPendingSave() }
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
        container.imageView.isHidden = true
        // The undo stack is per-canvas, not per-page: undoing after a page
        // switch would resurrect the previous page's ink on this one.
        canvas.undoManager?.removeAllActions()
        shapeWorkItem?.cancel()
        lastStrokeCount = canvas.drawing.strokes.count
        DispatchQueue.main.async { [controller] in controller.refreshUndoState() }
    }

    private func activatePage(_ index: Int) {
        guard index != activeIndex, containers.indices.contains(index) else { return }
        flushPendingSave()
        let oldIndex = activeIndex
        if containers.indices.contains(oldIndex) {
            containers[oldIndex].imageView.isHidden = false
            renderImage(for: oldIndex)
        }
        mountCanvas(on: index)
    }

    private func flushPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        controller.onDrawingChanged?(activeIndex, canvas.drawing)
    }

    private func renderImage(for index: Int) {
        guard containers.indices.contains(index),
              let snapshot = controller.snapshotProvider?(index) else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        let container = containers[index]
        Task.detached(priority: .utility) {
            let image = PageRenderer.render(snapshot, darkMode: dark)
            await MainActor.run {
                guard container.pageIndex == index else { return }
                container.imageView.image = image
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
    }

    /// Releasing a pinch near fit-width snaps the page to exactly fill the screen.
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard documentView.frame.width > 0, zoomScale > 0 else { return }
        let fit = bounds.width / (documentView.frame.width / zoomScale)
        if fit >= minimumZoomScale, fit <= maximumZoomScale,
           abs(zoomScale - fit) / fit < 0.12, zoomScale != fit {
            setZoomScale(fit, animated: true)
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
        }
        shapeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
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
    }
}

import SwiftUI
import PencilKit

/// Owns the live PKCanvasView so SwiftUI views (toolbar, editor) can drive
/// undo/redo, tools, and zoom without fighting the representable lifecycle.
final class CanvasController: NSObject, ObservableObject {
    @Published var toolState: ToolState {
        didSet {
            applyTool()
            rememberCurrentTool()
        }
    }
    @Published var isRulerActive = false {
        didSet { canvasView?.isRulerActive = isRulerActive }
    }
    /// true = Apple Pencil only (palm rejection via system); false = finger drawing allowed.
    @Published var pencilOnly = true {
        didSet { canvasView?.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput }
    }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var zoomScale: CGFloat = 1
    @Published var contentOffset: CGPoint = .zero

    var isDarkMode = false {
        didSet { applyTool() }
    }

    /// Per-tool settings (color/width/opacity remembered separately for each
    /// pen, the highlighter, the pencil, …), persisted across launches.
    private var savedTools: [String: ToolState]

    /// Remembered tool for Apple Pencil double-tap eraser toggle.
    private var toolBeforeEraser: ToolKind?

    weak var canvasView: PKCanvasView?
    var onDrawingChanged: ((PKDrawing) -> Void)?
    var onStroke: ((PKStroke) -> Void)?
    /// Fired when the Apple Pencil is held still on the canvas for ~1s (ask gesture).
    var onPencilHold: (() -> Void)?
    /// Fired when the user drags past the page's top/bottom edge (-1 = previous, +1 = next).
    var onPageOverscroll: ((Int) -> Void)?

    override init() {
        if let data = UserDefaults.standard.data(forKey: "tools.perKind"),
           let saved = try? JSONDecoder().decode([String: ToolState].self, from: data) {
            savedTools = saved
        } else {
            savedTools = [:]
        }
        toolState = savedTools[ToolKind.ballpoint.rawValue] ?? ToolState()
        super.init()
    }

    /// Switch tools, restoring that tool's own remembered color/width/opacity.
    func select(_ kind: ToolKind) {
        guard kind != toolState.kind else { return }
        var next = savedTools[kind.rawValue] ?? toolState
        next.kind = kind
        toolState = next
    }

    private func rememberCurrentTool() {
        savedTools[toolState.kind.rawValue] = toolState
        if let data = try? JSONEncoder().encode(savedTools) {
            UserDefaults.standard.set(data, forKey: "tools.perKind")
        }
    }

    func attach(_ canvas: PKCanvasView) {
        canvasView = canvas
        applyTool()
        canvas.isRulerActive = isRulerActive
        canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
    }

    func applyTool() {
        canvasView?.tool = toolState.pkTool(darkMode: isDarkMode)
    }

    func undo() { canvasView?.undoManager?.undo(); refreshUndoState() }
    func redo() { canvasView?.undoManager?.redo(); refreshUndoState() }

    func refreshUndoState() {
        let undo = canvasView?.undoManager?.canUndo ?? false
        let redo = canvasView?.undoManager?.canRedo ?? false
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
    }

    func toggleEraser() {
        if toolState.kind.isInking || toolState.kind == .lasso {
            toolBeforeEraser = toolState.kind
            select(.eraserPixel)
        } else {
            select(toolBeforeEraser ?? .ballpoint)
            toolBeforeEraser = nil
        }
    }
}

/// PKCanvasView wrapper: pressure/tilt come free from PencilKit; this layer adds
/// page sizing, zoom limits, change persistence, and Pencil 2 double-tap support.
struct PencilCanvasView: UIViewRepresentable {
    @ObservedObject var controller: CanvasController
    let drawing: PKDrawing
    let pageSize: CGSize
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.contentSize = pageSize
        canvas.minimumZoomScale = 0.5
        canvas.maximumZoomScale = 5
        canvas.bouncesZoom = true
        canvas.alwaysBounceVertical = true
        canvas.contentInsetAdjustmentBehavior = .never

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        canvas.addInteraction(pencilInteraction)

        // Circle & Ask trigger: hold the Pencil still for 1s to arm the ask-lasso.
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pencilHeld(_:)))
        hold.minimumPressDuration = 1.0
        hold.allowableMovement = 8
        hold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hold.delegate = context.coordinator
        canvas.addGestureRecognizer(hold)
        context.coordinator.holdRecognizer = hold

        context.coordinator.observeKeyboard(for: canvas)

        controller.isDarkMode = colorScheme == .dark
        controller.attach(canvas)
        DispatchQueue.main.async { [weak coordinator = context.coordinator, weak canvas] in
            guard let canvas else { return }
            coordinator?.centerContent(canvas)
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if controller.isDarkMode != (colorScheme == .dark) {
            controller.isDarkMode = colorScheme == .dark
        }
        // Only push the model drawing in when it differs (e.g. page switch) —
        // never clobber in-flight strokes. The programmatic flag stops the
        // delegate from treating this as a user edit mid view-update.
        if context.coordinator.lastPushedDrawing != drawing {
            context.coordinator.isProgrammaticChange = true
            context.coordinator.lastPushedDrawing = drawing
            canvas.drawing = drawing
            context.coordinator.isProgrammaticChange = false
        }
        if canvas.contentSize != pageSize { canvas.contentSize = pageSize }
        context.coordinator.centerContent(canvas)
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
        let controller: CanvasController
        var lastPushedDrawing: PKDrawing?
        var isProgrammaticChange = false
        weak var holdRecognizer: UILongPressGestureRecognizer?
        private weak var observedCanvas: PKCanvasView?
        private var saveWorkItem: DispatchWorkItem?
        private var keyboardObservers: [NSObjectProtocol] = []

        init(controller: CanvasController) {
            self.controller = controller
        }

        deinit {
            keyboardObservers.forEach(NotificationCenter.default.removeObserver)
        }

        /// While any keyboard is up, suspend the drawing + pencil-hold recognizers.
        /// iPadOS's Scribble/handwriting daemon otherwise fights the canvas for the
        /// text-input session ("Result accumulator timeout … exceeded"), freezing
        /// the app for ~3s whenever a text field gains focus.
        func observeKeyboard(for canvas: PKCanvasView) {
            observedCanvas = canvas
            let center = NotificationCenter.default
            keyboardObservers = [
                center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.setDrawingSuspended(true)
                },
                center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.setDrawingSuspended(false)
                },
            ]
        }

        private func setDrawingSuspended(_ suspended: Bool) {
            observedCanvas?.drawingGestureRecognizer.isEnabled = !suspended
            holdRecognizer?.isEnabled = !suspended
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Programmatic pushes (page switch in updateUIView) arrive while
            // SwiftUI is mid-update — publishing or saving here would loop.
            guard !isProgrammaticChange else { return }
            let drawing = canvasView.drawing
            lastPushedDrawing = drawing
            DispatchQueue.main.async { [controller] in
                controller.refreshUndoState()
                if let stroke = drawing.strokes.last {
                    controller.onStroke?(stroke)
                }
            }
            // Auto-save on every stroke, debounced so fast writing batches into one store write.
            saveWorkItem?.cancel()
            let work = DispatchWorkItem { [controller] in
                controller.onDrawingChanged?(drawing)
            }
            saveWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        // Scroll/zoom callbacks fire synchronously during UIKit layout, which can
        // happen inside a SwiftUI view update — defer the publish one runloop turn.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let offset = scrollView.contentOffset
            DispatchQueue.main.async { [weak controller] in
                guard let controller, controller.contentOffset != offset else { return }
                controller.contentOffset = offset
            }
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(scrollView)
            let scale = scrollView.zoomScale
            DispatchQueue.main.async { [weak controller] in
                guard let controller, controller.zoomScale != scale else { return }
                controller.zoomScale = scale
            }
        }

        /// Keeps the page centered when it's smaller than the viewport (PencilKit
        /// only accepts ink inside the content area, so without this the page
        /// hugs the top-left and the rest of the screen is dead space).
        func centerContent(_ scrollView: UIScrollView) {
            let dx = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
            let dy = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
            let insets = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
            if scrollView.contentInset != insets {
                scrollView.contentInset = insets
            }
        }

        /// Dragging well past the page's top or bottom edge flows to the
        /// neighboring page — continuous vertical reading across the note.
        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            let threshold: CGFloat = 70
            let insets = scrollView.adjustedContentInset
            let minOffsetY = -insets.top
            let maxOffsetY = max(minOffsetY, scrollView.contentSize.height + insets.bottom - scrollView.bounds.height)
            let offsetY = scrollView.contentOffset.y
            var direction = 0
            if offsetY < minOffsetY - threshold {
                direction = -1
            } else if offsetY > maxOffsetY + threshold {
                direction = 1
            }
            guard direction != 0 else { return }
            DispatchQueue.main.async { [weak controller] in
                controller?.onPageOverscroll?(direction)
            }
        }

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            guard UIPencilInteraction.preferredTapAction == .switchEraser else { return }
            controller.toggleEraser()
        }

        @objc func pencilHeld(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            controller.onPencilHold?()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

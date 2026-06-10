import SwiftUI
import PencilKit

/// Owns the live PKCanvasView so SwiftUI views (toolbar, editor) can drive
/// undo/redo, tools, and zoom without fighting the representable lifecycle.
final class CanvasController: NSObject, ObservableObject {
    @Published var toolState = ToolState() {
        didSet { applyTool() }
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

    /// Remembered tool for Apple Pencil double-tap eraser toggle.
    private var toolBeforeEraser: ToolState?

    weak var canvasView: PKCanvasView?
    var onDrawingChanged: ((PKDrawing) -> Void)?
    var onStroke: ((PKStroke) -> Void)?
    /// Fired when the Apple Pencil is held still on the canvas for ~1s (ask gesture).
    var onPencilHold: (() -> Void)?

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
        canUndo = canvasView?.undoManager?.canUndo ?? false
        canRedo = canvasView?.undoManager?.canRedo ?? false
    }

    func toggleEraser() {
        if toolState.kind.isInking || toolState.kind == .lasso {
            toolBeforeEraser = toolState
            toolState.kind = .eraserPixel
        } else if let previous = toolBeforeEraser {
            toolState = previous
            toolBeforeEraser = nil
        } else {
            toolState.kind = .ballpoint
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

        controller.isDarkMode = colorScheme == .dark
        controller.attach(canvas)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        controller.isDarkMode = colorScheme == .dark
        // Only push the model drawing in when it differs (e.g. page switch) —
        // never clobber in-flight strokes.
        if context.coordinator.lastPushedDrawing != drawing {
            context.coordinator.lastPushedDrawing = drawing
            canvas.drawing = drawing
        }
        if canvas.contentSize != pageSize { canvas.contentSize = pageSize }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
        let controller: CanvasController
        var lastPushedDrawing: PKDrawing?
        private var saveWorkItem: DispatchWorkItem?

        init(controller: CanvasController) {
            self.controller = controller
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            controller.refreshUndoState()
            if let stroke = canvasView.drawing.strokes.last {
                controller.onStroke?(stroke)
            }
            lastPushedDrawing = canvasView.drawing
            // Auto-save on every stroke, debounced so fast writing batches into one store write.
            saveWorkItem?.cancel()
            let drawing = canvasView.drawing
            let work = DispatchWorkItem { [controller] in
                controller.onDrawingChanged?(drawing)
            }
            saveWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            controller.contentOffset = scrollView.contentOffset
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            controller.zoomScale = scrollView.zoomScale
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

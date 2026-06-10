import SwiftUI
import PencilKit

/// Owns the live canvas state so SwiftUI views (toolbar, editor, overlays) can
/// drive tools, zoom, paging, and undo/redo without fighting the UIKit engine.
/// The document engine (NoteCanvasEngine) reports scroll/zoom/page geometry
/// here; overlays read per-page transforms back out.
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
        didSet {
            canvasView?.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
            // With finger drawing on, one-finger drags must ink, not scroll.
            engine?.panGestureRecognizer.minimumNumberOfTouches = pencilOnly ? 1 : 2
        }
    }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    // MARK: Geometry published by the engine

    @Published var zoomScale: CGFloat = 1
    /// Screen-space origin of every page (editor coordinates), updated as the
    /// document scrolls/zooms. Overlays anchor to their page through these.
    @Published var pageScreenOrigins: [CGPoint] = []
    /// The page under the viewport center; the live canvas follows it.
    @Published var currentPageIndex = 0

    var isDarkMode = false {
        didSet { applyTool() }
    }

    /// Per-tool settings (color/width/opacity remembered separately for each
    /// pen, the highlighter, the pencil, …), persisted across launches.
    private var savedTools: [String: ToolState]

    /// Remembered tool for Apple Pencil double-tap eraser toggle.
    private var toolBeforeEraser: ToolKind?

    /// The live PKCanvasView (hosted on the active page by the engine).
    weak var canvasView: PKCanvasView?
    /// The engine, for commands like scroll-to-page.
    weak var engine: DocumentScrollView?

    // MARK: Callbacks into SwiftUI

    var onDrawingChanged: ((Int, PKDrawing) -> Void)?
    var onStroke: ((Int, PKStroke) -> Void)?
    /// Fired when the Apple Pencil is held still on the canvas for ~1s (ask gesture).
    var onPencilHold: (() -> Void)?
    /// Tapping the trailing "add page" affordance.
    var onAddPage: (() -> Void)?
    /// The engine pulls page content through these (set by the editor).
    var drawingProvider: ((Int) -> PKDrawing)?
    var snapshotProvider: ((Int) -> PageRenderer.Snapshot?)?

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

    /// Maps page-space points of `pageIndex` into editor screen space.
    func transform(forPage pageIndex: Int) -> CanvasTransform {
        let origin = pageScreenOrigins.indices.contains(pageIndex) ? pageScreenOrigins[pageIndex] : .zero
        return CanvasTransform(zoomScale: zoomScale, contentOffset: CGPoint(x: -origin.x, y: -origin.y))
    }

    func scrollToPage(_ index: Int, animated: Bool = true) {
        engine?.scrollToPage(index, animated: animated)
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

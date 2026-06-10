import SwiftUI
import PencilKit

/// The main editing surface: one page of ink + text boxes, the floating toolbar,
/// and (from later phases) template backgrounds, media, and AI overlays.
struct NoteEditorView: View {
    @ObservedObject var note: Note
    @StateObject private var canvasController = CanvasController()
    @State private var pageIndex = 0
    @State private var textBoxes: [TextBoxModel] = []
    @State private var editingBoxID: UUID?
    @State private var distractionFree = false
    @Environment(\.managedObjectContext) private var context

    private var currentPage: Page? {
        let pages = note.sortedPages
        guard pages.indices.contains(pageIndex) else { return pages.first }
        return pages[pageIndex]
    }

    private var pageSize: CGSize { PageSize.from(id: currentPage?.pageSizeID).size }

    var body: some View {
        ZStack {
            Color("canvasBackground").ignoresSafeArea()

            if let page = currentPage {
                PencilCanvasView(
                    controller: canvasController,
                    drawing: page.drawing,
                    pageSize: pageSize
                )
                .ignoresSafeArea(edges: .bottom)

                TextBoxLayer(
                    boxes: $textBoxes,
                    transform: CanvasTransform(
                        zoomScale: canvasController.zoomScale,
                        contentOffset: canvasController.contentOffset
                    ),
                    editingBoxID: $editingBoxID
                )
                .allowsHitTesting(editingBoxID != nil || !textBoxes.isEmpty)
            }

            if !distractionFree {
                FloatingToolbar(
                    controller: canvasController,
                    onInsertTextBox: insertTextBox,
                    extraItems: [
                        ToolbarExtraItem(id: "fullscreen", symbolName: "arrow.up.left.and.arrow.down.right", labelKey: "editor.fullscreen") {
                            withAnimation { distractionFree = true }
                        }
                    ]
                )
            }

            if let editingID = editingBoxID,
               let boxIndex = textBoxes.firstIndex(where: { $0.id == editingID }) {
                VStack {
                    Spacer()
                    TextBoxStyleBar(box: $textBoxes[boxIndex])
                        .padding(.bottom, 16)
                }
            }

            if distractionFree {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation { distractionFree = false }
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .padding(10)
                                .background(.regularMaterial, in: Circle())
                        }
                        .padding()
                        .accessibilityLabel(Text("editor.exitFullscreen"))
                    }
                    Spacer()
                }
            }
        }
        .navigationTitle(note.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(distractionFree ? .hidden : .automatic, for: .navigationBar)
        .statusBarHidden(distractionFree)
        .onAppear(perform: loadPage)
        .onChange(of: pageIndex) { saveTextBoxes(); loadPage() }
        .onChange(of: textBoxes) { saveTextBoxes() }
        .onDisappear { saveTextBoxes(); PersistenceController.shared.save() }
        .task {
            canvasController.onDrawingChanged = { [weak note] drawing in
                guard let note else { return }
                let pages = note.sortedPages
                guard pages.indices.contains(pageIndex) else { return }
                pages[pageIndex].drawing = drawing
                note.searchableText = SearchableTextBuilder.build(for: note)
                PersistenceController.shared.save()
            }
        }
    }

    private func loadPage() {
        textBoxes = currentPage?.textBoxes ?? []
        editingBoxID = nil
    }

    private func saveTextBoxes() {
        guard let page = currentPage, page.textBoxes != textBoxes else { return }
        page.textBoxes = textBoxes
        PersistenceController.shared.save()
    }

    /// Drops a new text box at the center of the visible canvas region.
    private func insertTextBox() {
        let transform = CanvasTransform(
            zoomScale: canvasController.zoomScale,
            contentOffset: canvasController.contentOffset
        )
        let screenCenter = CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY)
        let pagePoint = transform.toPage(screenCenter)
        var box = TextBoxModel(x: pagePoint.x - 130, y: pagePoint.y - 30)
        box.colorHex = canvasController.toolState.colorHex
        textBoxes.append(box)
        editingBoxID = box.id
    }
}

/// Aggregates typed text (and later OCR) into Note.searchableText for library search.
enum SearchableTextBuilder {
    static func build(for note: Note) -> String {
        var parts: [String] = [note.title ?? ""]
        for page in note.sortedPages {
            parts.append(contentsOf: page.textBoxes.map(\.text))
            if let ocr = page.ocrText { parts.append(ocr) }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

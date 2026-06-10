import SwiftUI
import PencilKit
import PhotosUI
import UniformTypeIdentifiers

/// The main editing surface: template background + media + ink + text boxes,
/// the floating toolbar, page navigation, and (phase 5+) AI overlays.
struct NoteEditorView: View {
    @ObservedObject var note: Note
    @StateObject private var canvasController = CanvasController()
    @State private var pageIndex = 0
    @State private var textBoxes: [TextBoxModel] = []
    @State private var mediaItems: [MediaItemModel] = []
    @State private var editingBoxID: UUID?
    @State private var selectedMediaID: UUID?
    @State private var distractionFree = false
    @State private var showPageStrip = true
    @State private var showPageSettings = false
    @State private var showStickers = false
    @State private var showCamera = false
    @State private var showScanner = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var importingPDF = false
    @State private var ocrTask: Task<Void, Never>?
    @State private var overlaySaveTask: Task<Void, Never>?
    @StateObject private var tutor = AITutorController()
    @StateObject private var guidedMode = GuidedModeController()
    @StateObject private var audio = AudioSyncController()
    @State private var showAskField = false
    @State private var askText = ""
    @State private var lastStrokeAnchor: CGPoint?
    @State private var askLassoActive = false
    @State private var circleAskRegion: CGRect?
    @Environment(\.managedObjectContext) private var context
    @Environment(\.colorScheme) private var colorScheme

    private var currentPage: Page? {
        let pages = note.sortedPages
        guard pages.indices.contains(pageIndex) else { return pages.first }
        return pages[pageIndex]
    }

    private var pageSize: CGSize { PageSize.from(id: currentPage?.pageSizeID).size }

    private var transform: CanvasTransform {
        CanvasTransform(zoomScale: canvasController.zoomScale, contentOffset: canvasController.contentOffset)
    }

    var body: some View {
        ZStack {
            Color("canvasBackground").ignoresSafeArea()

            if let page = currentPage {
                TemplateBackgroundView(
                    template: page.template,
                    pageSize: pageSize,
                    transform: transform,
                    customPDFData: page.customTemplatePDF
                )

                MediaLayer(items: $mediaItems, transform: transform, selectedItemID: $selectedMediaID)

                PencilCanvasView(controller: canvasController, drawing: page.drawing, pageSize: pageSize)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(selectedMediaID == nil)

                TextBoxLayer(boxes: $textBoxes, transform: transform, editingBoxID: $editingBoxID)

                // AI canvas annotations + response bubbles (non-destructive overlays).
                ForEach(tutor.visibleBubbles) { bubble in
                    AnnotationOverlay(
                        annotations: bubble.annotations,
                        bubbleOrigin: CGPoint(x: bubble.x, y: bubble.y + 60),
                        transform: transform
                    )
                }
                ForEach(tutor.visibleBubbles) { bubble in
                    AIBubbleView(
                        bubble: bubble,
                        isLoading: tutor.loadingBubbleIDs.contains(bubble.id),
                        transform: transform,
                        tutor: tutor,
                        onInsertTextBox: { textBoxes.append($0) }
                    )
                }
            }

            if selectedMediaID != nil {
                // Tap-through catcher to deselect media and resume drawing.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selectedMediaID = nil }
                    .allowsHitTesting(false)
            }

            // Audio playback tap-to-seek: tap any written mark to jump the recording
            // to the moment it was written.
            if audio.isPlaying, let recording = audio.activeRecording {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let pagePoint = transform.toPage(location)
                        if let time = audio.time(near: pagePoint, pageIndex: pageIndex, in: recording) {
                            audio.seek(to: time)
                        }
                    }
            }

            if !distractionFree {
                FloatingToolbar(
                    controller: canvasController,
                    onInsertTextBox: insertTextBox,
                    extraItems: toolbarExtras
                )

                VStack(spacing: 8) {
                    Spacer()
                    AudioBar(audio: audio, note: note)
                    if showPageStrip {
                        PageNavigatorStrip(note: note, currentIndex: $pageIndex)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
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
                exitDistractionFreeButton
            }

            // Circle & Ask lasso capture layer.
            AskLassoOverlay(isActive: $askLassoActive, transform: transform) { region in
                circleAskRegion = region
            }

            // Guided-mode bottom suggestion card (auto-dismisses after 8s).
            if let suggestion = guidedMode.suggestion {
                VStack {
                    Spacer()
                    GuidedSuggestionCard(
                        suggestion: suggestion,
                        onAccept: { guidedMode.accept(suggestion) },
                        onDismiss: { withAnimation { guidedMode.suggestion = nil } }
                    )
                    .padding(.bottom, showPageStrip ? 130 : 30)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Side AI panel (secondary surface for long explanations + history).
            if tutor.panelOpen {
                HStack {
                    Spacer()
                    AIPanelView(tutor: tutor)
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationTitle(note.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
        .toolbar(distractionFree ? .hidden : .automatic, for: .navigationBar)
        .statusBarHidden(distractionFree)
        .onAppear {
            loadPage()
            tutor.attach(note: note)
            tutor.isDarkMode = colorScheme == .dark
            guidedMode.tutor = tutor
            audio.attach(note: note)
            canvasController.onStroke = { stroke in
                let center = CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY)
                lastStrokeAnchor = center
                audio.logStroke(at: center, pageIndex: pageIndex)
            }
            canvasController.onPencilHold = {
                withAnimation { askLassoActive = true }
            }
        }
        .onChange(of: colorScheme) { tutor.isDarkMode = colorScheme == .dark }
        .onChange(of: pageIndex) {
            persistOverlays()
            loadPage()
            tutor.pageChanged(to: pageIndex)
            guidedMode.pageTurned()
        }
        .onChange(of: textBoxes) { scheduleOverlaySave() }
        .onChange(of: mediaItems) { scheduleOverlaySave() }
        .onDisappear {
            persistOverlays()
            if audio.isRecording { audio.stopRecording() }
            audio.stopPlayback()
            PersistenceController.shared.save()
        }
        .task { wireCanvasSave() }
        .sheet(isPresented: $showPageSettings) {
            if let page = currentPage { PageSettingsSheet(page: page) }
        }
        .sheet(isPresented: $showStickers) {
            StickerLibrarySheet { image in insert(image: image, kind: .sticker) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in insert(image: image, kind: .image) }
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView { images in
                for image in images { insert(image: image, kind: .image) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItem, matching: .images)
        .onChange(of: photoPickerItem) { loadPickedPhoto() }
        .fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { importPDF(from: url) }
        }
        .dropDestination(for: Data.self) { items, location in
            for data in items where UIImage(data: data) != nil {
                insert(imageData: data, at: transform.toPage(location))
            }
            return true
        }
        .alert(Text("ai.ask"), isPresented: $showAskField) {
            TextField("ai.askPlaceholder", text: $askText)
            Button("action.cancel", role: .cancel) { askText = "" }
            Button("ai.send") { sendAsk() }
        } message: {
            Text("ai.askHint")
        }
        .sheet(isPresented: circleAskBinding) {
            if let region = circleAskRegion {
                CircleAskSheet(region: region) { question in
                    sendCircleAsk(question: question, region: region)
                }
            }
        }
        .alert(Text("ai.error"), isPresented: aiErrorBinding) {
            Button("action.done", role: .cancel) { tutor.errorMessage = nil }
        } message: {
            Text(tutor.errorMessage ?? "")
        }
    }

    private var aiErrorBinding: Binding<Bool> {
        Binding(get: { tutor.errorMessage != nil }, set: { if !$0 { tutor.errorMessage = nil } })
    }

    private var circleAskBinding: Binding<Bool> {
        Binding(get: { circleAskRegion != nil }, set: { if !$0 { circleAskRegion = nil } })
    }

    /// Circle & Ask submit: crop the circled region from a fresh page render and
    /// send it with the question; the bubble anchors to the circled content.
    private func sendCircleAsk(question: String, region: CGRect) {
        guard let page = currentPage else { return }
        let crop = croppedImage(of: region, page: page)
        let anchor = CGPoint(x: region.midX, y: region.midY)
        circleAskRegion = nil
        Task {
            await tutor.ask(question: question, anchor: anchor, focusRegion: region, focusImage: crop)
        }
    }

    private func croppedImage(of region: CGRect, page: Page) -> UIImage? {
        let full = PageRenderer.image(for: page, darkMode: colorScheme == .dark)
        guard let cg = full.cgImage else { return nil }
        let pixelScale = CGFloat(cg.width) / max(full.size.width, 1)
        let pixelRect = CGRect(
            x: region.minX * pixelScale, y: region.minY * pixelScale,
            width: region.width * pixelScale, height: region.height * pixelScale
        ).intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !pixelRect.isEmpty, let cropped = cg.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: cropped)
    }

    private func sendAsk() {
        let question = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        askText = ""
        guard !question.isEmpty else { return }
        let anchor = askAnchor
        Task { await tutor.ask(question: question, anchor: anchor) }
    }

    // MARK: - Toolbar

    private var toolbarExtras: [ToolbarExtraItem] {
        [
            ToolbarExtraItem(id: "ask-ai", symbolName: "sparkles", labelKey: "ai.ask") {
                showAskField = true
            },
            ToolbarExtraItem(id: "ai-history", symbolName: "bubble.left.and.text.bubble.right", labelKey: "ai.history") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    tutor.panelBubbleID = nil
                    tutor.panelOpen.toggle()
                }
            },
            ToolbarExtraItem(id: "fullscreen", symbolName: "arrow.up.left.and.arrow.down.right", labelKey: "editor.fullscreen") {
                withAnimation { distractionFree = true }
            }
        ]
    }

    /// Anchor for typed questions: the last pen stroke, falling back to viewport center.
    private var askAnchor: CGPoint {
        lastStrokeAnchor ?? transform.toPage(CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY * 0.6))
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button {
                    withAnimation { askLassoActive = true }
                } label: { Label("ai.circleAsk.title", systemImage: "lasso.badge.sparkles") }

                Button {
                    Task { await tutor.explainCurrentPage() }
                } label: { Label("ai.explainPage", systemImage: "doc.text.magnifyingglass") }

                Button {
                    Task { await tutor.startQuiz() }
                } label: { Label("ai.quizMe", systemImage: "questionmark.app") }

                Toggle(isOn: $guidedMode.isEnabled) {
                    Label("ai.guidedMode", systemImage: "lightbulb")
                }
            } label: {
                Image(systemName: "sparkles")
            }
            .accessibilityLabel(Text("ai.menu"))

            SubjectContextMenu(note: note)

            Menu {
                Button { showPhotoPicker = true } label: { Label("media.photo", systemImage: "photo") }
                Button { showCamera = true } label: { Label("media.camera", systemImage: "camera") }
                Button { showScanner = true } label: { Label("media.scan", systemImage: "doc.viewfinder") }
                Button { showStickers = true } label: { Label("media.stickers", systemImage: "face.smiling") }
                Button { importingPDF = true } label: { Label("media.importPDF", systemImage: "doc.badge.plus") }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(Text("media.insert"))

            Menu {
                ShareLink(
                    item: PDFExportFile(note: note),
                    preview: SharePreview(note.title ?? "StudyInk")
                ) {
                    Label("export.pdf", systemImage: "doc.richtext")
                }
                if let page = currentPage {
                    ShareLink(
                        item: PNGExportFile(page: page),
                        preview: SharePreview(note.title ?? "StudyInk")
                    ) {
                        Label("export.png", systemImage: "photo")
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel(Text("export.share"))

            Button { showPageSettings = true } label: { Image(systemName: "doc.badge.gearshape") }
                .accessibilityLabel(Text("page.settings"))

            Button {
                withAnimation { showPageStrip.toggle() }
            } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
            }
            .accessibilityLabel(Text("page.toggleStrip"))
        }
    }

    private var exitDistractionFreeButton: some View {
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

    // MARK: - Page lifecycle

    private func loadPage() {
        textBoxes = currentPage?.textBoxes ?? []
        mediaItems = currentPage?.mediaItems ?? []
        editingBoxID = nil
        selectedMediaID = nil
    }

    /// Typing in a text box mutates state on every keystroke; encoding JSON,
    /// rebuilding the note's search text, and hitting Core Data each time
    /// stalls the main thread (worst right as the keyboard animates in).
    /// Coalesce to one save shortly after edits go quiet.
    private func scheduleOverlaySave() {
        overlaySaveTask?.cancel()
        overlaySaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            persistOverlays()
        }
    }

    private func persistOverlays() {
        overlaySaveTask?.cancel()
        guard let page = currentPage else { return }
        if page.textBoxes != textBoxes { page.textBoxes = textBoxes }
        if page.mediaItems != mediaItems { page.mediaItems = mediaItems }
        note.searchableText = SearchableTextBuilder.build(for: note)
        PersistenceController.shared.save()
    }

    private func wireCanvasSave() {
        canvasController.onDrawingChanged = { [weak note] drawing in
            guard let note else { return }
            let pages = note.sortedPages
            guard pages.indices.contains(pageIndex) else { return }
            pages[pageIndex].drawing = drawing
            note.searchableText = SearchableTextBuilder.build(for: note)
            PersistenceController.shared.save()
            scheduleOCR(for: pages[pageIndex])
        }
    }

    /// Re-indexes handwriting a few seconds after the pen goes quiet, keeping
    /// search (and AI targeting) fresh without OCR-ing every stroke.
    private func scheduleOCR(for page: Page) {
        ocrTask?.cancel()
        ocrTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await OCRService.indexPage(page)
        }
    }

    // MARK: - Insertion

    private func insertTextBox() {
        let pagePoint = transform.toPage(CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY))
        var box = TextBoxModel(x: pagePoint.x - 130, y: pagePoint.y - 30)
        box.colorHex = canvasController.toolState.colorHex
        textBoxes.append(box)
        editingBoxID = box.id
    }

    private func insert(image: UIImage, kind: MediaItemModel.Kind) {
        guard let data = image.pngData() else { return }
        insert(imageData: data, kind: kind)
    }

    private func insert(imageData: Data, kind: MediaItemModel.Kind = .image, at point: CGPoint? = nil) {
        guard let image = UIImage(data: imageData),
              let fileName = MediaStore.save(imageData) else { return }
        let maxSide: CGFloat = kind == .sticker ? 120 : 360
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let center = point ?? transform.toPage(CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY))
        let item = MediaItemModel(
            kind: kind,
            fileName: fileName,
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        mediaItems.append(item)
        selectedMediaID = item.id
    }

    private func loadPickedPhoto() {
        guard let item = photoPickerItem else { return }
        photoPickerItem = nil
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                await MainActor.run { insert(imageData: data) }
            }
        }
    }

    private func importPDF(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        PDFImporter.importAsPages(data: data, into: note, after: Int32(pageIndex))
        PersistenceController.shared.save()
        pageIndex += 1
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

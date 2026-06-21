import SwiftUI
import PencilKit
import PhotosUI
import UniformTypeIdentifiers

/// The main editing surface: template background + media + ink + text boxes,
/// the floating toolbar, page navigation, and (phase 5+) AI overlays.
struct NoteEditorView: View {
    @ObservedObject var note: Note
    /// Asks the hosting container to swap the open note (left-edge notes pane).
    var onSwitchNote: (Note) -> Void = { _ in }
    @StateObject private var canvasController = CanvasController()
    @State private var pageIndex = 0
    @State private var textBoxes: [TextBoxModel] = []
    @State private var mediaItems: [MediaItemModel] = []
    @State private var editingBoxID: UUID?
    @State private var selectedMediaID: UUID?
    @State private var distractionFree = false
    @State private var showPageStrip = false
    /// Debounce for the ambient ghost suggestion (fires when the pen goes idle).
    @State private var ghostIdleTask: Task<Void, Never>?
    /// 0 = closed, 1 = notes pane, 2 = notes pane + subjects sidebar.
    @State private var drawerStage = 0
    /// Subject chosen in the drawer's subjects pane (.some(nil) = All Notes).
    @State private var drawerSubject: Subject?? = nil
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showRecorderPopover = false
    @State private var showAISketchPrompt = false
    @State private var aiSketchText = ""
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
    @StateObject private var quiz = QuizController()
    /// Ambient Tutor — the margin lane + glyphs (Marginalia design).
    @StateObject private var ambient = AmbientTutorController()
    @StateObject private var audio = AudioSyncController()
    @State private var showAskField = false
    @State private var askText = ""
    @State private var showAIDrawPrompt = false
    @State private var aiDrawText = ""
    @State private var lastStrokeAnchor: CGPoint?
    @State private var askLassoActive = false
    @State private var showGuidedLog = false
    @State private var transformLassoActive = false
    /// Page-space point of a pending finger-tap "Paste" affordance (ink clipboard).
    @State private var pastePoint: CGPoint?
    @State private var strokeSelection: StrokeSelection?
    @State private var strokeRotation: Double = 0
    @State private var strokeTranslation: CGSize = .zero
    @State private var strokeScale: CGFloat = 1
    @State private var editingShape: EditingShape?
    @State private var circleAskRegion: CGRect?
    @Environment(\.managedObjectContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePaper) private var themePaper
    @Environment(\.themeDesk) private var themeDesk
    @Environment(\.aiAccent) private var aiAccent

    private var currentPage: Page? {
        let pages = note.sortedPages
        guard pages.indices.contains(pageIndex) else { return pages.first }
        return pages[pageIndex]
    }

    private var pageSize: CGSize { currentPage?.canvasSize ?? PageSize.letter.size }

    private var transform: CanvasTransform {
        canvasController.transform(forPage: pageIndex)
    }

    /// Engine rebuilds the page stack when this changes (count/size/template).
    private var layoutSignature: String {
        note.sortedPages.map {
            "\($0.id?.uuidString ?? "?")|\(Int($0.canvasSize.width))x\(Int($0.canvasSize.height))|\($0.templateID ?? "blank")|\($0.customTemplatePDF?.count ?? 0)|\($0.templateSpacing)"
        }.joined(separator: ",")
    }

    private func page(at index: Int) -> Page? {
        let pages = note.sortedPages
        return pages.indices.contains(index) ? pages[index] : nil
    }

    /// Magnetic alignment for element borders, from the current page's template.
    private var snapMetrics: SnapMetrics? {
        guard canvasController.snapToGrid, let page = currentPage else { return nil }
        return SnapMetrics.metrics(for: page.template, spacing: page.effectiveTemplateSpacing)
    }

    /// AI annotations + floating bubbles for every page, anchored through each
    /// page transform. Extracted to keep the body's type-check tractable.
    @ViewBuilder private var aiOverlays: some View {
        ForEach(tutor.bubbles) { bubble in
            AnnotationOverlay( 
                annotations: bubble.annotations,
                bubbleOrigin: CGPoint(x: bubble.x, y: bubble.y + 60),
                transform: canvasController.transform(forPage: bubble.pageIndex)
            )
        }
        ForEach(tutor.bubbles.filter { $0.isPanelOnly != true }) { bubble in
            AIBubbleView(
                bubble: bubble,
                isLoading: tutor.loadingBubbleIDs.contains(bubble.id),
                transform: canvasController.transform(forPage: bubble.pageIndex),
                tutor: tutor,
                onInsertTextBox: { textBoxes.append($0) }
            )
        }
    }

    @ViewBuilder private var floatingHeader: some View {
        if !distractionFree {
            editorHeader
                // The AI side panel (320pt, trailing) should PUSH the header
                // icons left rather than cover them.
                .padding(.trailing, tutor.panelOpen ? 320 : 0)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: tutor.panelOpen)
        }
    }

    var body: some View {
        ZStack {
            themeDesk.ignoresSafeArea()

            // The stitched document: every page in one continuous scroll.
            NoteCanvasView(
                controller: canvasController,
                pageSizes: note.sortedPages.map { $0.canvasSize },
                layoutSignature: layoutSignature
            )
            .ignoresSafeArea(edges: .bottom)
            // NOTE: the canvas stays hit-testable while the notes drawer is
            // open — the engine's tap intercept (armed via setTapIntercept)
            // is what closes the drawer, and it lives INSIDE the canvas's
            // UIKit hierarchy. Disabling hit-testing here starved it and made
            // the drawer unclosable.
            // Also OFF whenever the lasso tool is active: our TransformLassoOverlay
            // owns selection, so the PencilKit canvas must never receive those
            // touches — otherwise its built-in PKLassoTool fires a SECOND (native)
            // selection over ours, which spawned the system edit menu and a
            // stroke-group index crash.
            .allowsHitTesting(selectedMediaID == nil && strokeSelection == nil && !transformLassoActive && editingShape == nil && canvasController.toolState.kind != .lasso)

            // Loader over the canvas until the page's content (ink/PDF) is up.
            // Also masks the brief stale-ink flash when rebuilding for a new note.
            themeDesk
                .ignoresSafeArea()
                .overlay { ProgressView().controlSize(.large).tint(.secondary) }
                .opacity(canvasController.isContentReady ? 0 : 1)
                .allowsHitTesting(!canvasController.isContentReady)
                .animation(.easeOut(duration: 0.3), value: canvasController.isContentReady)
                .zIndex(50)

            // Tap-anywhere catcher to drop the current media/text selection.
            if selectedMediaID != nil || editingBoxID != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedMediaID = nil
                        editingBoxID = nil
                    }
            }

            // Current page's editable overlays (other pages render their media
            // and text inside the engine's cached page images).
            MediaLayer(items: $mediaItems, transform: transform, selectedItemID: $selectedMediaID, snap: snapMetrics)
            TextBoxLayer(boxes: $textBoxes, transform: transform, editingBoxID: $editingBoxID, snap: snapMetrics)

            // Above the margin glyphs — a chat bubble must never sit under a ✓/~/?.
            aiOverlays
                .zIndex(1)

            // The Ambient Tutor's margin lane: glyphs anchored to the lines of
            // work, and the note that unfolds from a tapped glyph.
            MarginLaneView(
                ambient: ambient,
                pageIndex: pageIndex,
                transform: transform,
                // Keep the unfolded note card clear of the page strip on the right.
                trailingInset: showPageStrip ? 110 : 0,
                onFixIt: { item in
                    // The "your-style amber ink" write-on is the deferred deep
                    // feature; for now write the correction in amber ink right
                    // beside the line it belongs to (we already know the rect,
                    // so no AI/OCR round-trip to land it in the wrong place).
                    ambient.dismiss()
                    if let result = item.result {
                        let rect = item.anchorRect
                        let fontSize = max(16, min(34, rect.height * 0.95))
                        // Write the corrected line just BELOW the student's line
                        // (writing to the right overlaps their work), verbatim —
                        // `result` is already the full corrected expression.
                        let point = CGPoint(x: rect.minX, y: rect.maxY + 6)
                        tutor.writeInk(
                            text: result,
                            at: point,
                            fontSize: fontSize,
                            colorHex: ambientInkHex,
                            avoid: ambient.lastLineRects,
                            on: canvasController.canvasView
                        )
                    }
                },
                onShowWhy: { item in
                    ambient.dismiss()
                    Task { await tutor.ask(question: "Explain why: \(item.body)", anchor: askAnchor) }
                },
                onOpenHint: { item in
                    // A watcher's "?" — highlight the line it flagged RIGHT AWAY (so
                    // the student sees what it's about before the answer streams in),
                    // then open the full explanation there. The glyph PERSISTS: only a
                    // new nudge, a check, or switching the watcher off clears it —
                    // opening it does not.
                    ambient.focus(on: item)
                    let anchor = CGPoint(x: item.anchorRect.midX, y: item.anchorRect.midY)
                    Task { await tutor.ask(question: item.body, anchor: anchor) }
                },
                onAcceptGhost: { g in
                    ambient.dismissGhost()
                    // Write where the preview was. Inline completions centre on the
                    // line (so a tall fraction straddles it); below-the-line ones
                    // avoid existing work.
                    tutor.writeInk(
                        text: g.text,
                        at: g.anchor,
                        colorHex: ambientInkHex,
                        avoid: g.inline ? [] : ambient.lastLineRects,
                        center: g.inline,
                        on: canvasController.canvasView
                    )
                    ambient.invalidateGhost()
                }
            )

            // Ambient tutor result banner ("looks all good" / error). Thinking
            // itself is the breathing corner badge below.
            ambientStatusHUD

            // ANY AI work — Check my work, Circle & Ask, Explain, Answer in Ink —
            // shows one breathing sparkle in the top corner so "the AI is
            // thinking" (replaces the old 'Checking your work…' pill).
            if tutor.isThinking || ambient.isChecking || ambient.isSuggesting || guidedMode.isWatching {
                AIThinkingBadge()
                    .padding(.top, 84)
                    .padding(.trailing, showPageStrip ? 120 : 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: tutor.isThinking || ambient.isChecking || ambient.isSuggesting || guidedMode.isWatching)
            }

            // Note title + creation time in the desk gutter above the first
            // page (scrolls/zooms with the page) — never over ink.
            if !distractionFree, let pageOrigin = canvasController.pageScreenOrigins.first {
                Button(action: startRename) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: note.title ?? "")
                            .font(.fraunces(20, weight: .semibold, relativeTo: .title3))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(note.createdAt ?? .now, format: .dateTime.day().month().year().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .offset(x: pageOrigin.x + 4, y: pageOrigin.y - 52)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    onTransformSelection: {
                        withAnimation { transformLassoActive = true }
                    },
                    extraItems: toolbarExtras,
                    // Pages strip occupies the trailing edge — slide aside.
                    trailingInset: showPageStrip ? 96 : 0
                )

                // The recorder lives in the top bar; the bar only surfaces
                // while a session is live (scrubber + tap-to-seek hint).
                if audio.isRecording || audio.isPlaying {
                    VStack(spacing: 8) {
                        Spacer()
                        AudioBar(audio: audio, note: note)
                            .padding(.bottom, 8)
                    }
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        pageIndicator
                            .padding(.trailing, 12)
                            .padding(.bottom, 24)
                    }
                }

                // Page navigator docks on the trailing edge (vertical strip).
                // Slide it away by dragging right; a pull-tab slides it back.
                HStack {
                    Spacer()
                    if showPageStrip {
                        PageNavigatorStrip(
                            note: note,
                            currentIndex: $pageIndex,
                            horizontal: false,
                            onWillMutatePages: { canvasController.commitPendingInk() }
                        )
                        .padding(.trailing, 6)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .gesture(
                            DragGesture(minimumDistance: 24)
                                .onEnded { value in
                                    if value.translation.width > 36 {
                                        Haptics.selection()
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showPageStrip = false }
                                    }
                                }
                        )
                    }
                    // Hidden by default with no pull-tab; reopen from the header
                    // pages button (top bar).
                }

                // Two-stage drawer: first edge swipe shows the notes of the
                // current subject; a second edge swipe slides the subjects
                // sidebar in on the left, pushing the notes pane right.
                // Picking a subject slides it back out with the new filter.
                if drawerStage > 0 {
                    HStack(spacing: 0) {
                        // Styled like the main screen's sidebar: a full-height,
                        // edge-pinned opaque panel (not a floating card), with
                        // the subjects column joining it on the second stage.
                        HStack(spacing: 0) {
                            if drawerStage >= 2 {
                                SubjectsPane { subject in
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        drawerSubject = .some(subject)
                                        drawerStage = 1
                                    }
                                }
                                .transition(.move(edge: .leading))
                                Divider()
                            }
                            NotesPane(currentNote: note, subjectOverride: drawerSubject) { selected in
                                withAnimation { closeDrawer() }
                                guard selected.objectID != note.objectID else { return }
                                onSwitchNote(selected)
                            }
                        }
                        .background(SemanticColor.sidebarBackground)
                        .overlay(alignment: .trailing) { Divider().ignoresSafeArea() }
                        .ignoresSafeArea(edges: .vertical)
                        .transition(.move(edge: .leading))
                        .gesture(
                            DragGesture(minimumDistance: 20)
                                .onEnded { value in
                                    if value.translation.width < -30 {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                            if drawerStage >= 2 { drawerStage = 1 } else { closeDrawer() }
                                        }
                                    }
                                }
                        )
                        Spacer()
                    }
                }
                // Edge catch strip: opens the drawer, then promotes it to the
                // subjects stage on the next swipe.
                if drawerStage < 2 {
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: 20)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 15)
                                    .onEnded { value in
                                        if value.translation.width > 30 {
                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                                drawerStage += 1
                                            }
                                        }
                                    }
                            )
                        Spacer()
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

            // Select & rotate: lasso capture (freeform or marquee, switchable
            // inline), then live rotation preview.
            TransformLassoOverlay(isActive: $transformLassoActive, transform: canvasController.canvasTransform(forPage: pageIndex), rectangular: canvasController.lassoRectangular) { polygon in
                beginStrokeTransform(with: polygon)
            }
            // Node editing for freshly created shapes.
            if editingShape != nil {
                ShapeNodeOverlay(
                    editing: Binding(
                        get: { editingShape! },
                        set: { editingShape = $0 }
                    ),
                    transform: canvasController.canvasTransform(forPage: editingShape!.pageIndex),
                    snap: snapMetrics.map { SnapMetrics(stepX: $0.stepX.map { $0 * canvasController.inkScale },
                                                        stepY: $0.stepY.map { $0 * canvasController.inkScale }) },
                    onChange: { _ in
                        // No engine write during the drag — the stroke is lifted
                        // out of the ink and the overlay preview is the only
                        // live copy, so there's no async PencilKit lag.
                    },
                    onDone: {
                        if let editing = editingShape {
                            let stroke = ShapeRecognizer.idealStroke(
                                for: editing.shape,
                                ink: editing.ink,
                                width: CGFloat(editing.width)
                            )
                            canvasController.engine?.endStrokeEdit(with: stroke)
                        }
                        editingShape = nil
                        Haptics.tap()
                    }
                )
            }

            if let selection = strokeSelection {
                StrokeTransformOverlay(
                    selection: selection,
                    transform: canvasController.canvasTransform(forPage: selection.pageIndex),
                    rotation: $strokeRotation,
                    translation: $strokeTranslation,
                    scale: $strokeScale,
                    onDone: applyStrokeTransform,
                    onCancel: {
                        canvasController.engine?.cancelStrokeSelection()
                        clearStrokeSelection()
                    },
                    canPaste: canvasController.hasPasteContent,
                    onCut: { canvasController.engine?.cutStrokeSelection(selection); clearStrokeSelection() },
                    onCopy: {
                        let t = selectionTransform(selection)
                        canvasController.engine?.copyStrokeSelection(rotation: t.0, scale: t.1, translation: t.2, selection: selection)
                        clearStrokeSelection()
                    },
                    onPaste: { canvasController.engine?.pasteStrokes(); clearStrokeSelection() },
                    onDuplicate: {
                        let t = selectionTransform(selection)
                        canvasController.engine?.duplicateStrokeSelection(rotation: t.0, scale: t.1, translation: t.2, selection: selection)
                        clearStrokeSelection()
                    },
                    onDelete: { canvasController.engine?.deleteStrokeSelection(); clearStrokeSelection() }
                )
            }

            // Finger-tap "Paste" affordance: tap empty space with ink on the
            // clipboard → a Paste chip appears there; tap it to drop the ink.
            if let pt = pastePoint, canvasController.hasPasteContent {
                let screen = canvasController.canvasTransform(forPage: pageIndex).toScreen(pt)
                Button {
                    canvasController.engine?.pasteStrokes(at: pt)
                    Haptics.tap()
                    withAnimation { pastePoint = nil }
                } label: {
                    // iOS-default paste-pill look: plain "Paste", neutral material.
                    Text("media.paste")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                        .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
                }
                .buttonStyle(.plain)
                .position(x: screen.x, y: max(40, screen.y - 26))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .zIndex(40)
            }

            // Guided-mode bottom suggestion card. High zIndex so nothing (AI overlay,
            // margin lane) can sit over it.
            if let suggestion = guidedMode.suggestion {
                VStack {
                    Spacer()
                    GuidedSuggestionCard(
                        suggestion: suggestion,
                        onAccept: { guidedMode.accept(suggestion) },
                        onDismiss: { withAnimation { guidedMode.suggestion = nil } }
                    )
                    .padding(.bottom, 64)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(60)
            }

            // Guided-mode status: transient banner on activation + a persistent
            // "watching" chip while enabled (tap to turn off).
            if let banner = guidedMode.banner, guidedMode.suggestion == nil {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(SemanticColor.aiCircleStroke)
                        Text(banner)
                            .font(.footnote)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(SemanticColor.aiBubbleBorder))
                    .padding(.bottom, 64)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if guidedMode.isEnabled && !distractionFree {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            // Stepping down to Subtle turns watching off (the
                            // sensitivity is the single control now).
                            ambient.sensitivity = .subtle
                            guidedMode.isEnabled = false
                        } label: {
                            Label("ai.guidedMode", systemImage: "lightbulb.fill")
                                .font(.caption2)
                                .foregroundStyle(SemanticColor.aiCircleStroke)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(SemanticColor.aiBubbleBorder, lineWidth: 0.5))
                        }
                        .accessibilityLabel(Text("ai.guided.disable"))

                        Button {
                            showGuidedLog = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption)
                                .padding(7)
                                .background(.regularMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(SemanticColor.aiBubbleBorder, lineWidth: 0.5))
                        }
                        .accessibilityLabel(Text("ai.guided.log"))
                        .popover(isPresented: $showGuidedLog) {
                            GuidedLogView(guidedMode: guidedMode)
                        }
                        Spacer()
                    }
                    .padding(.leading, 14)
                    .padding(.bottom, 8)
                }
            }

            // Side AI panel (secondary surface for long explanations + history).
            if tutor.panelOpen {
                HStack {
                    Spacer()
                    AIPanelView(tutor: tutor)
                }
                .ignoresSafeArea(edges: .bottom)
            }

            // Minimal ask-the-tutor input: floating glass field + quick chips,
            // bottom-center (replaces the system alert).
            if showAskField {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showAskField = false }
                    }
                VStack {
                    Spacer()
                    AskTutorBar(text: $askText) {
                        sendAsk()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showAskField = false }
                    }
                    .padding(.bottom, 28)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Transparent header floating over the canvas (always visible) — it
        // reserves no canvas height; the title/time sit in the gutter above
        // the page instead.
        .overlay(alignment: .top) { floatingHeader }
        // Ambient: each new stroke invalidates the ghost and re-arms the idle
        // timer; when the pen rests, the tutor suggests the next step.
        .onChange(of: canvasController.drawingGestureBeganToken) { _, _ in
            ambient.invalidateGhost()
            scheduleGhostSuggestion()
            if pastePoint != nil { pastePoint = nil }
        }
        // When the watcher produces a nudge, drop its "?" glyph at the student's
        // LAST pen location (where they're working = what the nudge is about). The
        // OCR is too garbled to text-match the model's clean match_string, so the
        // pen position is the reliable anchor.
        .onChange(of: guidedMode.suggestion) { _, suggestion in
            guard let suggestion else { return }
            let anchor = lastStrokeAnchor ?? CGPoint(x: 120, y: 160)
            let rect = CGRect(x: anchor.x - 24, y: anchor.y - 14, width: 48, height: 28)
            ambient.placeHint(pageIndex: pageIndex, anchorRect: rect, body: suggestion.text)
        }
        // No system navigation bar — the canvas owns the full screen; actions
        // live in the fixed header + floating toolbar.
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        // Kill BOTH system "drag back to the library" gestures at the UIKit
        // level: the navigation pop swipe and the split view's sidebar-reveal
        // pan (hiding the back button alone didn't stop them).
        .background(NavigationGestureDisabler())
        .sheet(isPresented: $quiz.isPresented) { QuizView(quiz: quiz) }
        .alert(Text("ai.draw"), isPresented: $showAIDrawPrompt) {
            TextField("ai.draw.placeholder", text: $aiDrawText)
            Button("action.cancel", role: .cancel) {}
            Button("ai.draw.go") {
                let request = aiDrawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !request.isEmpty else { return }
                Task {
                    await tutor.answerInInk(
                        request: request,
                        on: canvasController.canvasView,
                        colorHex: canvasController.toolState.colorHex,
                        penWidth: canvasController.toolState.width
                    )
                }
            }
        }
        .alert(Text("ai.sketch"), isPresented: $showAISketchPrompt) {
            TextField("ai.sketch.placeholder", text: $aiSketchText)
            Button("action.cancel", role: .cancel) {}
            Button("ai.sketch.go") {
                let request = aiSketchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !request.isEmpty else { return }
                Task { await tutor.drawSketch(request: request, on: canvasController.canvasView) }
            }
        }
        .statusBarHidden(distractionFree)
        .onAppear {
            // Restore the page the user last left off on for this note.
            if let key = note.id?.uuidString {
                let saved = UserDefaults.standard.integer(forKey: "note.lastPage.\(key)")
                if saved > 0, saved < note.sortedPages.count {
                    pageIndex = saved
                    canvasController.initialPageIndex = saved
                }
            }
            loadPage()
            // Safety net: never let the loader stick if the ready signal is missed.
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); canvasController.markReady() }
            tutor.attach(note: note)
            tutor.isDarkMode = colorScheme == .dark
            guidedMode.tutor = tutor
            guidedMode.ambient = ambient
            // Guided Mode (proactive watching) is folded into the sensitivity:
            // Helpful watches, Subtle/Off don't.
            guidedMode.isEnabled = (ambient.sensitivity == .helpful)
            audio.attach(note: note)
            canvasController.onStroke = { index, stroke in
                let center = CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY)
                if index == pageIndex { lastStrokeAnchor = center }
                audio.logStroke(at: center, pageIndex: index)
                guidedMode.strokeOccurred()
            }
            canvasController.onInterceptedTap = {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { closeDrawer() }
            }
            canvasController.onPencilHold = {
                withAnimation { askLassoActive = true }
            }
            canvasController.drawingProvider = { [weak note] index in
                MainActor.assumeIsolated {
                    guard let note else { return PKDrawing() }
                    let pages = note.sortedPages
                    return pages.indices.contains(index) ? pages[index].drawing : PKDrawing()
                }
            }
            canvasController.snapshotProvider = { [weak note] index in
                MainActor.assumeIsolated {
                    guard let note else { return nil }
                    let pages = note.sortedPages
                    guard pages.indices.contains(index) else { return nil }
                    return PageRenderer.Snapshot(page: pages[index])
                }
            }
            // Finger-tap on empty canvas (no shape): select the topmost media
            // under it (media is otherwise non-interactive so pan/zoom pass
            // through), or deselect if the tap missed everything.
            canvasController.onCanvasFingerTap = { point in
                if let hit = mediaItems.last(where: { $0.frame.contains(point) }) {
                    Haptics.selection()
                    selectedMediaID = hit.id
                    pastePoint = nil
                } else {
                    selectedMediaID = nil
                    // Empty-space tap with ink on the clipboard → offer Paste here.
                    if canvasController.hasPasteContent {
                        Haptics.selection()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { pastePoint = point }
                    } else {
                        pastePoint = nil
                    }
                }
            }
            // Fresh shapes commit clean and stay unselected — node editing
            // only opens when the user taps a shape with a finger.
            canvasController.onShapeTapped = { pageIndex, strokeIndex, shape, ink, width, colorHex in
                // Commit any shape already being edited before lifting the new one.
                if let editing = editingShape {
                    let stroke = ShapeRecognizer.idealStroke(for: editing.shape, ink: editing.ink, width: CGFloat(editing.width))
                    canvasController.engine?.endStrokeEdit(with: stroke)
                    editingShape = nil
                }
                canvasController.engine?.beginStrokeEdit(at: strokeIndex)
                editingShape = EditingShape(
                    pageIndex: pageIndex,
                    strokeIndex: strokeIndex,
                    shape: shape,
                    ink: ink,
                    colorHex: colorHex,
                    width: width
                )
            }
            canvasController.onAddPage = { [weak note] in
                guard let note else { return }
                note.addPage()
                PersistenceController.shared.save()
                let last = note.sortedPages.count - 1
                DispatchQueue.main.async {
                    pageIndex = last
                }
            }
        }
        .onChange(of: colorScheme) { tutor.isDarkMode = colorScheme == .dark }
        .onChange(of: pageIndex) { oldIndex, newIndex in
            // An open shape edit or lasso selection holds strokes OUT of the ink —
            // restore/commit them before the page (and its drawing) is saved and
            // swapped, so nothing is lost.
            commitOpenShapeEdit()
            if strokeSelection != nil {
                applyStrokeTransform()
                strokeSelection = nil
            }
            persistOverlays(to: page(at: oldIndex))
            canvasController.engine?.refreshPage(oldIndex)
            loadPage()
            // Remember where the user is so re-opening the note returns here.
            if let key = note.id?.uuidString {
                UserDefaults.standard.set(newIndex, forKey: "note.lastPage.\(key)")
            }
            tutor.pageChanged(to: newIndex)
            guidedMode.pageTurned()
            if canvasController.currentPageIndex != newIndex {
                canvasController.scrollToPage(newIndex)
            }
        }
        .onChange(of: canvasController.currentPageIndex) { _, engineIndex in
            if pageIndex != engineIndex { pageIndex = engineIndex }
        }
        // Drawer dismissal happens at the UIKit level: SwiftUI tap catchers
        // lose to the canvas's hit-testing, so the engine intercepts the
        // first tap while the drawer is open.
        .onChange(of: drawerStage) { _, stage in
            canvasController.setTapIntercept(enabled: stage > 0)
        }
        // Rotation should feel like part of the lasso, not a second mode:
        // picking the lasso arms select-and-rotate right away.
        .onChange(of: canvasController.toolState.kind) { _, kind in
            if kind == .lasso {
                withAnimation { transformLassoActive = true }
            } else if transformLassoActive {
                withAnimation { transformLassoActive = false }
            }
        }
        .onChange(of: textBoxes) { scheduleOverlaySave() }
        .onChange(of: mediaItems) { scheduleOverlaySave() }
        .onDisappear {
            commitOpenShapeEdit()
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
        .alert(Text("library.renameNote"), isPresented: $showRenameAlert) {
            TextField("library.noteTitle", text: $renameText)
            Button("action.cancel", role: .cancel) {}
            Button("action.done") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                note.title = trimmed
                note.touch()
                PersistenceController.shared.save()
            }
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
    private func sendCircleAsk(question: String, region screenRect: CGRect) {
        // Resolve which page the circle actually landed on (not just the
        // viewport-center page) so the crop + answer target what was circled.
        let pages = note.sortedPages
        let resolved = resolveCirclePage(screenRect: screenRect)
        guard pages.indices.contains(resolved.index) else { return }
        let page = pages[resolved.index]
        let crop = croppedImage(of: resolved.pageRect, page: page)
        let anchor = CGPoint(x: resolved.pageRect.midX, y: resolved.pageRect.midY)
        circleAskRegion = nil
        // Point the tutor at the circled page so context + bubble anchor match.
        tutor.currentPageIndex = resolved.index
        Task {
            await tutor.ask(question: question, anchor: anchor, focusRegion: resolved.pageRect, focusImage: crop)
        }
    }

    /// Which page a screen-space rect is over, plus that rect in the page's
    /// own coordinate space. Falls back to the current page if none contains it.
    private func resolveCirclePage(screenRect: CGRect) -> (index: Int, pageRect: CGRect) {
        let center = CGPoint(x: screenRect.midX, y: screenRect.midY)
        let pages = note.sortedPages
        for i in pages.indices {
            let t = canvasController.transform(forPage: i)
            let p = t.toPage(center)
            let size = pages[i].canvasSize
            if (0...size.width).contains(p.x), (0...size.height).contains(p.y) {
                return (i, screenRectToPage(screenRect, t))
            }
        }
        let t = canvasController.transform(forPage: pageIndex)
        return (pageIndex, screenRectToPage(screenRect, t))
    }

    private func screenRectToPage(_ rect: CGRect, _ t: CanvasTransform) -> CGRect {
        let origin = t.toPage(rect.origin)
        return CGRect(x: origin.x, y: origin.y,
                      width: rect.width / t.zoomScale, height: rect.height / t.zoomScale)
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

    /// Lasso completed: capture the strokes under the loop for move+rotate.
    private func beginStrokeTransform(with polygon: [CGPoint]) {
        guard let drawing = canvasController.canvasView?.drawing else { return }
        strokeRotation = 0
        strokeTranslation = .zero
        strokeScale = 1
        if let selection = StrokeSelector.selection(
            from: drawing,
            polygon: polygon,
            pageIndex: pageIndex,
            darkMode: colorScheme == .dark
        ) {
            Haptics.selection()
            strokeSelection = selection
            // Lift the selected strokes out of the live ink so dragging the
            // selection doesn't leave a copy at the original position.
            canvasController.engine?.liftStrokeSelection(selection.strokeIndices)
        } else {
            Haptics.error()
            // Empty loop — go straight back to capturing, no dead end.
            rearmLassoIfActive()
        }
    }

    /// Bake the previewed move + resize + rotation into the strokes, undoably.
    private func applyStrokeTransform() {
        defer {
            strokeSelection = nil
            strokeRotation = 0
            strokeTranslation = .zero
            strokeScale = 1
            rearmLassoIfActive()
        }
        guard let selection = strokeSelection else { return }
        guard abs(strokeRotation) > 0.5 || strokeTranslation != .zero || abs(strokeScale - 1) > 0.01 else {
            // No real change — just drop the lifted strokes back where they were.
            canvasController.engine?.cancelStrokeSelection()
            return
        }
        // The overlay drag is in screen points; convert to the canvas's own
        // (inkScale×) coordinate space, where the selected strokes live.
        let zoom = canvasController.canvasTransform(forPage: selection.pageIndex).zoomScale
        let canvasTranslation = CGSize(width: strokeTranslation.width / zoom,
                                       height: strokeTranslation.height / zoom)
        canvasController.engine?.commitStrokeSelection(
            rotation: strokeRotation, scale: strokeScale, translation: canvasTranslation, selection: selection)
        Haptics.success()
    }

    /// Keep the lasso in its single seamless mode: after a selection finishes,
    /// re-arm the capture so the next loop works immediately (no native-lasso
    /// fallback, no second tap).
    private func rearmLassoIfActive() {
        if canvasController.toolState.kind == .lasso {
            withAnimation { transformLassoActive = true }
        }
    }

    /// The selection's live move/rotate/scale in the canvas's coordinate space
    /// (screen drag → ÷ zoom), so copy/duplicate keep it where the user dragged.
    private func selectionTransform(_ selection: StrokeSelection) -> (Double, CGFloat, CGSize) {
        let zoom = canvasController.canvasTransform(forPage: selection.pageIndex).zoomScale
        return (strokeRotation, strokeScale,
                CGSize(width: strokeTranslation.width / zoom, height: strokeTranslation.height / zoom))
    }

    /// Reset the selection UI after an edit-menu action (the engine has already
    /// applied it), and re-arm the lasso for the next loop.
    private func clearStrokeSelection() {
        strokeSelection = nil
        strokeRotation = 0
        strokeTranslation = .zero
        strokeScale = 1
        rearmLassoIfActive()
    }

    private func sendAsk() {
        let question = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        askText = ""
        guard !question.isEmpty else { return }
        let anchor = askAnchor
        Task { await tutor.ask(question: question, anchor: anchor) }
    }

    // MARK: - Ask bar
}

/// Disables the interactive pop swipe and the split view's sidebar-reveal pan
/// while the editor is on screen; restores both on the way out.
/// Enforced continuously — SwiftUI re-enables both recognizers on its own
/// updates, so a one-shot disable in viewDidAppear quietly wore off.
private struct NavigationGestureDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Disabler { Disabler() }
    func updateUIViewController(_ controller: Disabler, context: Context) {
        controller.applyIfVisible()
    }

    final class Disabler: UIViewController {
        private var enforcer: Timer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply(enabled: false)
            enforcer?.invalidate()
            enforcer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.apply(enabled: false)
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyIfVisible()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            enforcer?.invalidate()
            enforcer = nil
            apply(enabled: true)
        }

        func applyIfVisible() {
            guard viewIfLoaded?.window != nil else { return }
            apply(enabled: false)
        }

        private func apply(enabled: Bool) {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = enabled
            splitViewController?.presentsWithGesture = enabled
            // SwiftUI's NavigationStack installs its own screen-edge pan for
            // the pop — it is NOT the interactivePopGestureRecognizer, which
            // is why the swipe survived the two lines above. Sweep the window
            // and switch off every edge-pan recognizer while we're on screen.
            if let window = viewIfLoaded?.window {
                setEdgePans(enabled: enabled, in: window)
            }
        }

        private func setEdgePans(enabled: Bool, in view: UIView) {
            for recognizer in view.gestureRecognizers ?? [] where recognizer is UIScreenEdgePanGestureRecognizer {
                recognizer.isEnabled = enabled
            }
            for subview in view.subviews {
                setEdgePans(enabled: enabled, in: subview)
            }
        }
    }
}

/// Record/stop + the note's recordings; swipe a recording to delete it
/// (file and Core Data row both).
private struct RecorderPopover: View {
    @ObservedObject var audio: AudioSyncController
    @ObservedObject var note: Note
    @Environment(\.managedObjectContext) private var context
    @State private var recordingPendingDelete: Recording?

    private var recordings: [Recording] {
        (note.recordings ?? []).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                audio.isRecording ? audio.stopRecording() : audio.startRecording()
            } label: {
                Label(
                    audio.isRecording ? "audio.stop" : "audio.record",
                    systemImage: audio.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(audio.isRecording ? Color("errorRed") : Color.accentColor)
            .padding(12)

            if !recordings.isEmpty {
                Divider()
                List {
                    ForEach(recordings, id: \.objectID) { recording in
                        Button {
                            audio.play(recording)
                        } label: {
                            HStack {
                                Image(systemName: "play.circle")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((recording.createdAt ?? .now).formatted(date: .abbreviated, time: .shortened))
                                        .font(.subheadline)
                                    Text(Duration.seconds(recording.duration).formatted(.time(pattern: .minuteSecond)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                recordingPendingDelete = recording
                            } label: { Label("action.delete", systemImage: "trash") }
                                .tint(Color("errorRed"))
                        }
                    }
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(recordings.count) * 52 + 16, 260))
            }
        }
        .frame(width: 280)
        .alert(Text("audio.deleteRecording.confirm"), isPresented: Binding(
            get: { recordingPendingDelete != nil },
            set: { if !$0 { recordingPendingDelete = nil } }
        )) {
            Button("action.cancel", role: .cancel) { recordingPendingDelete = nil }
            Button("action.delete", role: .destructive) {
                if let recording = recordingPendingDelete { delete(recording) }
                recordingPendingDelete = nil
            }
        } message: {
            Text("delete.permanent.message")
        }
    }

    private func delete(_ recording: Recording) {
        audio.stopPlayback()
        if let fileName = recording.fileName {
            try? FileManager.default.removeItem(at: AudioSyncController.directory.appendingPathComponent(fileName))
        }
        context.delete(recording)
        PersistenceController.shared.save()
    }
}

/// Minimal floating input for asking the tutor: one glass capsule with a
/// focused text field and a send arrow, quick-question chips above it.
private struct AskTutorBar: View {
    @Binding var text: String
    var onSend: () -> Void
    @FocusState private var focused: Bool

    private static let quickKeys: [LocalizedStringKey] = [
        "ai.quick.explain", "ai.quick.hint", "ai.quick.summarize",
    ]
    private static let quickQuestions: [String] = [
        String(localized: "ai.quick.explain"),
        String(localized: "ai.quick.hint"),
        String(localized: "ai.quick.summarize"),
    ]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Array(Self.quickKeys.enumerated()), id: \.offset) { index, key in
                    Button {
                        text = Self.quickQuestions[index]
                        onSend()
                    } label: {
                        Text(key)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.quaternary))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                TextField("ai.askPlaceholder", text: $text, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($focused)
                    .onSubmit(onSend)
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(text.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel(Text("ai.send"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(width: 420)
            .studyGlass(cornerRadius: 24)
        }
        .onAppear { focused = true }
    }
}

// MARK: - Toolbar & content actions

extension NoteEditorView {
    private var toolbarExtras: [ToolbarExtraItem] {
        [
            // The AI pen: arm Circle & Ask straight from the toolbar — circle
            // anything on the page and ask about it.
            ToolbarExtraItem(id: "ask-ai", symbolName: "wand.and.stars", labelKey: "ai.circleAsk.title") {
                withAnimation { askLassoActive = true }
            },
            ToolbarExtraItem(id: "ai-history", symbolName: "clock.arrow.circlepath", labelKey: "ai.history") {
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

    /// Floating glass action bar (top-trailing) — replaces the navigation bar.
    /// Fixed Foolscap header bar (58pt): back · title/subtitle · recorder ·
    /// more · pages · Tutor pill. Undo/redo now live on the floating toolbar.
    private var editorHeader: some View {
        HStack(spacing: 10) {
            Button(action: { dismiss() }) {
                headerSquare("chevron-left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("action.back"))

            Spacer(minLength: 8)

            // Undo / redo always live here, top-right.
            Button(action: { canvasController.undo() }) { headerSquare("undo-2") }
                .buttonStyle(.plain)
                .disabled(!canvasController.canUndo)
                .accessibilityLabel(Text("action.undo"))
            Button(action: { canvasController.redo() }) { headerSquare("redo-2") }
                .buttonStyle(.plain)
                .disabled(!canvasController.canRedo)
                .accessibilityLabel(Text("action.redo"))

            recorderMenu
                .background(themePaper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SemanticColor.separator))
            overflowMenu
                .background(themePaper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SemanticColor.separator))
            Button {
                withAnimation { showPageStrip.toggle() }
            } label: {
                headerSquare("copy")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("page.toggleStrip"))
            // The Tutor pill (AI menu) — the study partner's ochre.
            aiMenu
        }
        .font(.system(size: 16, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        // Transparent header — it floats over the canvas, no solid bar / divider
        // and reserves no canvas height (spec: compact 44pt, non-eating).
    }

    /// A 34pt rounded-square header button face — light paper so it reads on the
    /// transparent (desk) header. Glyph is a bundled Lucide icon.
    private func headerSquare(_ lucide: String) -> some View {
        Lucide(lucide, size: 18)
            .foregroundStyle(SemanticColor.textPrimary)
            .frame(width: 34, height: 34)
            .background(themePaper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SemanticColor.separator))
    }

    private func startRename() {
        // Start empty when it's still the default "Untitled" name.
        let untitled = String(localized: "library.untitledNote")
        renameText = (note.title == untitled) ? "" : (note.title ?? "")
        showRenameAlert = true
    }

    /// The tutor's amber ink colour — the design tags AI-written ink amber.
    private var ambientInkHex: String { UIColor(AppTheme.current.aiAccent).hexString }

    /// Top-center result banner for the ambient tutor ("looks all good", an
    /// error, "nothing to check"). The thinking state itself is the breathing
    /// corner badge — see aiThinkingHUD.
    @ViewBuilder
    private var ambientStatusHUD: some View {
        VStack {
            if let notice = ambient.notice, !ambient.isChecking {
                Text(notice)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(SemanticColor.separator))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, 84)
        .frame(maxWidth: .infinity, alignment: .center)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: ambient.notice)
    }

    /// Debounced: when the pen rests ~2.5s after writing, the ambient tutor
    /// suggests the next step (Helpful sensitivity only).
    private func scheduleGhostSuggestion() {
        ghostIdleTask?.cancel()
        guard ambient.sensitivity == .helpful, !distractionFree else { return }
        ghostIdleTask = Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            canvasController.commitPendingInk()
            await ambient.suggestNext(note: note, pageIndex: pageIndex, darkMode: colorScheme == .dark, auto: true)
        }
    }

    /// Record/stop plus the note's saved recordings — a popover list so
    /// recordings can be swiped away (menus can't swipe).
    private var recorderMenu: some View {
        Button {
            showRecorderPopover = true
        } label: {
            Lucide("mic", size: 18)
                .foregroundStyle(audio.isRecording ? Color.accentColor : SemanticColor.textPrimary)
                .frame(width: 34, height: 34)
        }
        .tint(Color.accentColor)
        .accessibilityLabel(Text(audio.isRecording ? "audio.stop" : "audio.record"))
        .popover(isPresented: $showRecorderPopover) {
            RecorderPopover(audio: audio, note: note)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// AI tools, top-level in the action bar.
    private var aiMenu: some View {
        Menu {
            // Ambient Tutor — check the page line-by-line; glyphs settle in the
            // margin lane.
            Button {
                Task {
                    // Flush the debounced ink save first, or the OCR renders the
                    // PERSISTED page and misses everything just written — the
                    // check would then find no lines and silently do nothing.
                    canvasController.commitPendingInk()
                    await ambient.checkWork(note: note, pageIndex: pageIndex, darkMode: colorScheme == .dark)
                }
            } label: { Label("ambient.check", systemImage: "sparkles.rectangle.stack") }
            Button {
                ambient.invalidateGhost()
                Task {
                    canvasController.commitPendingInk()
                    await ambient.suggestNext(note: note, pageIndex: pageIndex, darkMode: colorScheme == .dark)
                    // Manual press should never look like it did nothing.
                    if ambient.ghost == nil { ambient.showNotice(String(localized: "ambient.notice.noSuggestion")) }
                }
            } label: { Label("ambient.suggest", systemImage: "wand.and.rays") }
            Picker(selection: Binding(get: { ambient.sensitivity }, set: {
                ambient.sensitivity = $0
                guidedMode.isEnabled = ($0 == .helpful)   // Helpful = watch proactively
            })) {
                ForEach(AmbientSensitivity.allCases) { s in Text(s.labelKey).tag(s) }
            } label: { Label("ambient.sensitivity", systemImage: "dial.medium") }
            Divider()
            Button {
                withAnimation { askLassoActive = true }
            } label: { Label("ai.circleAsk.title", systemImage: "lasso.badge.sparkles") }
            Button {
                Task { await tutor.explainCurrentPage() }
            } label: { Label("ai.explainPage", systemImage: "doc.text.magnifyingglass") }
            Button {
                Task { await quiz.start(note: note, pageIndex: pageIndex, darkMode: colorScheme == .dark) }
            } label: { Label("ai.quizMe", systemImage: "questionmark.app") }
            Button {
                aiDrawText = ""
                showAIDrawPrompt = true
            } label: { Label("ai.draw", systemImage: "pencil.and.outline") }
            Button {
                aiSketchText = ""
                showAISketchPrompt = true
            } label: { Label("ai.sketch", systemImage: "scribble") }
            // Guided Mode (proactive watching) is now folded into the Helpful
            // sensitivity above — no separate toggle.
        } label: {
            HStack(spacing: 5) {
                Lucide("wand-sparkles", size: 15)
                Text("ai.tutorName")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .frame(height: 34)
            .padding(.horizontal, 12)
            .background(aiAccent, in: Capsule())
        }
        .accessibilityLabel(Text("ai.menu"))
    }

    /// Everything else: insert, export, subject, page settings.
    private var overflowMenu: some View {
        Menu {
            Menu {
                Button { showPhotoPicker = true } label: { Label("media.photo", systemImage: "photo") }
                Button { showCamera = true } label: { Label("media.camera", systemImage: "camera") }
                Button { showScanner = true } label: { Label("media.scan", systemImage: "doc.viewfinder") }
                Button { showStickers = true } label: { Label("media.stickers", systemImage: "face.smiling") }
                Button { importingPDF = true } label: { Label("media.importPDF", systemImage: "doc.badge.plus") }
                Divider()
                Button { pasteFromClipboard() } label: { Label("media.paste", systemImage: "doc.on.clipboard") }
            } label: {
                Label("media.insert", systemImage: "plus")
            }

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
                Label("export.share", systemImage: "square.and.arrow.up")
            }

            SubjectContextMenu(note: note)

            Divider()

            Button { showPageSettings = true } label: {
                Label("page.settings", systemImage: "doc.badge.gearshape")
            }
        } label: {
            Lucide("more-horizontal", size: 18)
                .foregroundStyle(SemanticColor.textPrimary)
                .frame(width: 34, height: 34)
        }
        .accessibilityLabel(Text("editor.more"))
    }

    /// Bottom-right: current page out of total, with up/down paging.
    private var pageIndicator: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation { pageIndex = max(0, pageIndex - 1) }
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 34, height: 28)
            }
            .disabled(pageIndex == 0)
            .accessibilityLabel(Text("page.previous"))

            Text(verbatim: "\(pageIndex + 1)/\(note.sortedPages.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                withAnimation { pageIndex = min(note.sortedPages.count - 1, pageIndex + 1) }
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 34, height: 28)
            }
            .disabled(pageIndex >= note.sortedPages.count - 1)
            .accessibilityLabel(Text("page.next"))
        }
        .font(.system(size: 14, weight: .medium))
        .padding(4)
        .studyGlass(cornerRadius: 14)
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

    private func persistOverlays(to target: Page? = nil) {
        overlaySaveTask?.cancel()
        guard let page = target ?? currentPage else { return }
        // Only do the expensive work (rebuild the note's search index + write Core
        // Data) when an overlay ACTUALLY changed. A plain page turn carries no
        // change, so this short-circuits — without it, flipping pages quickly hit
        // the disk and re-scanned every page each time, which is what made fast
        // navigation stutter.
        var changed = false
        if page.textBoxes != textBoxes { page.textBoxes = textBoxes; changed = true }
        if page.mediaItems != mediaItems { page.mediaItems = mediaItems; changed = true }
        guard changed else { return }
        note.searchableText = SearchableTextBuilder.build(for: note)
        PersistenceController.shared.save()
    }

    private func closeDrawer() {
        drawerStage = 0
        drawerSubject = nil
    }

    /// Commits an in-progress shape edit (its stroke is lifted out of the ink
    /// while the node overlay is up) so navigation can't persist the page
    /// without it.
    private func commitOpenShapeEdit() {
        guard let editing = editingShape else { return }
        let stroke = ShapeRecognizer.idealStroke(for: editing.shape, ink: editing.ink, width: CGFloat(editing.width))
        canvasController.engine?.endStrokeEdit(with: stroke)
        editingShape = nil
    }

    private func wireCanvasSave() {
        canvasController.onDrawingChanged = { [weak note] index, drawing in
            guard let note else { return }
            let pages = note.sortedPages
            guard pages.indices.contains(index) else { return }
            pages[index].drawing = drawing
            // Ink on the last page grows the document — there's always a fresh
            // page waiting below. (Empty pages stay out of the exported PDF.)
            if index == pages.count - 1, !drawing.strokes.isEmpty {
                _ = note.addPage()
            }
            note.searchableText = SearchableTextBuilder.build(for: note)
            PersistenceController.shared.save()
            scheduleOCR(for: pages[index])
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

    /// Pastes clipboard images as media items, or clipboard text as a text box,
    /// dropped at the center of the visible page region.
    private func pasteFromClipboard() {
        let pasteboard = UIPasteboard.general
        if let images = pasteboard.images, !images.isEmpty {
            for image in images {
                insert(image: image, kind: .image)
            }
        } else if let text = pasteboard.string, !text.isEmpty {
            let pagePoint = transform.toPage(CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY))
            var box = TextBoxModel(x: pagePoint.x - 130, y: pagePoint.y - 30)
            box.text = text
            box.colorHex = canvasController.toolState.colorHex
            textBoxes.append(box)
        }
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

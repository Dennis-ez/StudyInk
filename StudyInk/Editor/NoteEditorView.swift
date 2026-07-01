import SwiftUI
import PencilKit
import PhotosUI
import UniformTypeIdentifiers

/// Wraps a SINGLE page-anchored overlay so it re-renders when the document geometry
/// changes (scroll/zoom) WITHOUT re-evaluating the whole editor body. The overlay reads
/// `transform` inside the closure, so each gate refresh recomputes it from the current
/// geometry. Apply any `.zIndex` to the gate itself (it's a layout-neutral passthrough).
private struct GeometryGate<Content: View>: View {
    @ObservedObject var geometry: CanvasGeometry
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}

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
    /// Debounce for the "grade my answer" glyph (fires when the pen goes idle).
    @State private var gradePromptTask: Task<Void, Never>?
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
    @State private var showAISettings = false
    @State private var showCamera = false
    @State private var showScanner = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var importingPDF = false
    @State private var ocrTask: Task<Void, Never>?
    @State private var overlaySaveTask: Task<Void, Never>?
    @StateObject private var tutor = AITutorController()
    @StateObject private var guidedMode = GuidedModeController()
    @StateObject private var ghostWitness = GhostWitnessController()
    @StateObject private var warpTunnel = WarpTunnelController()
    @StateObject private var quiz = QuizController()
    /// Ambient Tutor — the margin lane + glyphs (Marginalia design).
    @StateObject private var ambient = AmbientTutorController()
    @StateObject private var audio = AudioSyncController()
    @State private var showAskField = false
    @State private var askText = ""
    @State private var showAIDrawPrompt = false
    @State private var aiDrawText = ""
    @State private var lastStrokeAnchor: CGPoint?
    /// False when the most recent stroke was a big shape/scribble (a circle, an
    /// underline, a doodle) rather than handwriting — used to suppress the proactive
    /// tutor so it doesn't fire after you annotate/doodle instead of solving.
    @State private var lastStrokeIsWriting = true
    @State private var askLassoActive = false
    @State private var showGuidedLog = false
    @State private var transformLassoActive = false
    /// Page-space point of a pending finger-tap "Paste" affordance (ink clipboard).
    @State private var pastePoint: CGPoint?
    /// Armed after a short delay so the content loader only shows for a SLOW load —
    /// a fast note switch shouldn't flash it (that read as a hiccup).
    @State private var loaderArmed = false
    @State private var strokeSelection: StrokeSelection?
    @State private var strokeRotation: Double = 0
    @State private var strokeTranslation: CGSize = .zero
    @State private var strokeScale: CGFloat = 1
    /// An ink-free lassoed region (image of a PDF/printed chunk) awaiting a
    /// copy / duplicate / delete choice from the pill.
    @State private var regionSelection: RegionSelection?
    @State private var circleAskRegion: CGRect?
    /// 4b Circle-to-ask — the inline rail state (page-anchored so it stays glued).
    @State private var circleRail: CircleRailState?
    /// Tap-to-define: cached OCR lines (page coords) for the current page, and the
    /// concept the student tapped (Lagrange, L'Hôpital, …) with its definition.
    @State private var conceptOCRLines: [OCRLine] = []
    @State private var conceptHit: ConceptHit?
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
        ForEach(tutor.bubbles.filter {
            // Hide the floating card while its conversation is open in the side
            // panel — otherwise the same thread shows in both places.
            $0.isPanelOnly != true && !(tutor.panelOpen && $0.id == tutor.panelBubbleID)
        }) { bubble in
            // 5b — the chat thread lives in the margin (collapsed connector chip /
            // open YOU·MARGIN conversation), replacing the AIBubbleView card.
            MarginThreadBubble(
                bubble: bubble,
                isLoading: tutor.loadingBubbleIDs.contains(bubble.id),
                transform: canvasController.transform(forPage: bubble.pageIndex),
                tutor: tutor
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
            // The canvas STAYS hit-testable while the lasso tool is armed so a
            // finger can still scroll/zoom the page (the lasso overlay above passes
            // finger touches through and captures only the pencil). The native
            // PKLassoTool can't fire because applyTool disables the canvas's drawing
            // gesture for the lasso tool, and the pencil is caught by the overlay
            // before it reaches the canvas. Only a committed selection / media /
            // shape edit takes the canvas out of play.
            .allowsHitTesting(selectedMediaID == nil && strokeSelection == nil)

            // Loader over the canvas until the page's content (ink/PDF) is up — but
            // only after a short delay (loaderArmed), so a fast note switch doesn't
            // flash it (that flash read as a hiccup). Still masks the stale-ink flash.
            let showLoader = !canvasController.isContentReady && loaderArmed
            themeDesk
                .ignoresSafeArea()
                .overlay { if showLoader { ProgressView().controlSize(.large).tint(.secondary) } }
                .opacity(showLoader ? 1 : 0)
                // Never eat touches — the loader is a visual mask only. Blocking
                // hits here meant you couldn't swipe/scroll for the first ~150ms
                // after entering a note. Finger pans now reach the scroll view.
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.25), value: showLoader)
                .zIndex(50)
                .task {
                    // Short enough that opening a note reliably shows the loader
                    // while it builds, long enough that a near-instant load doesn't
                    // flash it.
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    if !canvasController.isContentReady { loaderArmed = true }
                }

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
            GeometryGate(geometry: canvasController.geometry) {
                MediaLayer(items: $mediaItems, transform: transform, selectedItemID: $selectedMediaID, snap: snapMetrics,
                           onAutoScroll: { canvasController.autoScroll(by: $0) })
            }
            GeometryGate(geometry: canvasController.geometry) {
                TextBoxLayer(boxes: $textBoxes, transform: transform, editingBoxID: $editingBoxID, snap: snapMetrics)
            }

            // Above the margin glyphs — a chat bubble must never sit under a ✓/~/?.
            GeometryGate(geometry: canvasController.geometry) {
                aiOverlays
            }
            .zIndex(1)

            // Coloured highlights over the ink each expanded guided step is about
            // — same colour as that step's badge, so the student sees the link.
            GeometryGate(geometry: canvasController.geometry) {
                ForEach(guidedMode.stepHighlights) { h in
                    let r = transform.toScreen(h.rect).insetBy(dx: -4, dy: -2)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(h.color.opacity(0.20))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(h.color.opacity(0.7), lineWidth: 1.5))
                        .frame(width: max(r.width, 8), height: max(r.height, 8))
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .zIndex(2)

            // The Ambient Tutor's margin lane: glyphs anchored to the lines of
            // work, and the note that unfolds from a tapped glyph.
            GeometryGate(geometry: canvasController.geometry) {
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
                        // The line's rect HEIGHT is inflated by fractions (num+rule+
                        // denom), so * 0.95 wrote huge ink. Match the student's glyph
                        // size: a much smaller factor, capped ~handwriting size.
                        let fontSize = max(15, min(24, rect.height * 0.42))
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
                            on: canvasController.vectorCanvas
                        )
                    }
                },
                onShowWhy: { item in
                    // Show the why INSIDE the note (keep it open); tagged with the item so
                    // it renders inline in the bubble, not as a separate floating card.
                    let anchor = CGPoint(x: item.anchorRect.midX, y: item.anchorRect.maxY)
                    Task { await ambient.explainSteps(focus: item.body, anchor: anchor, pageIndex: pageIndex, note: note, darkMode: colorScheme == .dark, itemID: item.id) }
                },
                onOpenHint: { item in
                    // A watcher's "?" — highlight the line it flagged RIGHT AWAY, then
                    // show the worked steps inline (the step UI), NOT the chat bubble.
                    ambient.focus(on: item)
                    let anchor = CGPoint(x: item.anchorRect.midX, y: item.anchorRect.maxY)
                    Task { await ambient.explainSteps(focus: item.body, anchor: anchor, pageIndex: pageIndex, note: note, darkMode: colorScheme == .dark) }
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
                        on: canvasController.vectorCanvas
                    )
                    ambient.invalidateGhost()
                },
                // The "✦ Find my mistake" pill — stream the ✓ / ~ verdict glyphs (marks
                // where without spoiling the fix; tap a ~ for the note, "Fix it" to reveal).
                onGrade: {
                    ambient.clearGradePrompt()
                    canvasController.commitPendingInk()
                    Task { await ambient.checkWork(note: note, pageIndex: pageIndex, darkMode: colorScheme == .dark) }
                },
                // 3b "Fix it" — write the fix as amber ink just below the broken line.
                onDiagnosticFix: { err, rect in
                    ambient.dismissDiagnostic()
                    let fontSize = max(15, min(24, rect.height * 0.42))
                    let point = CGPoint(x: rect.minX, y: rect.maxY + 6)
                    tutor.writeInk(
                        text: err.fixLatex,
                        at: point,
                        fontSize: fontSize,
                        colorHex: ambientInkHex,
                        avoid: ambient.lastLineRects,
                        on: canvasController.vectorCanvas
                    )
                },
                // 3b "Show the rule" — worked steps for the break, in the inline step UI.
                onDiagnosticShowRule: { err, rect in
                    ambient.dismissDiagnostic()
                    let anchor = CGPoint(x: rect.midX, y: rect.maxY)
                    Task { await ambient.explainSteps(focus: err.why, anchor: anchor, pageIndex: pageIndex, note: note, darkMode: colorScheme == .dark) }
                }
            )
            }

            // Ambient tutor result banner ("looks all good" / error). Thinking
            // itself is the breathing corner badge below.
            ambientStatusHUD

            // ANY AI work — Check my work, Circle & Ask, Explain, Answer in Ink —
            // shows one breathing sparkle in the top corner so "the AI is
            // thinking" (replaces the old 'Checking your work…' pill).
            // Ghost Witness: faint dashed guide lines fitted over the sketch.
            if let g = ghostWitness.geometry, g.pageIndex == pageIndex {
                GeometryGate(geometry: canvasController.geometry) {
                    GhostWitnessOverlay(
                        geometry: g,
                        transform: canvasController.canvasTransform(forPage: pageIndex),
                        onDismiss: { ghostWitness.dismiss() }
                    )
                }
                .zIndex(35)
            }
            if let notice = ghostWitness.notice ?? warpTunnel.notice {
                VStack {
                    Text(notice)
                        .font(.subheadline)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(SemanticColor.separator))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                        .padding(.top, 100)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                .allowsHitTesting(false)
                .zIndex(36)
            }

            // Warp Tunnel: slide-up preview of the question page.
            if let preview = warpTunnel.preview {
                WarpTunnelPanel(preview: preview, onDismiss: { warpTunnel.dismiss() })
                    .zIndex(55)
            }


            if tutor.isThinking || ambient.isChecking || ambient.isSuggesting || guidedMode.isWatching || ghostWitness.isFitting {
                AIThinkingBadge()
                    .padding(.top, 84)
                    .padding(.trailing, showPageStrip ? 120 : 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: tutor.isThinking || ambient.isChecking || ambient.isSuggesting || guidedMode.isWatching || ghostWitness.isFitting)
            }

            // Note title + creation time in the desk gutter above the first
            // page (scrolls/zooms with the page) — never over ink.
            GeometryGate(geometry: canvasController.geometry) {
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

            // Lasso CAPTURE overlay — draw-only now (the loop is captured by the
            // engine's pencil gesture, so a finger still scrolls the page). It
            // reads the live loop points and just renders the marching ants.
            GeometryGate(geometry: canvasController.geometry) {
                TransformLassoOverlay(
                    isActive: $transformLassoActive,
                    rectangular: canvasController.lassoRectangular,
                    transform: canvasController.transform(forPage: pageIndex),
                    points: canvasController.lassoPoints,
                    onCancel: { canvasController.select(.ballpoint) }
                )
            }

            // Tap-to-define a concept (Lagrange, L'Hôpital, …).
            if let hit = conceptHit {
                GeometryGate(geometry: canvasController.geometry) {
                    ConceptDefinitionCard(hit: hit, transform: transform) {
                        withAnimation { conceptHit = nil }
                    }
                }
                .zIndex(45)
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
                // Above the paste / region pills so a pill never covers the toolbar (#4).
                .zIndex(48)

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

            // Circle & Ask lasso capture layer (4b — the selection morphs into an
            // inline rail; no modal).
            GeometryGate(geometry: canvasController.geometry) {
                AskLassoOverlay(isActive: $askLassoActive, transform: transform) { region in
                    let resolved = resolveCirclePage(screenRect: region)
                    let pages = note.sortedPages
                    let crop = pages.indices.contains(resolved.index)
                        ? croppedImage(of: resolved.pageRect, page: pages[resolved.index]) : nil
                    circleRail = CircleRailState(screenRect: region, pageIndex: resolved.index, crop: crop)
                }
            }
            circleRailLayer


            if let selection = strokeSelection {
                StrokeTransformOverlay(
                    selection: selection,
                    transform: canvasController.transform(forPage: selection.pageIndex),
                    rotation: $strokeRotation,
                    translation: $strokeTranslation,
                    scale: $strokeScale,
                    onDone: applyStrokeTransform,
                    onCancel: {
                        canvasController.engine?.cancelVectorSelection()
                        clearStrokeSelection()
                    },
                    canPaste: false,
                    onCut: { canvasController.engine?.deleteVectorSelection(); clearStrokeSelection() },
                    onCopy: {
                        let t = selectionTransform(selection)
                        canvasController.engine?.commitVectorSelection(rotation: t.0, scale: t.1, translation: t.2, selection: selection)
                        clearStrokeSelection()
                    },
                    onPaste: { canvasController.engine?.cancelVectorSelection(); clearStrokeSelection() },
                    onDuplicate: {
                        let t = selectionTransform(selection)
                        canvasController.engine?.duplicateVectorSelection(rotation: t.0, scale: t.1, translation: t.2, selection: selection)
                        clearStrokeSelection()
                    },
                    onDelete: { canvasController.engine?.deleteVectorSelection(); clearStrokeSelection() }
                )
            }

            // Finger-tap paste menu (our theme): tap empty space with something
            // pasteable → Paste (ink) · Paste image · Insert space, right there.
            if let pt = pastePoint {
                // pastePoint is PAGE space, so map it through the PAGE transform —
                // canvasTransform (inkScale× space) put the pill ~4× off the finger.
                let screen = transform.toScreen(pt)
                HStack(spacing: 0) {
                    if canvasController.hasPasteContent {
                        pasteMenuItem("media.paste") {
                            // Paste the ink, then select it (transform mode) so it
                            // can be moved/resized right away.
                            if let bounds = canvasController.engine?.pasteStrokes(at: pt) {
                                let r = bounds.insetBy(dx: -6, dy: -6)
                                beginStrokeTransform(with: [
                                    CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                                ])
                            }
                            dismissPasteMenu()
                        }
                    } else if UIPasteboard.general.hasImages {
                        // ONLY when there's a genuine external image and no in-app ink:
                        // copying ink also drops a system image, which made "Paste
                        // image" appear redundantly after an ink copy (#7).
                        pasteMenuItem("media.pasteImage") { pasteImage(at: pt); dismissPasteMenu() }
                    }
                }
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
                .fixedSize()
                .position(x: screen.x, y: max(44, screen.y - 28))
                // New identity per spot so it fades in fresh at the new point
                // instead of sliding from the previous position.
                .id(pt)
                .transition(.opacity)
                .zIndex(40)
            }

            // Ink-free lassoed region → copy / duplicate / delete pill (the lasso
            // caught no editable strokes, so we treat the area as an image).
            if let region = regionSelection {
                GeometryGate(geometry: canvasController.geometry) {
                let r = transform.toScreen(region.pageRect)
                ZStack {
                    // Same marching ants as the ink lasso (animated, same colour),
                    // following the SHAPE as drawn (not a rectangle).
                    TimelineView(.animation) { context in
                        let secs = context.date.timeIntervalSinceReferenceDate
                        let phase = -CGFloat(secs.truncatingRemainder(dividingBy: 0.5) / 0.5) * 12
                        Path { p in
                            let pts = region.polygon.map { transform.toScreen($0) }
                            guard let f = pts.first else { return }
                            p.move(to: f)
                            for pt in pts.dropFirst() { p.addLine(to: pt) }
                            p.closeSubpath()
                        }
                        .stroke(SemanticColor.aiCircleStroke,
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [7, 5], dashPhase: phase))
                    }
                    .allowsHitTesting(false)
                    HStack(spacing: 0) {
                        pasteMenuItem("media.copy") { copyRegion(region); withAnimation { regionSelection = nil } }
                        pasteMenuDivider
                        pasteMenuItem("media.duplicate") { duplicateRegion(region); withAnimation { regionSelection = nil } }
                        pasteMenuDivider
                        pasteMenuItem("action.delete") { deleteRegion(region); withAnimation { regionSelection = nil } }
                    }
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
                    .fixedSize()
                    .position(x: r.midX, y: max(44, r.minY - 28))
                }
                .transition(.opacity)
                }
                .zIndex(41)
            }

            // (Handoff §1) The guided suggestion no longer POPS UP a bottom card —
            // it becomes a dormant lane glyph (placed via onChange below) that the
            // student taps to open the inline step card. No auto-opening surface.

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
                            Label("ai.guidedMode", systemImage: "sparkles")
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
        // Ambient: each new stroke clears any pending suggestion and re-arms the
        // single arbiter; when the pen rests, the arbiter emits AT MOST ONE thing.
        .onChange(of: canvasController.drawingGestureBeganToken) { _, _ in
            scheduleAmbient()
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
                        on: canvasController.vectorCanvas,
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
                Task { await tutor.drawSketch(request: request, on: canvasController.vectorCanvas) }
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
            ghostWitness.tutor = tutor
            // Proactive watching is now owned entirely by the single arbiter
            // (scheduleAmbient), gated on ambient.sensitivity. The legacy
            // guidedMode controller is kept inert — enabling it would re-introduce
            // the parallel AI call AND a checkPage() on note-open (the "guide
            // popped up the moment I entered the page" misfire).
            guidedMode.isEnabled = false
            audio.attach(note: note)
            // DEV: eyeball the 3b diagnostic surface in-editor without an API key.
            if ProcessInfo.processInfo.environment["CONOTE_DEMO_CHECK"] != nil {
                let size = pageSize
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    ambient.injectDemoDiagnostic(pageIndex: pageIndex, pageSize: size)
                }
            }
            // DEV: eyeball the 4b circle-to-ask rail + answer in-editor without a key.
            if ProcessInfo.processInfo.environment["CONOTE_DEMO_CIRCLE"] != nil {
                let size = pageSize
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    let rect = CGRect(x: 90, y: 300, width: 240, height: 30)
                    circleRail = CircleRailState(
                        screenRect: rect, pageIndex: pageIndex, crop: nil, selected: .explain,
                        result: AIClient.CircleResult(
                            explain: "A chain of proteins in the inner mitochondrial membrane. Electrons released from glucose hop down it; each hop pumps H⁺ out, building a gradient that drives ATP synthase.",
                            simpler: "A bucket brigade for electrons — each hand-off shoves a proton uphill, storing 'pressure' that later spins a turbine (ATP synthase).",
                            analogy: nil,
                            quiz: nil), loading: false)
                }
            }
            // DEV: eyeball the 2a fill-in ghost (Subtle no-spoiler + blank token).
            if ProcessInfo.processInfo.environment["CONOTE_DEMO_GHOST"] != nil {
                let size = pageSize
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    ambient.sensitivity = .subtle
                    ambient.ghost = GhostSuggestion(
                        pageIndex: pageIndex, anchor: CGPoint(x: size.width * 0.16, y: size.height * 0.34),
                        text: "= sin(u) + C",
                        why: "You've reduced it to ∫ cos(u) du. The antiderivative of cosine is sine — so the blank fills with u.",
                        steps: [], inline: false, highlights: [], blankToken: "u")
                }
            }
            // DEV: eyeball the 5b margin chat thread in-editor without a key.
            if ProcessInfo.processInfo.environment["CONOTE_DEMO_CHAT"] != nil {
                let size = pageSize
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    var b = AIBubbleModel(pageIndex: pageIndex, anchorX: size.width * 0.18, anchorY: size.height * 0.22,
                                          x: size.width * 0.18, y: size.height * 0.22)
                    b.thread = [AIExchange(question: "where did the 2x go?",
                                           answer: "Good eye — what did you multiply by when you set $du = 2x\\,dx$? Look at where that factor lands in the next line.")]
                    b.chips = ["show me the substitution", "is the 2x always there?"]
                    tutor.bubbles.append(b)
                }
            }
            canvasController.onStroke = { index, stroke in
                let center = CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY)
                if index == pageIndex { lastStrokeAnchor = center }
                // Editing the page invalidates a shown diagnostic (§7 auto-resolve).
                if ambient.diagnostic != nil { ambient.dismissDiagnostic() }
                // Only a handwriting stroke should arm the proactive tutor. Two tells
                // that a stroke is a DIAGRAM/doodle (axis, graph curve, underline,
                // circle), not writing: it's big, OR it's a long near-straight line
                // (path length ≈ its diagonal). Handwriting is small AND curvy.
                let diag = hypot(stroke.renderBounds.width, stroke.renderBounds.height)
                let straightness = diag > 1 ? Self.strokeLength(stroke) / diag : 2
                let isLine = straightness < 1.3 && diag > 55
                lastStrokeIsWriting = diag < 170 && !isLine
                audio.logStroke(at: center, pageIndex: index)
                // NOTE: the legacy guidedMode per-stroke watcher used to fire a
                // SECOND proactive AI call here (in parallel with the arbiter in
                // scheduleAmbient), giving two AI calls + two surfaces per pause
                // and firing on the wrong context. The single arbiter (armed on
                // drawingGestureBeganToken) is now the sole proactive source.
                // Erasing fires this too: drop any glyph whose ink is now gone.
                let inkRects = (canvasController.vectorCanvas?.currentStrokes() ?? []).map(\.bbox)
                ambient.pruneGlyphs(pageIndex: index, inkRects: inkRects)
                // Editing a graded line (a new stroke ON it) resolves its glyph.
                ambient.resolveGlyphs(pageIndex: index, editedBy: stroke.renderBounds)
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
            canvasController.inkDataProvider = { [weak note] index in
                MainActor.assumeIsolated {
                    guard let note else { return (nil, nil) }
                    let pages = note.sortedPages
                    guard pages.indices.contains(index) else { return (nil, nil) }
                    return (pages[index].vectorInkData, pages[index].drawingData)
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
                // A tap dismisses the ink-free region pill.
                if regionSelection != nil {
                    withAnimation { regionSelection = nil }
                    rearmLassoIfActive()
                    return
                }
                // Tap a recognised concept (Lagrange, L'Hôpital, …) → show its
                // definition. Glossary match is instant; an unlisted term defers
                // to the AI (silently — the card only appears if it IS a concept).
                if let line = conceptOCRLines.first(where: { $0.rect.insetBy(dx: -10, dy: -10).contains(point) }) {
                    if let (concept, hebrew) = ConceptGlossary.match(in: line.text) {
                        Haptics.selection()
                        let he = hebrew || preferHebrewDefinitions
                        withAnimation {
                            conceptHit = ConceptHit(term: concept.title, pageRect: line.rect,
                                                    definition: he ? concept.definitionHE : concept.definitionEN)
                        }
                        return
                    }
                    if AIConfig.isConfigured,
                       line.text.split(whereSeparator: { !$0.isLetter }).contains(where: { $0.count >= 4 }) {
                        let rect = line.rect, text = line.text
                        Task {
                            if var hit = await ConceptLookup.defineWithAI(lineText: text) {
                                hit.pageRect = rect
                                await MainActor.run { Haptics.selection(); withAnimation { conceptHit = hit } }
                            }
                        }
                    }
                }
                if conceptHit != nil { withAnimation { conceptHit = nil } }
                if let hit = mediaItems.last(where: { $0.frame.contains(point) }) {
                    Haptics.selection()
                    selectedMediaID = hit.id
                    pastePoint = nil
                } else if tapSelectStrokes(at: point) {
                    // Tapped on ink → select that shape/cluster for move/resize/rotate.
                    selectedMediaID = nil
                } else {
                    selectedMediaID = nil
                    if pastePoint != nil {
                        // Menu already up → a tap elsewhere just dismisses it.
                        withAnimation { pastePoint = nil }
                    } else if canvasController.hasPasteContent || UIPasteboard.general.hasImages {
                        // Empty-space tap with something pasteable → our paste menu.
                        Haptics.selection()
                        withAnimation(.easeOut(duration: 0.15)) { pastePoint = point }
                    }
                }
            }
            // The engine's pencil lasso gesture finished a loop (CANVAS-coord
            // points — same space as canvas.drawing) → turn it into a selection.
            // Freeform keeps its drawn shape; the marquee uses the bounding rect.
            canvasController.onLassoComplete = { canvasPoints in
                guard canvasPoints.count >= 3 else { return }
                let polygon: [CGPoint]
                if canvasController.lassoRectangular {
                    let xs = canvasPoints.map(\.x), ys = canvasPoints.map(\.y)
                    let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                    polygon = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
                } else {
                    polygon = canvasPoints
                }
                beginStrokeTransform(with: polygon)
            }
            // A NEW lasso loop is starting — commit/clear any prior selection so the
            // second loop draws live and the first doesn't linger underneath (#3/#4).
            canvasController.onLassoBegan = {
                if strokeSelection != nil { applyStrokeTransform() }
                if regionSelection != nil { regionSelection = nil }
                // A region selection had hidden the lasso overlay — re-arm it so the
                // new loop is visible while it's drawn.
                rearmLassoIfActive()
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
            // A lasso selection holds strokes OUT of the ink — commit it before the
            // page (and its drawing) is saved and swapped, so nothing is lost.
            if strokeSelection != nil {
                applyStrokeTransform()
                strokeSelection = nil
            }
            // A lasso selection belongs to the page it was drawn on — drop it on a
            // page change so it doesn't follow you to the next page.
            regionSelection = nil
            canvasController.lassoPoints = []
            guidedMode.clearHighlights()   // step highlights belong to the page they're on
            persistOverlays(to: page(at: oldIndex))
            canvasController.engine?.refreshPage(oldIndex)
            loadPage()
            // Remember where the user is so re-opening the note returns here.
            if let key = note.id?.uuidString {
                UserDefaults.standard.set(newIndex, forKey: "note.lastPage.\(key)")
            }
            tutor.pageChanged(to: newIndex)
            // (Legacy guidedMode.pageTurned() removed — it fired an unprompted
            // proactive AI call on every page turn. The arbiter only acts when
            // the pen actually rests, so a page turn alone no longer nags.)
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
            // Picking a different tool deselects whatever's currently selected
            // (committing any in-progress move first), so you can't draw with a
            // stray selection still active.
            if strokeSelection != nil { applyStrokeTransform() }
            if regionSelection != nil { withAnimation { regionSelection = nil } }
            selectedMediaID = nil
            editingBoxID = nil
            if kind == .lasso {
                withAnimation { transformLassoActive = true }
            } else if transformLassoActive {
                withAnimation { transformLassoActive = false }
            }
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
        .alert(Text("ai.error"), isPresented: aiErrorBinding) {
            // A missing key is a dead-end with only "Done" — give a one-tap path
            // to set AI up instead of making the user leave the note to find it.
            if !AIConfig.isConfigured {
                Button("settings.ai.openSettings") {
                    tutor.errorMessage = nil
                    showAISettings = true
                }
            }
            Button("action.done", role: .cancel) { tutor.errorMessage = nil }
        } message: {
            Text(tutor.errorMessage ?? "")
        }
        .sheet(isPresented: $showAISettings) { SettingsView() }
    }

    private var aiErrorBinding: Binding<Bool> {
        Binding(get: { tutor.errorMessage != nil }, set: { if !$0 { tutor.errorMessage = nil } })
    }

    private var circleAskBinding: Binding<Bool> {
        Binding(get: { circleAskRegion != nil }, set: { if !$0 { circleAskRegion = nil } })
    }

    /// 4b Circle-to-ask state — the lassoed span captured in SCREEN space (fixed where
    /// you circled; it does NOT track the pan/scroll, which felt wrong), plus the crop
    /// + page for the AI call and the fetched verbs.
    struct CircleRailState {
        var screenRect: CGRect
        var pageIndex: Int
        var crop: UIImage?
        var selected: CircleVerb?
        var result: AIClient.CircleResult?
        var loading = false
    }

    /// The inline rail + pill + answer card, pinned to the fixed screen rect where the
    /// span was circled (does not follow the pan).
    @ViewBuilder private var circleRailLayer: some View {
        if let rail = circleRail {
            GeometryReader { geo in
                let r = rail.screenRect
                // A soft pill that HUGS the content, pulled in from the loose lasso box.
                let pw = max(30, r.width * 0.8), ph = max(20, min(r.height, 40))
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AITokens.ai.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(AITokens.ai.opacity(0.40)))
                        .frame(width: pw, height: ph)
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                    // The inline verb rail slides out beside it on the same line.
                    SelectionRail(
                        selected: rail.selected,
                        onVerb: { selectCircleVerb($0) },
                        onClose: { withAnimation(.easeOut(duration: 0.2)) { circleRail = nil } })
                        .fixedSize()
                        .position(x: min(r.midX + pw / 2 + 80, geo.size.width - 96),
                                  y: min(max(r.midY, 70), geo.size.height - 70))
                    // The answer unfolds directly beneath the circled line.
                    if let verb = rail.selected {
                        CircleAnswerCard(verb: verb, result: rail.result, isLoading: rail.loading)
                            .frame(width: 300)
                            .position(x: min(max(r.midX, 170), geo.size.width - 170),
                                      y: min(r.maxY + 100, geo.size.height - 120))
                            .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    /// Fetch the circle answer for a tapped verb (once — all three come in one call).
    private func selectCircleVerb(_ verb: CircleVerb) {
        guard var rail = circleRail else { return }
        let hadResult = rail.result != nil
        rail.selected = verb
        if !hadResult { rail.loading = true }
        withAnimation(.easeOut(duration: 0.2)) { circleRail = rail }
        guard !hadResult else { return }
        let pageIndex = rail.pageIndex
        let crop = rail.crop
        let level = ambient.sensitivity.rawValue
        Task {
            let pages = note.sortedPages
            guard pages.indices.contains(pageIndex) else { return }
            let ocr = await NoteContextBuilder.ocrLines(for: pages[pageIndex])
            let envelope = AIClient.buildEnvelope(
                lines: ocr, focusLine: nil, guidedLevel: level, askDepth: 1)
            let region = crop?.downsampled(maxDimension: 1024).pngData()
            let result = try? await AIClient.call(
                .circle, envelope: envelope, region: region,
                extra: "The circled span is the attached image — answer about THAT span, with its surrounding context.",
                as: AIClient.CircleResult.self)
            await MainActor.run {
                guard var current = circleRail else { return }
                current.result = result
                current.loading = false
                withAnimation(.easeOut(duration: 0.2)) { circleRail = current }
            }
        }
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
        // The AI focuses ONLY on this crop, so render it the way a vision model reads best:
        // clean white paper, no ruled-line noise, dark ink on white, high-res — regardless
        // of the user's dark mode.
        let full = PageRenderer.recognitionImage(PageRenderer.Snapshot(page: page), scale: 3)
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
    /// Tap-to-select a shape: find the ink under the finger and hand it to the same
    /// transform pipeline the lasso uses (move/resize/rotate). Returns true if it
    /// selected something. `point` is in canvas/page space (same as the strokes).
    private func tapSelectStrokes(at point: CGPoint) -> Bool {
        let strokes = canvasController.vectorCanvas?.currentStrokes() ?? []
        guard !strokes.isEmpty else { return false }
        let tapR: CGFloat = 24
        func area(_ r: CGRect) -> CGFloat { max(r.width, 1) * max(r.height, 1) }
        // ONLY shapes are tap-selectable, never handwriting. Detect shape-ness
        // GEOMETRICALLY (not a stored tag — that would be lost on transform): a
        // snapped line/circle/rectangle is clean enough that ShapeRecognizer
        // re-recognises it; messy writing isn't. minDiagonal mirrors the auto-shape
        // floor so handwriting-sized marks don't count.
        func isShape(_ s: VectorInk.Stroke) -> Bool { ShapeRecognizer.recognize(s, minDiagonal: 60) != nil }
        // Prefer strokes whose INK is under the finger (tapping on the line); fall
        // back to strokes whose bounds enclose the tap (tapping inside a closed shape).
        var hits = strokes.filter { s in
            isShape(s) && s.bbox.insetBy(dx: -tapR, dy: -tapR).contains(point)
                && s.samples.contains { hypot($0.location.x - point.x, $0.location.y - point.y) <= tapR + $0.width }
        }
        if hits.isEmpty { hits = strokes.filter { isShape($0) && $0.bbox.contains(point) } }
        // Most specific = smallest bounds; then grow to the connected shape (other
        // SHAPE strokes whose bounds overlap it — e.g. the 4 sides of a rectangle).
        guard let primary = hits.min(by: { area($0.bbox) < area($1.bbox) }) else { return false }
        var bounds = primary.bbox
        for s in strokes where isShape(s) && s.bbox.intersects(primary.bbox.insetBy(dx: -2, dy: -2)) {
            bounds = bounds.union(s.bbox)
        }
        let r = bounds.insetBy(dx: -1, dy: -1)
        beginStrokeTransform(with: [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)
        ])
        return strokeSelection != nil
    }

    private func beginStrokeTransform(with polygon: [CGPoint]) {
        let strokes = canvasController.vectorCanvas?.currentStrokes() ?? []
        strokeRotation = 0
        strokeTranslation = .zero
        strokeScale = 1
        // Select straight from the vector strokes (PAGE space) — no PencilKit round-trip.
        if let selection = StrokeSelector.vectorSelection(
            from: strokes,
            polygon: polygon,
            pageIndex: pageIndex,
            darkMode: colorScheme == .dark
        ) {
            Haptics.selection()
            strokeSelection = selection
            canvasController.engine?.liftVectorSelection(selection.strokeIndices)
        } else {
            // No editable ink in the loop — select the lassoed REGION (a chunk of
            // PDF / printed problem) and offer copy / duplicate / delete via a pill,
            // instead of auto-copying.
            if let region = makeRegionSelection(canvasPolygon: polygon) {
                Haptics.selection()
                regionSelection = region
                withAnimation { transformLassoActive = false }
            } else {
                Haptics.error()
                rearmLassoIfActive()
            }
        }
    }

    /// Render a flat image of the lassoed region (page background + PDF + media +
    /// ink). The captured image is the RECTANGULAR bounding box of the loop (the
    /// on-canvas outline still traces the freeform shape via `polygon`); copy /
    /// duplicate produce a clean rectangle, not a clipped silhouette. `polygon` is
    /// in the canvas's inkScale× space.
    private func makeRegionSelection(canvasPolygon polygon: [CGPoint]) -> RegionSelection? {
        guard let page = currentPage, polygon.count >= 3 else { return nil }
        let pagePoly = polygon   // already PAGE coords (vector lasso, no inkScale)
        let xs = pagePoly.map(\.x), ys = pagePoly.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              maxX - minX > 8, maxY - minY > 8 else { return nil }
        let region = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let scale: CGFloat = 3
        let full = PageRenderer.render(PageRenderer.Snapshot(page: page), darkMode: colorScheme == .dark, scale: scale)
        guard let cgFull = full.cgImage else { return nil }
        let imgBounds = CGRect(x: 0, y: 0, width: cgFull.width, height: cgFull.height)
        let px = CGRect(x: region.minX * scale, y: region.minY * scale,
                        width: region.width * scale, height: region.height * scale).intersection(imgBounds)
        guard !px.isEmpty, let cropped = cgFull.cropping(to: px) else { return nil }
        // Crop straight from the rendered page's cgImage — already in display
        // orientation, so the copy is upright (the mask path flipped it) and
        // rectangular.
        return RegionSelection(polygon: pagePoly, pageRect: region,
                               image: UIImage(cgImage: cropped, scale: scale, orientation: .up))
    }

    private func copyRegion(_ region: RegionSelection) {
        UIPasteboard.general.image = region.image
        Haptics.success()
    }

    /// Drop the lassoed region back onto the page as a movable image.
    private func duplicateRegion(_ region: RegionSelection) {
        guard let data = region.image.pngData() ?? region.image.jpegData(compressionQuality: 0.9),
              let name = MediaStore.save(data) else { Haptics.error(); return }
        let r = region.pageRect
        let item = MediaItemModel(fileName: name, x: r.minX + 24, y: r.minY + 24, width: r.width, height: r.height)
        mediaItems.append(item)
        persistOverlays()
        // Don't auto-select the copy: its media action bar popped up right where
        // the region pill was and read as "the pill is still there". Tap the copy
        // to move it.
        selectedMediaID = nil
        Haptics.success()
    }

    /// Remove media whose center sits inside the lassoed region (the only
    /// deletable content under an ink-free loop).
    private func deleteRegion(_ region: RegionSelection) {
        let r = region.pageRect
        let before = mediaItems.count
        mediaItems.removeAll { r.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        if mediaItems.count != before { persistOverlays(); Haptics.success() } else { Haptics.tap() }
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
            canvasController.engine?.cancelVectorSelection()
            return
        }
        // The overlay drag is in screen points; convert to PAGE space (where the vector
        // strokes live) by dividing out the zoom.
        let zoom = canvasController.transform(forPage: selection.pageIndex).zoomScale
        let pageTranslation = CGSize(width: strokeTranslation.width / zoom,
                                     height: strokeTranslation.height / zoom)
        canvasController.engine?.commitVectorSelection(
            rotation: strokeRotation, scale: strokeScale, translation: pageTranslation, selection: selection)
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

/// A lassoed region with no editable ink — a flat image of that page area
/// (masked to the drawn shape), offered for copy / duplicate / delete via a pill.
struct RegionSelection {
    var polygon: [CGPoint]   // page coords — the lassoed shape, as drawn
    var pageRect: CGRect     // bounding box (page coords) — pill anchor + crop
    var image: UIImage       // masked to the polygon
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

    /// Tap-to-define shows the Hebrew definition when the device prefers Hebrew
    /// (a Hebrew-script term always shows Hebrew regardless).
    private var preferHebrewDefinitions: Bool {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("he")
    }

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

    /// Approx on-screen length of a stroke (sum of sampled segment lengths). A
    /// near-straight line has length ≈ its bounding-box diagonal; handwriting is
    /// far curvier — used to keep the tutor from firing on diagram lines.
    private static func strokeLength(_ stroke: PKStroke) -> CGFloat {
        let path = stroke.path
        guard path.count > 1 else { return 0 }
        let step = max(1, path.count / 48)
        var len: CGFloat = 0
        var prev = path[0].location
        for i in stride(from: step, to: path.count, by: step) {
            let p = path[i].location
            len += hypot(p.x - prev.x, p.y - prev.y)
            prev = p
        }
        return len
    }

    /// THE ARBITER (handoff §1, "the one rule"): every idle pause runs through one
    /// place that emits AT MOST ONE proactive surface — never a ghost AND a grade
    /// pill on the same pause. Writing again clears whatever was up and re-arms.
    ///
    /// Sensitivity = eligibility, not volume (§3.5):
    ///   off     → nothing
    ///   subtle  → grade offer only (no proactive ghost)
    ///   helpful → next-step ghost when there's a clear continuation, else a grade offer
    private func scheduleAmbient() {
        ghostIdleTask?.cancel()
        gradePromptTask?.cancel()
        ambient.invalidateGhost()
        ambient.clearGradePrompt()
        // Guided mode is its OWN proactive watcher (strokeOccurred → checkPage). When
        // it's on, don't also run the ambient idle ghost/grade — otherwise every
        // pen-pause fires two AI calls and shows two competing surfaces. Manual
        // check-my-work / suggest-next buttons still work.
        guard ambient.sensitivity != .off, !distractionFree, !guidedMode.isEnabled else { return }
        ghostIdleTask = Task {
            try? await Task.sleep(nanoseconds: 3_900_000_000)
            // Doodle / diagram line → the tutor stays silent (intent: sketching).
            guard !Task.isCancelled, lastStrokeIsWriting, !ambient.isChecking else { return }
            canvasController.commitPendingInk()
            let dark = colorScheme == .dark
            // Helpful: try the next-step continuation first. suggestNext(auto) only
            // fires on an UNFINISHED line (mid-derivation), so a finished line leaves
            // ghost == nil → fall through to the grade offer. One surface, never two.
            if ambient.sensitivity == .helpful {
                await ambient.suggestNext(note: note, pageIndex: pageIndex, darkMode: dark, auto: true)
            }
            guard !Task.isCancelled else { return }
            if ambient.ghost == nil, let anchor = lastStrokeAnchor {
                ambient.offerGrade(pageIndex: pageIndex, anchor: anchor)
            }
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
                ambient.sensitivity = $0   // the arbiter reads this; guidedMode stays inert
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
                Task { await ghostWitness.fit(note: note, pageIndex: pageIndex, darkMode: colorScheme == .dark) }
            } label: { Label("ai.fitSketch", systemImage: "scribble.variable") }
            Button {
                Task { await warpTunnel.showQuestion(note: note, currentPageIndex: pageIndex, darkMode: colorScheme == .dark) }
            } label: { Label("ai.showQuestion", systemImage: "arrow.up.left.and.arrow.down.right.rectangle") }
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

    /// Page jump: each chevron tap advances one page immediately and animates the
    /// scroll. (The live canvas only re-mounts when the scroll settles, so rapid
    /// taps no longer glitch the ink.)
    private func jumpPage(by delta: Int) {
        let count = note.sortedPages.count
        // Base the jump on the page the user currently SEES (live), so a tap after
        // a free-scroll goes to the right neighbour.
        let base = canvasController.visiblePageIndex
        let target = max(0, min(count - 1, base + delta))
        guard target != pageIndex else { return }
        Haptics.tap()
        pageIndex = target
    }

    /// Bottom-right: current page out of total, with up/down paging.
    private var pageIndicator: some View {
        // The LIVE page under the viewport (updates while scrolling); the canvas
        // still mounts at settle. Falls back to pageIndex before the first scroll.
        let shown = canvasController.visiblePageIndex
        return VStack(spacing: 0) {
            Button {
                jumpPage(by: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 34, height: 28)
            }
            .disabled(shown == 0)
            .accessibilityLabel(Text("page.previous"))

            Text(verbatim: "\(shown + 1)/\(note.sortedPages.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                jumpPage(by: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 34, height: 28)
            }
            .disabled(shown >= note.sortedPages.count - 1)
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
        conceptHit = nil
        refreshConceptLines()
    }

    /// Re-OCR the current page (off main) so tap-to-define knows where each line
    /// of writing sits. Cheap and cached; refreshed on page load and after edits.
    /// Deferred a beat so its page render doesn't pile onto the open-note render
    /// load (that contention produced black, ink-less pages).
    private func refreshConceptLines() {
        guard let page = currentPage else { conceptOCRLines = []; return }
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled, page == currentPage else { return }
            conceptOCRLines = await NoteContextBuilder.ocrLines(for: page)
        }
    }

    // MARK: - Finger-tap paste menu

    private func dismissPasteMenu() {
        Haptics.tap()
        withAnimation { pastePoint = nil }
    }

    private func pasteMenuItem(_ key: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(key)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pasteMenuDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 22)
    }

    /// Paste the system-clipboard image as a media item at the tap.
    private func pasteImage(at pagePoint: CGPoint) {
        guard let image = UIPasteboard.general.image,
              let data = image.pngData() ?? image.jpegData(compressionQuality: 0.9),
              let name = MediaStore.save(data) else { return }
        let w = min(image.size.width, 320)
        let h = w * (image.size.height / max(image.size.width, 1))
        let item = MediaItemModel(fileName: name, x: pagePoint.x - w / 2, y: pagePoint.y - h / 2, width: w, height: h)
        mediaItems.append(item)
        persistOverlays()
        selectedMediaID = item.id
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

    private func wireCanvasSave() {
        canvasController.onDrawingChanged = { [weak note] index, strokes in
            guard let note else { return }
            let pages = note.sortedPages
            guard pages.indices.contains(index) else { return }
            pages[index].vectorStrokes = strokes   // dual-writes vectorInkData + drawingData
            // Ink on the last page grows the document — there's always a fresh
            // page waiting below. (Empty pages stay out of the exported PDF.)
            if index == pages.count - 1, !strokes.isEmpty {
                _ = note.addPage()
            }
            // NOTE: the note's search index is NOT rebuilt here. Rebuilding it on
            // every debounced stroke scanned every page on the main thread while
            // the user was still writing — a real hiccup. Ink doesn't change the
            // recognized TEXT until OCR runs, so the rebuild moved into the
            // debounced OCR task (scheduleOCR), which only fires once writing
            // settles. This save just persists the ink.
            PersistenceController.shared.save()
            scheduleOCR(for: pages[index])
            // Erasing ink should clear any AI mark that pointed at it.
            tutor.pruneAnnotations(onPage: index, strokes: strokes)
            // Re-arm guided mode's pen-pause watcher (its trigger was lost in the
            // vector migration, so it stopped reacting to writing). No-op when off.
            guidedMode.strokeOccurred()
        }
    }

    /// Re-indexes handwriting a few seconds after the pen goes quiet, keeping
    /// search (and AI targeting) fresh without OCR-ing every stroke.
    private func scheduleOCR(for page: Page) {
        ocrTask?.cancel()
        ocrTask = Task { [weak note] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await OCRService.indexPage(page)
            // Refresh the search index ONCE, after OCR actually changed the
            // recognized text — moved off the per-stroke save path.
            guard !Task.isCancelled, let note else { return }
            await MainActor.run {
                note.searchableText = SearchableTextBuilder.build(for: note)
                PersistenceController.shared.save()
            }
            // Keep tap-to-define's line cache current with the latest writing.
            if !Task.isCancelled { await MainActor.run { refreshConceptLines() } }
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

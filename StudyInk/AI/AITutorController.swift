import SwiftUI

/// Orchestrates the AI tutor for one open note: sends requests with full note
/// context, parses bubbles/annotations/chips, and manages bubble lifecycle
/// (active → pinned on the page / dismissed into history).
@MainActor
final class AITutorController: ObservableObject {
    @Published var bubbles: [AIBubbleModel] = []
    @Published var history: [AIBubbleModel] = []
    @Published var loadingBubbleIDs: Set<UUID> = []
    /// In-flight non-bubble AI work (Answer in Ink, Draw on Canvas, …) so the
    /// editor can show one "thinking" indicator for any AI activity.
    @Published private(set) var pendingTasks = 0
    @Published var errorMessage: String?

    /// True whenever the tutor is working on anything (a bubble or an ink task).
    var isThinking: Bool { pendingTasks > 0 || !loadingBubbleIDs.isEmpty }

    func beginTask() { pendingTasks += 1 }
    func endTask() { pendingTasks = max(0, pendingTasks - 1) }
    @Published var panelOpen = false
    @Published var panelBubbleID: UUID?

    private(set) weak var note: Note?
    var currentPageIndex = 0
    var isDarkMode = false

    func attach(note: Note) {
        guard self.note != note else { return }
        self.note = note
        history = AIHistoryStore.load(noteID: note.id)
        loadPinnedBubbles()
    }

    /// Bubbles for the page currently on screen; others collapse automatically.
    var visibleBubbles: [AIBubbleModel] {
        bubbles.filter { $0.pageIndex == currentPageIndex }
    }

    var currentPage: Page? {
        guard let note else { return nil }
        let pages = note.sortedPages
        guard pages.indices.contains(currentPageIndex) else { return nil }
        return pages[currentPageIndex]
    }

    // MARK: - Asking

    /// Creates a bubble anchored at `anchor` and asks Claude with full note context.
    func ask(
        question: String,
        anchor: CGPoint,
        focusRegion: CGRect? = nil,
        focusImage: UIImage? = nil,
        systemHint: String? = nil,
        panelOnly: Bool = false
    ) async {
        guard let note, let page = currentPage else { return }
        let pageSize = page.canvasSize
        let position = AIBubbleModel.position(anchor: anchor, pageSize: pageSize)
        var bubble = AIBubbleModel(
            pageIndex: currentPageIndex,
            anchorX: anchor.x, anchorY: anchor.y,
            x: position.x, y: position.y
        )
        bubble.thread = [AIExchange(question: question, answer: "")]
        if panelOnly {
            bubble.isPanelOnly = true
            panelBubbleID = bubble.id
        }
        bubbles.append(bubble)
        loadingBubbleIDs.insert(bubble.id)
        defer { loadingBubbleIDs.remove(bubble.id) }

        do {
            let context = await NoteContextBuilder.build(
                note: note,
                currentPageIndex: currentPageIndex,
                darkMode: isDarkMode,
                focusRegion: focusRegion,
                focusImage: focusImage,
                focusAnchor: anchor   // where the student is working → orient the answer
            )
            var blocks = context.blocks
            blocks.append(.text("Student question: \(question)"))
            if let systemHint { blocks.append(.text(systemHint)) }

            let raw = try await AIService.send(
                system: SystemPrompt.tutor(subjectContext: note.subjectContext ?? "general"),
                messages: [.user(blocks)],
                maxTokens: 2400   // room for a full worked explanation (was truncating mid-$…$)
            )
            let parsed = AIResponseParser.parse(raw)
            let lines = await NoteContextBuilder.ocrLines(for: page)
            apply(parsed: parsed, to: bubble.id, ocrLines: lines)
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
            bubbles.removeAll { $0.id == bubble.id }
        }
    }

    /// Threads a follow-up inside an existing bubble; old annotations fade out,
    /// new ones animate in.
    func followUp(bubbleID: UUID, question: String) async {
        guard let note, let page = currentPage,
              let index = bubbles.firstIndex(where: { $0.id == bubbleID }) else { return }
        bubbles[index].thread.append(AIExchange(question: question, answer: ""))
        loadingBubbleIDs.insert(bubbleID)
        defer { loadingBubbleIDs.remove(bubbleID) }

        do {
            let context = await NoteContextBuilder.build(
                note: note, currentPageIndex: currentPageIndex, darkMode: isDarkMode,
                focusAnchor: CGPoint(x: bubbles[index].anchorX, y: bubbles[index].anchorY)
            )
            var messages: [AIMessage] = [.user(context.blocks)]
            // Replay the thread so the model has the bubble's conversation.
            for exchange in bubbles[index].thread {
                if let q = exchange.question {
                    messages.append(.user(text: q))
                }
                if !exchange.answer.isEmpty {
                    messages.append(.assistant(text: exchange.answer))
                }
            }

            let raw = try await AIService.send(
                system: SystemPrompt.tutor(subjectContext: note.subjectContext ?? "general"),
                messages: messages,
                maxTokens: 2400
            )
            let parsed = AIResponseParser.parse(raw)
            let lines = await NoteContextBuilder.ocrLines(for: page)
            apply(parsed: parsed, to: bubbleID, ocrLines: lines)
        } catch {
            errorMessage = error.localizedDescription
            if let i = bubbles.firstIndex(where: { $0.id == bubbleID }), bubbles[i].thread.last?.answer.isEmpty == true {
                bubbles[i].thread.removeLast()
            }
        }
    }

    private func apply(parsed: AIParsedResponse, to bubbleID: UUID, ocrLines: [OCRLine]) {
        guard let index = bubbles.firstIndex(where: { $0.id == bubbleID }) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if bubbles[index].thread.last?.answer.isEmpty == true {
                bubbles[index].thread[bubbles[index].thread.count - 1].answer = parsed.text
            } else {
                bubbles[index].thread.append(AIExchange(question: nil, answer: parsed.text))
            }
            bubbles[index].tone = parsed.tone
            bubbles[index].chips = parsed.chips
            bubbles[index].annotations = AIResponseParser.resolve(annotations: parsed.annotations, against: ocrLines)
        }
        logToHistory(bubbles[index])
        Haptics.success()
        // VoiceOver: announce new tutor responses so non-visual users hear them arrive.
        UIAccessibility.post(
            notification: .announcement,
            argument: String(localized: "ai.bubble.accessibility") + ": " + parsed.text
        )
    }

    // MARK: - Lifecycle

    /// Toggles pinning. Pinned bubbles persist across sessions but keep their
    /// current expanded/collapsed state — force-collapsing on pin felt like
    /// the bubble vanished.
    func pin(bubbleID: UUID) {
        guard let index = bubbles.firstIndex(where: { $0.id == bubbleID }) else { return }
        bubbles[index].isPinned.toggle()
        // Pinning tucks the card into its compact chip, anchored on the page — a
        // persistent, returnable marker (tap the chip to reopen). Unpinning
        // re-expands it. The chip stays in place, so it reads as "pinned here",
        // not "vanished".
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            bubbles[index].isCollapsed = bubbles[index].isPinned
        }
        persistPinnedBubbles()
    }

    func dismiss(bubbleID: UUID) {
        guard let index = bubbles.firstIndex(where: { $0.id == bubbleID }) else { return }
        let bubble = bubbles.remove(at: index)
        logToHistory(bubble)
        if bubble.isPinned { persistPinnedBubbles() }
    }

    func move(bubbleID: UUID, to point: CGPoint) {
        guard let index = bubbles.firstIndex(where: { $0.id == bubbleID }) else { return }
        // Clamp inside the page so a bubble can never be dragged out of reach.
        let pages = note?.sortedPages ?? []
        let pageSize = pages.indices.contains(bubbles[index].pageIndex)
            ? pages[bubbles[index].pageIndex].canvasSize
            : CGSize(width: 800, height: 1100)
        bubbles[index].x = min(max(point.x, -bubbles[index].width / 2), pageSize.width - 60)
        bubbles[index].y = min(max(point.y, -20), pageSize.height - 80)
        if bubbles[index].isPinned { persistPinnedBubbles() }
    }

    /// Asking from the side panel: follow up on the selected thread, otherwise
    /// start a panel-only conversation — never a floating canvas bubble.
    func askFromPanel(question: String) async {
        if let id = panelBubbleID, bubbles.contains(where: { $0.id == id }) {
            await followUp(bubbleID: id, question: question)
            return
        }
        let pageSize = currentPage.map(\.canvasSize) ?? CGSize(width: 800, height: 1100)
        await ask(
            question: question,
            anchor: CGPoint(x: pageSize.width - 140, y: 100),
            panelOnly: true
        )
    }

    func resize(bubbleID: UUID, width: Double, maxHeight: Double? = nil) {
        guard let index = bubbles.firstIndex(where: { $0.id == bubbleID }) else { return }
        bubbles[index].width = min(max(width, 240), 540)
        if let maxHeight {
            bubbles[index].maxHeight = min(max(maxHeight, 160), 700)
        }
        if bubbles[index].isPinned { persistPinnedBubbles() }
    }

    func toggleCollapsed(bubbleID: UUID) {
        guard let index = bubbles.firstIndex(where: { $0.id == bubbleID }) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            bubbles[index].isCollapsed.toggle()
        }
    }

    /// Inserts the latest answer as a typed text box on the canvas.
    func insertAnswerIntoNote(bubbleID: UUID) -> TextBoxModel? {
        guard let bubble = bubbles.first(where: { $0.id == bubbleID }), !bubble.latestAnswer.isEmpty else { return nil }
        var box = TextBoxModel(x: bubble.x, y: bubble.y + 40, width: max(bubble.width, 260), height: 120)
        box.text = bubble.latestAnswer
        return box
    }

    func pageChanged(to index: Int) {
        currentPageIndex = index
        // Collapse bubbles belonging to other pages; they re-expand on return.
        for i in bubbles.indices where bubbles[i].pageIndex != index {
            bubbles[i].isCollapsed = true
        }
    }

    // MARK: - Persistence

    private func loadPinnedBubbles() {
        guard let note else { return }
        bubbles = note.sortedPages.flatMap { page -> [AIBubbleModel] in
            guard let data = page.pinnedBubblesData,
                  let stored = try? JSONDecoder().decode([AIBubbleModel].self, from: data) else { return [] }
            return stored
        }
    }

    private func persistPinnedBubbles() {
        guard let note else { return }
        for (index, page) in note.sortedPages.enumerated() {
            let pinned = bubbles.filter { $0.isPinned && $0.pageIndex == index }
            page.pinnedBubblesData = try? JSONEncoder().encode(pinned)
        }
        PersistenceController.shared.save()
    }

    private func logToHistory(_ bubble: AIBubbleModel) {
        history.removeAll { $0.id == bubble.id }
        history.insert(bubble, at: 0)
        AIHistoryStore.save(history, noteID: note?.id)
    }
}

/// JSON file per note logging every AI interaction (the AI History panel source).
enum AIHistoryStore {
    private static func url(noteID: UUID?) -> URL? {
        guard let noteID else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AIHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(noteID.uuidString).json")
    }

    static func load(noteID: UUID?) -> [AIBubbleModel] {
        guard let url = url(noteID: noteID), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([AIBubbleModel].self, from: data)) ?? []
    }

    static func save(_ history: [AIBubbleModel], noteID: UUID?) {
        guard let url = url(noteID: noteID), let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url)
    }
}

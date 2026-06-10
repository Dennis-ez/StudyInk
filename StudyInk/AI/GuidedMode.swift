import SwiftUI

struct GuidedSuggestion: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let matchString: String?
    let createdAt = Date()
}

/// Proactive tutoring: evaluates the page ~3 seconds after the pen goes quiet
/// (and on page turns), never mid-stroke, with at least 30s between requests
/// and no repeats for unchanged content. Suggestion cards auto-dismiss after
/// 8 seconds; tapping one opens a full response bubble anchored to the
/// relevant region. Every suggestion is kept in a tappable history log.
@MainActor
final class GuidedModeController: ObservableObject {
    @Published var isEnabled = false {
        didSet { isEnabled ? start() : stop() }
    }
    @Published var suggestion: GuidedSuggestion?
    /// Transient, non-tappable status text (e.g. "guided mode is watching").
    @Published var banner: String?
    /// Every suggestion made this session, newest first (tappable later).
    @Published var log: [GuidedSuggestion] = []

    weak var tutor: AITutorController?
    private var penPauseTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var lastSeenText = ""
    private var lastRequestAt = Date.distantPast
    private var inFlight = false
    /// Minimum quiet time between AI requests.
    private let minRequestInterval: TimeInterval = 30
    /// How long the pen must rest before we evaluate the page.
    private let penPauseDelay: TimeInterval = 3

    func start() {
        stopTasks()
        // Re-arm the change detector so re-enabling re-evaluates the current page.
        lastSeenText = ""
        lastRequestAt = .distantPast
        guard AIConfig.isConfigured else {
            isEnabled = false
            tutor?.errorMessage = AIServiceError.missingKey(AIConfig.provider).localizedDescription
            return
        }
        showBanner(String(localized: "ai.guided.activated"))
        Task { await checkPage() }
    }

    func stop() {
        stopTasks()
        suggestion = nil
        banner = nil
    }

    /// Called for every new stroke: (re)arms the pen-pause timer so evaluation
    /// happens a few seconds after writing stops — never mid-stroke.
    func strokeOccurred() {
        guard isEnabled else { return }
        penPauseTask?.cancel()
        penPauseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.penPauseDelay ?? 3))
            guard !Task.isCancelled else { return }
            await self?.checkPage()
        }
    }

    func pageTurned() {
        guard isEnabled else { return }
        penPauseTask?.cancel()
        Task { await checkPage(force: true) }
    }

    private func stopTasks() {
        penPauseTask?.cancel()
        dismissTask?.cancel()
        bannerTask?.cancel()
        penPauseTask = nil
        dismissTask = nil
        bannerTask = nil
    }

    private func showBanner(_ text: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { banner = text }
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { self?.banner = nil }
        }
    }

    /// One cheap, text-only request: is there something worth flagging right now?
    private func checkPage(force: Bool = false) async {
        guard let tutor, let note = tutor.note, let page = tutor.currentPage,
              !inFlight, AIConfig.isConfigured else { return }

        // Rate limit: at most one request per 30s, regardless of trigger.
        guard Date().timeIntervalSince(lastRequestAt) >= minRequestInterval else { return }

        await OCRService.indexPage(page)
        let typed = page.textBoxes.map(\.text).joined(separator: "\n")
        let content = [(page.ocrText ?? ""), typed].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count > 12, force || content != lastSeenText else { return }
        lastSeenText = content
        lastRequestAt = Date()
        inFlight = true
        defer { inFlight = false }

        let hint = """
        GUIDED MODE: You are passively watching the student write. Below is the OCR + typed text of the current page.
        Decide whether ONE genuinely useful, proactive suggestion exists. A good suggestion:
        - quotes or names the exact expression/line it is about (e.g. "you wrote lim x→0 sin(x)/x — want me to check the evaluation?")
        - offers a concrete next action (check a step, verify a base case, test an edge case, finish a definition)
        - is at most ~12 words, in the student's language
        Do NOT comment on neat/complete work, restate the obvious, or suggest generic "keep going" encouragement.
        Respond with ONLY a JSON object:
        {"suggestion": "<the one-sentence suggestion>", "match_string": "<exact string copied verbatim from the page text it refers to — required whenever possible, else null>"}
        If nothing clears that bar, respond with exactly {}.

        Page content:
        \(content.prefix(3000))
        """

        do {
            let raw = try await AIService.send(
                system: SystemPrompt.tutor(subjectContext: note.subjectContext ?? "calculus1"),
                messages: [.user(text: hint)],
                maxTokens: 300
            )
            guard let data = extractJSON(from: raw)?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = object["suggestion"] as? String, !text.isEmpty else { return }
            show(GuidedSuggestion(text: text, matchString: object["match_string"] as? String))
        } catch {
            // Don't fail silently and don't alert every 10s: surface the error
            // once and switch guided mode off so the user can fix the cause.
            tutor.errorMessage = error.localizedDescription
            isEnabled = false
        }
    }

    private func show(_ new: GuidedSuggestion) {
        Haptics.tap()
        log.insert(new, at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            suggestion = new
        }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            withAnimation { self?.suggestion = nil }
        }
    }

    /// Student tapped the card → open a real bubble anchored at the referenced text.
    func accept(_ suggestion: GuidedSuggestion) {
        self.suggestion = nil
        dismissTask?.cancel()
        guard let tutor, let page = tutor.currentPage else { return }
        Task {
            var anchor = CGPoint(x: 200, y: 200)
            if let match = suggestion.matchString {
                let lines = await NoteContextBuilder.ocrLines(for: page)
                var probe = AIAnnotationModel(kind: .highlight, matchString: match, colorToken: "aiHighlightBlue")
                probe = AIResponseParser.resolve(annotations: [probe], against: lines).first ?? probe
                if let rect = probe.rect {
                    anchor = CGPoint(x: rect.midX, y: rect.midY)
                }
            }
            await tutor.ask(question: suggestion.text, anchor: anchor)
        }
    }

    /// Tolerates fenced code blocks and surrounding prose around the JSON object.
    private func extractJSON(from raw: String) -> String? {
        if let fence = raw.range(of: "```json", options: .caseInsensitive),
           let close = raw.range(of: "```", range: fence.upperBound..<raw.endIndex) {
            return String(raw[fence.upperBound..<close.lowerBound])
        }
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start <= end else { return nil }
        return String(raw[start...end])
    }
}

/// Bottom suggestion card UI.
struct GuidedSuggestionCard: View {
    let suggestion: GuidedSuggestion
    var onAccept: () -> Void
    var onDismiss: () -> Void

    private var isRTL: Bool { suggestion.text.isMostlyRTL }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(SemanticColor.aiCircleStroke)
            Text(suggestion.text)
                .font(.subheadline)
                .multilineTextAlignment(isRTL ? .trailing : .leading)
            Spacer(minLength: 6)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text("ai.dismiss"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .studyGlass(cornerRadius: 16)
        .frame(maxWidth: 480)
        .contentShape(Rectangle())
        .onTapGesture(perform: onAccept)
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("ai.guided.suggestion"))
        .accessibilityValue(Text(suggestion.text))
        .accessibilityAddTraits(.isButton)
    }
}


/// Popover log of past guided-mode suggestions; tapping one opens it as a bubble.
struct GuidedLogView: View {
    @ObservedObject var guidedMode: GuidedModeController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if guidedMode.log.isEmpty {
                ContentUnavailableView("ai.guided.log.empty", systemImage: "lightbulb")
            } else {
                List(guidedMode.log) { item in
                    Button {
                        dismiss()
                        guidedMode.accept(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.text)
                                .font(.subheadline)
                                .multilineTextAlignment(item.text.isMostlyRTL ? .trailing : .leading)
                                .frame(maxWidth: .infinity, alignment: item.text.isMostlyRTL ? .trailing : .leading)
                            Text(item.createdAt, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 300, minHeight: 240)
        .navigationTitle(Text("ai.guided.log"))
    }
}

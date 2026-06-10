import SwiftUI

struct GuidedSuggestion: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let matchString: String?
}

/// Proactive tutoring: watches the page (OCR every ~10s and on page turn) and
/// surfaces one short suggestion card at the bottom of the screen. Cards
/// auto-dismiss after 8 seconds; tapping one opens a full response bubble
/// anchored to the relevant region.
@MainActor
final class GuidedModeController: ObservableObject {
    @Published var isEnabled = false {
        didSet { isEnabled ? start() : stop() }
    }
    @Published var suggestion: GuidedSuggestion?
    /// Transient, non-tappable status text (e.g. "guided mode is watching").
    @Published var banner: String?

    weak var tutor: AITutorController?
    private var watchTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var lastSeenText = ""
    private var inFlight = false

    func start() {
        stopTasks()
        // Re-arm the change detector so re-enabling re-evaluates the current page.
        lastSeenText = ""
        guard AIConfig.isConfigured else {
            isEnabled = false
            tutor?.errorMessage = AIServiceError.missingKey(AIConfig.provider).localizedDescription
            return
        }
        showBanner(String(localized: "ai.guided.activated"))
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkPage()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stop() {
        stopTasks()
        suggestion = nil
        banner = nil
    }

    func pageTurned() {
        guard isEnabled else { return }
        Task { await checkPage(force: true) }
    }

    private func stopTasks() {
        watchTask?.cancel()
        dismissTask?.cancel()
        bannerTask?.cancel()
        watchTask = nil
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

        await OCRService.indexPage(page)
        let typed = page.textBoxes.map(\.text).joined(separator: "\n")
        let content = [(page.ocrText ?? ""), typed].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count > 12, force || content != lastSeenText else { return }
        lastSeenText = content
        inFlight = true
        defer { inFlight = false }

        let hint = """
        GUIDED MODE: You are passively watching the student write. Below is the OCR + typed text of the current page.
        If — and only if — there is one genuinely useful, short proactive suggestion (e.g. "you wrote a limit — want me to check its structure?", "you defined a recurrence — want me to check the base case?"), respond with ONLY a JSON object:
        {"suggestion": "<one short sentence in the student's language>", "match_string": "<exact string from the page text it refers to, or null>"}
        If nothing is worth saying, respond with exactly {}.

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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SemanticColor.aiBubbleBorder))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
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

import SwiftUI

struct GuidedSuggestion: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let matchString: String?
    /// One line on WHY this matters (shown when the card is expanded).
    var why: String?
    /// The ordered steps from where the student is to the next result — laid out
    /// when the card is tapped open. Each may contain LaTeX (rendered via AIRichText).
    var steps: [String] = []
    let createdAt = Date()

    var hasDetail: Bool { (why?.isEmpty == false) || !steps.isEmpty }
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
    /// True while the watcher is evaluating the page — drives the breathing badge.
    @Published var isWatching = false
    /// Every suggestion made this session, newest first (tappable later).
    @Published var log: [GuidedSuggestion] = []

    weak var tutor: AITutorController?
    /// The margin lane — so a nudge can drop a "?" glyph at the line it's about.
    weak var ambient: AmbientTutorController?
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
        ambient?.clearHints()
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
        // Don't fire on every page while the user scrolls through an imported PDF
        // — wait until they DWELL on a page, then evaluate (and checkPage still
        // bails on pages with no student work of their own).
        penPauseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await self?.checkPage(force: true)
        }
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

        // CHEAP eligibility gate, BEFORE any OCR / render / Core Data save: only
        // evaluate pages the STUDENT is actively working on — their handwriting or
        // their own typed text. A pristine imported PDF page (printed Q&A they're
        // just reading/scrolling) has OCR'd content but no work of their own, so
        // skip it entirely — no heavy work, no hiccup (#5/#8).
        let typed = page.textBoxes.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let strokeCount = page.drawing.strokes.count
        guard strokeCount > 2 || typed.count > 8 else { return }

        PerfMonitor.shared.setActivity("ai:guided")
        defer { if PerfMonitor.shared.activity == "ai:guided" { PerfMonitor.shared.setActivity("idle") } }
        await OCRService.indexPage(page)
        let content = [(page.ocrText ?? ""), typed].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Stroke count is part of the signature so we re-evaluate handwriting that
        // OCR can't read (the model SEES the page image below regardless).
        let signature = "\(content)#\(strokeCount)"
        guard force || signature != lastSeenText else { return }       // and it changed
        lastSeenText = signature
        lastRequestAt = Date()
        inFlight = true
        isWatching = true
        defer { inFlight = false; isWatching = false }

        // Render the page so the model can read handwriting visually, not just OCR.
        let snapshot = PageRenderer.Snapshot(page: page)
        let pageImage = await Task.detached(priority: .utility) {
            // 2× so small handwriting (stacked fractions, limit subscripts) and a
            // pasted question image are legible — at 1× the model can't read them.
            PageRenderer.render(snapshot, darkMode: false, scale: 2)
        }.value

        let hint = """
        GUIDED MODE — you are quietly watching the student work. Offer help ONLY when it is genuinely useful; you will be asked again as they keep writing, so stay SILENT when in doubt.
        The image above is the student's CURRENT PAGE (read the handwriting from it — OCR is unreliable). First understand the PROBLEM / sub-question (typed, printed, or a pasted screenshot/photo; may be Hebrew/another language) and WHERE in the solution the student currently is.
        Then, silently, WORK OUT the correct next step yourself. Now compare it to the student's LAST lines and decide if exactly one of these is clearly true:
        - STUCK: an unfinished line they haven't progressed, a long pause, or the same step rewritten/erased.
        - ERROR: they just made a mistake, or are about to take a wrong turn. Judge the EXACT value they wrote (sign, number, variable) against YOUR own solution — never excuse a wrong sign or root.
        - MISSING: a key step or case is skipped.
        Only then, give ONE concrete hint that:
        - names the exact line/expression it is about,
        - points to the next action or the error WITHOUT giving the full answer (a nudge, not the solution),
        - is ≤12 words, written in \(SystemPrompt.languageTarget).
        Do NOT comment on correct/complete/neat work, restate the obvious, or give generic encouragement.
        Reason briefly if you need to, then output ONLY a JSON object (you may fence it in a ```json block):
        {"suggestion": "<the ≤12-word nudge>", "why": "<one short line on why this matters, ≤14 words>", "steps": ["<each step formatted as: what you do, then ' → ', then the RESULTING expression after that step in $...$>"], "match_string": "<exact string copied verbatim from the page it refers to, or null>"}
        `why` and `steps` are revealed only if the student taps for help, so DO give the real worked steps there (input → output). EVERY step must end with ' → ' and the resulting expression (in $...$) AFTER applying that step, so the student sees the output at each stage. Write `why`/`steps` in \(SystemPrompt.languageTarget). Keep `steps` to at most 6 items.
        If nothing clears that bar, output exactly {}.

        OCR/typed text (may be empty or wrong):
        \(content.prefix(3000))
        """

        var blocks: [AIContent] = []
        if let imageBlock = AIContent.image(pageImage) {
            blocks.append(.text("The student's current page:"))
            blocks.append(imageBlock)
        }
        blocks.append(.text(hint))

        do {
            let raw = try await AIService.send(
                system: SystemPrompt.guidedWatcher,
                messages: [.user(blocks)],
                // Generous: Gemini 2.5 spends "thinking" tokens that count against
                // this budget, so a tight cap (700) starved the actual output and
                // truncated the {suggestion,…} JSON mid-string → nothing showed.
                maxTokens: 2500
            )
            // Parse the watcher reply, tolerating a TRUNCATED JSON (a thinking model
            // can cut it off mid-string): fall back to a regex on the values.
            var suggestion: String?
            var match: String?
            var why: String?
            var steps: [String] = []
            if let data = extractJSON(from: raw)?.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                suggestion = object["suggestion"] as? String
                match = object["match_string"] as? String
                why = object["why"] as? String
                steps = (object["steps"] as? [String])?.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? []
            }
            if suggestion?.isEmpty != false {
                suggestion = Self.regexCapture(#""suggestion"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: raw)
                match = match ?? Self.regexCapture(#""match_string"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: raw)
            }
            guard let text = suggestion, !text.isEmpty else { return }
            let new = GuidedSuggestion(
                text: text,
                matchString: (match?.isEmpty == false && match != "null") ? match : nil,
                why: (why?.isEmpty == false && why != "null") ? why : nil,
                steps: steps
            )
            show(new)
            // The glyph is placed by the editor at the student's last pen location
            // (the OCR is too garbled to text-match the model's clean match_string).
        } catch {
            // A request superseded by newer writing is CANCELLED — that's the
            // debounce working, not a failure. Keep watching.
            if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            // A real error (bad key, network): surface once and switch off so the
            // user can fix the cause, rather than alerting every 10s.
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
            // Linger: the watcher fires at most once per ~30s and the AI call takes
            // ~10s, so a quick 8s card was easy to miss entirely.
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            withAnimation { self?.suggestion = nil }
        }
    }

    /// The student is reading the expanded steps — stop the auto-dismiss.
    func keepAlive() { dismissTask?.cancel() }

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

    /// First capture group of `pattern` in `s` (used to recover values from a
    /// truncated JSON reply).
    private static func regexCapture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
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

/// Bottom suggestion card UI. The nudge is shown collapsed; tapping lays out the
/// "why" and the ordered steps (input → output), with real LaTeX via AIRichText
/// and the AI accent so it reads in the tutor's own "ink".
struct GuidedSuggestionCard: View {
    let suggestion: GuidedSuggestion
    var onAccept: () -> Void
    var onDismiss: () -> Void
    /// Called when the student expands the steps — stops the auto-dismiss.
    var onExpand: () -> Void = {}

    @State private var expanded = false
    private var isRTL: Bool { suggestion.text.isMostlyRTL }
    private var accent: Color { SemanticColor.aiCircleStroke }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 11 : 0) {
            // The nudge row.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb.fill").foregroundStyle(accent)
                AIRichText(content: suggestion.text)
                    .font(.subheadline)
                Spacer(minLength: 6)
                if suggestion.hasDetail {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Button(action: onDismiss) {
                    Lucide("x", size: 13).foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text("ai.dismiss"))
            }

            if expanded {
                Divider().overlay(accent.opacity(0.25))
                if let why = suggestion.why, !why.isEmpty {
                    detail(label: whyLabel, body: why)
                }
                if !suggestion.steps.isEmpty {
                    detailHeader(howLabel)
                    ForEach(Array(suggestion.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 9) {
                            Text(verbatim: "\(index + 1)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(width: 19, height: 19)
                                .background(accent, in: Circle())
                            AIRichText(content: step)
                                .font(.fraunces(15, weight: .regular, relativeTo: .subheadline))
                        }
                    }
                    Button(action: onAccept) {
                        Label { Text("ai.guided.openChat") } icon: { Image(systemName: "bubble.left.and.text.bubble.right") }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .studyGlass(cornerRadius: 16)
        .frame(maxWidth: 480)
        .contentShape(Rectangle())
        .onTapGesture {
            if suggestion.hasDetail {
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
                if expanded { onExpand() }
            } else {
                onAccept()
            }
        }
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("ai.guided.suggestion"))
    }

    /// Labels follow the CONTENT language, not the device: Hebrew steps get
    /// Hebrew "למה / איך" even on an English device.
    private var detailHebrew: Bool {
        (suggestion.why?.isMostlyRTL ?? false) || (suggestion.steps.first?.isMostlyRTL ?? false)
    }
    private var whyLabel: String { detailHebrew ? "למה" : "Why" }
    private var howLabel: String { detailHebrew ? "איך" : "How" }

    private func detailHeader(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption.weight(.semibold).smallCaps())
            .foregroundStyle(accent)
    }

    private func detail(label: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            detailHeader(label)
            AIRichText(content: body)
                .font(.fraunces(15, weight: .regular, relativeTo: .subheadline))
        }
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
                    GuidedLogRow(item: item) { dismiss(); guidedMode.accept(item) }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 300, minHeight: 240)
        .navigationTitle(Text("ai.guided.log"))
    }
}

/// One history entry — the nudge, tap to expand its why + worked steps (with
/// real LaTeX), or open it in chat.
private struct GuidedLogRow: View {
    let item: GuidedSuggestion
    var onOpen: () -> Void
    @State private var expanded = false
    private var accent: Color { SemanticColor.aiCircleStroke }
    private var hebrew: Bool {
        (item.why?.isMostlyRTL ?? false) || (item.steps.first?.isMostlyRTL ?? false) || item.text.isMostlyRTL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                AIRichText(content: item.text).font(.subheadline)
                Spacer(minLength: 8)
                if item.hasDetail {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Text(item.createdAt, style: .time).font(.caption2).foregroundStyle(.secondary)

            if expanded {
                if let why = item.why, !why.isEmpty {
                    Text(verbatim: hebrew ? "למה" : "Why")
                        .font(.caption2.weight(.semibold).smallCaps()).foregroundStyle(accent)
                    AIRichText(content: why).font(.footnote)
                }
                if !item.steps.isEmpty {
                    Text(verbatim: hebrew ? "איך" : "How")
                        .font(.caption2.weight(.semibold).smallCaps()).foregroundStyle(accent)
                    ForEach(Array(item.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text(verbatim: "\(i + 1)")
                                .font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                                .frame(width: 16, height: 16).background(accent, in: Circle())
                            AIRichText(content: step).font(.footnote)
                        }
                    }
                    Button(action: onOpen) {
                        Label { Text("ai.guided.openChat") } icon: { Image(systemName: "bubble.left.and.text.bubble.right") }
                            .font(.caption2).foregroundStyle(accent)
                    }
                    .buttonStyle(.plain).padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.hasDetail { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
            else { onOpen() }
        }
        .environment(\.layoutDirection, hebrew ? .rightToLeft : .leftToRight)
    }
}

import SwiftUI

// MARK: - Ambient Tutor (Marginalia) models + controller
//
// The "Ambient Tutor" design: the tutor reads the page and leaves quiet marks
// in the margin lane (the red rule) — a ✓, a gentle correction ~, a "?" hint.
// Tap a glyph and a MarginNoteView unfolds with the help. Push, politely.
//
// This is the front of the spec's build order: the margin lane + glyph system +
// note, driven by a *triggered* "Check my work" against the app's existing AI
// (OCR + AIService). The continuous on-device reader / voice / SRS are the
// deeper follow-on.

/// The four marginal glyphs.
enum AmbientGlyph: String, Codable {
    case correct   // ✓ verified correct (passive)
    case attend    // ~ gentle correction
    case hint      // ? hint available / stuck
    case note      // • a general idea/connection

    /// The glyph's category color, from the active skin's tokens.
    var color: Color {
        switch self {
        case .correct: return SemanticColor.success
        case .attend:  return AppTheme.current.aiCircleColor
        case .hint, .note: return AppTheme.current.aiAccent
        }
    }
}

/// Answer tone — drives the note's leading strip color.
enum AmbientTone {
    case teaching, correct, correction, error
    var color: Color {
        switch self {
        case .teaching:  return Color.accentColor
        case .correct:   return SemanticColor.success
        case .correction: return AppTheme.current.aiCircleColor
        case .error:     return SemanticColor.destructive
        }
    }
}

/// One margin item — a glyph anchored to a line of the student's work, with a
/// pre-computed note so a tap is instant.
struct MarginItem: Identifiable {
    let id = UUID()
    var pageIndex: Int
    /// Anchor rect in PAGE coordinates (scrolls/zooms with the canvas).
    var anchorRect: CGRect
    var glyph: AmbientGlyph
    var tone: AmbientTone
    /// Short label shown at the top of the note ("Almost —", "Looks right").
    var label: String
    /// The explanation body.
    var body: String
    /// Optional corrected result, rendered as italic math.
    var result: String?
    /// True for ✓ — passive, no note unfolds (just a toast feel).
    var passive: Bool { glyph == .correct }
}

/// The tutor's predicted next step, shown as faint amber ghost text ahead of
/// the pen. Flick/tap to accept → it's written as real ink.
/// A "grade my answer" prompt: a glyph anchored to the student's last line that,
/// when tapped, grades the page.
struct GradePrompt: Equatable {
    var pageIndex: Int
    /// Page-space point of the student's last work (the glyph parks at this height).
    var anchor: CGPoint
}

/// An inline "why" explanation rendered as worked steps (the step UI), shown in
/// place near the line instead of opening the AI chat bubble.
struct StepExplanation: Equatable {
    var pageIndex: Int
    var anchor: CGPoint
    var why: String?
    var steps: [String]
    var isLoading: Bool
    /// When set, this explanation belongs to a specific margin note (the check
    /// glyph's "Show why") and renders INSIDE that note rather than as a floating card.
    var itemID: UUID? = nil
    /// The params/terms from the student's own work the tutor used — color-coded
    /// as chips here and as matching highlights over their ink on the canvas.
    var highlights: [AIHighlight] = []
}

/// One thing the tutor "took into consideration": a term/value/param read off the
/// student's work. Shown as a colored chip in the why/steps card and, when it has a
/// location, as a matching-colored highlight over that spot on the canvas — so the
/// student sees WHICH part of their work fed the explanation. Subject-agnostic.
struct AIHighlight: Equatable, Identifiable {
    let id = UUID()
    /// The term as written (e.g. "(x-1)²", "valence electrons", "1789").
    var label: String
    /// Page-space rect over the student's ink, or nil when it can't be located.
    var rect: CGRect?
    /// Index into AIHighlightPalette — the chip + the on-ink box share this color.
    var colorIndex: Int

    static func == (a: AIHighlight, b: AIHighlight) -> Bool {
        a.label == b.label && a.rect == b.rect && a.colorIndex == b.colorIndex
    }
}

/// A small fixed set of distinct, legible accents used to color-code the tutor's
/// considered params across the bubble (chips) and the canvas (ink highlights).
enum AIHighlightPalette {
    /// Canonical (light) hexes; the on-ink box uses a translucent fill so dark
    /// ink stays readable through it.
    static let hexes = ["#2E7DF6", "#8B5CF6", "#0F9D8C", "#E0529C", "#E08A1E"]
    static func color(_ i: Int) -> Color { Color(hex: hexes[wrap(i)]) ?? .blue }
    static func uiColor(_ i: Int) -> UIColor { UIColor(hex: hexes[wrap(i)]) ?? .systemBlue }
    private static func wrap(_ i: Int) -> Int { ((i % hexes.count) + hexes.count) % hexes.count }
}

struct GhostSuggestion {
    /// Tags the explanation fetched for the ghost's "?" so it renders inside the ghost
    /// card (not as a floating step card).
    static let explainItemID = UUID()
    var pageIndex: Int
    /// Page-space anchor. For an inline completion it's the MIDDLE of the line
    /// (so a tall fraction straddles it); for a new line below it's the top-left.
    var anchor: CGPoint
    var text: String
    /// One short sentence: WHY this is the next step (revealed on the "?" tap).
    var why: String?
    /// The ordered worked steps that lead to this next line (revealed on the "?"
    /// tap, under the why). Each may contain LaTeX, rendered via AIRichText.
    var steps: [String] = []
    /// True when completing the current line (after '='), false for a new line.
    var inline: Bool = false
    /// The params/terms from the student's work this step builds on — color-coded
    /// as chips in the why/steps card and as matching highlights on the canvas.
    var highlights: [AIHighlight] = []
    /// 2a fill-in ghost: the single insight-bearing token in `text` to mask first
    /// (the substituted variable / key operand). Nil = show the whole line.
    var blankToken: String? = nil

    var hasDetail: Bool { (why?.isEmpty == false) || !steps.isEmpty }
}

/// The 3b "Check my work · straight to the break" result (handoff §4.3): a line-health
/// map + the FIRST break with a precise fix. Built from the `check` Gemini call.
struct DiagnosticState {
    var pageIndex: Int
    var ok: [Bool]                                  // per-line verdict (health map)
    var brokenLine: Int?                            // firstError.line
    var error: AIClient.CheckResult.FirstError?
    var praise: String?
    var lineRects: [CGRect]                          // page-space, for spotlight + fix anchor
}

/// The 1a "Guided mode · reveal in layers" state (handoff §4.1): one `next_step` call
/// returns nudge/hint/step; the card reveals only up to the current rung.
struct GuidedLadderState {
    var step: AIClient.NextStep
    var rung: Int                                   // 1 question · 2 hint · 3 step
    var anchor: CGPoint
    var pageIndex: Int
}

enum AmbientSensitivity: String, CaseIterable, Identifiable {
    case off, subtle, helpful
    var id: String { rawValue }
    var labelKey: LocalizedStringKey {
        switch self {
        case .off: return "ambient.off"
        case .subtle: return "ambient.subtle"
        case .helpful: return "ambient.helpful"
        }
    }
}

@MainActor
final class AmbientTutorController: ObservableObject {
    @Published var items: [MarginItem] = []
    @Published var openItemID: UUID?
    @Published var isChecking = false
    /// True while a MANUAL "Suggest next step" is in flight — drives the same
    /// breathing badge as a check (auto/idle suggestions stay silent).
    @Published var isSuggesting = false
    /// Transient banner shown after a check (an error, or "nothing to check").
    @Published var notice: String?
    /// The next-step ghost suggestion, if any.
    @Published var ghost: GhostSuggestion?
    /// The 3b diagnostic result (health map + first break), if a check is showing.
    @Published var diagnostic: DiagnosticState?
    /// The 1a guided ladder, if one is open.
    @Published var guidedLadder: GuidedLadderState?
    /// OCR line rects from the most recent check — used so AI ink (fix-it) lands
    /// in a clear gap instead of over the student's existing work.
    private(set) var lastLineRects: [CGRect] = []
    /// Guards the idle auto-trigger so we only suggest once per writing burst.
    private var lastGhostSourceLine: String?
    /// Memoised check results, per page. Re-running "Check my work" on a page
    /// whose content hasn't changed re-streams the SAME verdicts instead of
    /// re-calling the model — so repeated taps are deterministic (vision models
    /// vary run-to-run even at temperature 0). Keyed by a content signature.
    private var checkCache: [String: [Verdict]] = [:]
    /// Signature of the most recent check. Re-tapping Check on the SAME page is
    /// read as "regrade — you got it wrong", which bypasses the cache for a fresh
    /// pass instead of replaying the same (possibly wrong) verdicts.
    private var lastCheckSignature: String?
    @AppStorage("ambient.sensitivity") private var sensitivityRaw = AmbientSensitivity.helpful.rawValue

    var sensitivity: AmbientSensitivity {
        get { AmbientSensitivity(rawValue: sensitivityRaw) ?? .helpful }
        set { sensitivityRaw = newValue.rawValue }
    }
    /// "Tutor on" — when off the lane is silent.
    var isOn: Bool { sensitivity != .off }

    func items(onPage index: Int) -> [MarginItem] { items.filter { $0.pageIndex == index } }

    /// Shows a transient banner and auto-dismisses it after a few seconds.
    func showNotice(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) { notice = message }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    if self?.notice == message { self?.notice = nil }
                }
            }
        }
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.passive else { return }
        withAnimation(DS.Motion.bubbleAppear) { openItemID = id }
        Haptics.tap()
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) { openItemID = nil }
    }

    /// A NEW stroke landing on a glyph's line means the student EDITED that line —
    /// the verdict no longer applies, so resolve (remove) the glyph. (§7 "editing
    /// the line auto-resolves its glyph".)
    func resolveGlyphs(pageIndex: Int, editedBy rect: CGRect) {
        let survivors = items.filter { $0.pageIndex != pageIndex || !$0.anchorRect.intersects(rect) }
        guard survivors.count != items.count else { return }
        if let open = openItemID, !survivors.contains(where: { $0.id == open }) { openItemID = nil }
        withAnimation(.easeOut(duration: 0.2)) { items = survivors }
    }

    /// Drop glyphs whose anchored ink is gone (the student erased that line).
    /// `inkRects` = page-space render bounds of every remaining stroke on the page.
    func pruneGlyphs(pageIndex: Int, inkRects: [CGRect]) {
        let survivors = items.filter { item in
            item.pageIndex != pageIndex
                || inkRects.contains { $0.intersects(item.anchorRect) }
        }
        guard survivors.count != items.count else { return }
        if let open = openItemID, !survivors.contains(where: { $0.id == open }) { openItemID = nil }
        withAnimation(.easeOut(duration: 0.2)) { items = survivors }
    }

    func clear(pageIndex: Int? = nil) {
        withAnimation(.easeOut(duration: 0.2)) {
            if let p = pageIndex { items.removeAll { $0.pageIndex == p } }
            else { items.removeAll() }
            openItemID = nil
        }
    }

    /// Pins a proactive-watcher nudge to the line it's about: a "?" hint glyph in
    /// the margin next to `anchorRect`, tappable to open the full explanation.
    /// Only one live hint per page (a newer nudge replaces the older).
    func placeHint(pageIndex: Int, anchorRect: CGRect, body: String) {
        withAnimation(.easeOut(duration: 0.3)) {
            items.removeAll { $0.pageIndex == pageIndex && $0.glyph == .hint }
            items.append(MarginItem(pageIndex: pageIndex, anchorRect: anchorRect,
                                    glyph: .hint, tone: .teaching, label: "", body: body))
        }
        Haptics.selection()
    }

    /// Removes a placed hint (it's been opened / addressed).
    func removeHint(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) { items.removeAll { $0.id == id } }
    }

    /// A transient highlight band drawn over a line when its hint is opened, so the
    /// student sees WHAT the tutor is talking about before the answer streams in.
    struct FocusHighlight: Equatable { var id = UUID(); var pageIndex: Int; var rect: CGRect }
    @Published var focusHighlight: FocusHighlight?
    private var focusClearTask: Task<Void, Never>?

    func focus(on item: MarginItem) {
        focusClearTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            focusHighlight = FocusHighlight(pageIndex: item.pageIndex, rect: item.anchorRect)
        }
        focusClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            await MainActor.run { withAnimation(.easeOut(duration: 0.4)) { self?.focusHighlight = nil } }
        }
    }

    /// Removes every watcher hint (e.g. when the watcher is switched off).
    func clearHints() {
        withAnimation(.easeOut(duration: 0.2)) { items.removeAll { $0.glyph == .hint } }
    }

    // MARK: - Check my work (triggered)

    /// OCRs the page, asks the AI to verify each line, and emits margin glyphs:
    /// ✓ on correct lines (staggered, top-down) and a single correction note on
    /// the first error.
    func checkWork(note: Note, pageIndex: Int, darkMode: Bool) async {
        guard sensitivity != .off else { return }
        let pages = note.sortedPages
        guard pages.indices.contains(pageIndex) else { return }
        let page = pages[pageIndex]

        notice = nil
        ghost = nil   // a stale idle-suggestion shouldn't linger over a check
        isChecking = true
        defer { isChecking = false }
        clear(pageIndex: pageIndex)

        // Vision fragments one equation into several observations (a lim stack,
        // a "∫ x dx =" split into "∫ x dx" + "="). Merge same-row fragments into
        // ONE line so each line is a whole statement the model can verdict, its
        // rect spans the equation for anchoring, and a trailing "=" is detected.
        // Rows come back ordered top-to-bottom, so line index == visual position.
        // A pasted question image/screenshot is rendered into the page, so its
        // printed text gets OCR'd too — never grade THAT (it's the problem, not
        // the student's work). Drop any region that sits inside a media frame.
        let mediaFrames = page.mediaItems.map(\.frame)
        let allOCR = await NoteContextBuilder.ocrLines(for: page)
        let inMedia: (OCRLine) -> Bool = { line in mediaFrames.contains { $0.intersects(line.rect) } }
        // The pasted question's printed text is OCR'd too. Pull it out as the
        // explicit PROBLEM STATEMENT (so the model has the task + its sub-parts
        // even if the small image is hard to read), and grade only the student's
        // own work (everything outside the media).
        let problem = allOCR.filter(inMedia).map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = Self.mergeRows(allOCR.filter { !inMedia($0) })
        // OCR found no text (a diagram, or handwriting it can't read) — if there IS
        // ink, grade the whole inked area as one region rather than refusing.
        if lines.isEmpty, let inkRect = Self.inkBounds(of: page) {
            lines = [OCRLine(text: "", rect: inkRect, confidence: 0)]
        }
        lastLineRects = lines.map(\.rect)
        guard !lines.isEmpty else {
            showNotice(String(localized: "ambient.notice.empty"))
            return
        }

        // Deterministic repeats: if the DRAWING hasn't changed since the last
        // grade, re-stream the cached verdicts rather than re-asking the (run-to-
        // run variable) model. Key on the drawing DATA, not the OCR text — OCR
        // jitters slightly between runs on identical ink, which would defeat the
        // cache and surface different verdicts for the same work.
        let inkHash = page.drawing.dataRepresentation().hashValue
        let signature = "\(pageIndex)#\(page.drawing.strokes.count)#\(inkHash)#\(page.mediaItems.count)"
        // A first check (or one after edits / on another page) replays the cache
        // for consistency; an immediate RE-TAP on the same unchanged page forces a
        // fresh grade so a wrong verdict isn't sticky.
        let forceFresh = (signature == lastCheckSignature)
        lastCheckSignature = signature
        if !forceFresh, let cached = checkCache[signature] {
            await stream(verdicts: cached, lines: lines, pageIndex: pageIndex)
            if items(onPage: pageIndex).isEmpty {
                showNotice(String(localized: "ambient.notice.allGood"))
            }
            return
        }

        do {
            let context = await NoteContextBuilder.build(
                note: note, currentPageIndex: pageIndex, darkMode: darkMode
            )
            var blocks = context.blocks
            blocks.append(.text(Self.checkInstruction(lines: lines, pageNumber: pageIndex + 1, problem: problem)))
            // Reply in the PAGE's language — a Hebrew page gets a Hebrew note/fix.
            if lines.map(\.text).joined(separator: " ").isMostlyRTL {
                blocks.append(.text("The page is in HEBREW — write every \"note\" (and any worded \"fix\") in HEBREW."))
            }
            // Per-item y/anchor/note/fix is verbose; give it room so a multi-
            // equation page doesn't truncate mid-array.
            // temperature 0 → grading the SAME page gives the SAME verdicts every
            // run (was varying because the default temperature samples randomly).
            let raw = try await AIService.send(system: Self.checkSystem, messages: [.user(blocks)], maxTokens: 4500, temperature: 0)
            var verdicts = Self.parseVerdicts(raw)
            guard !verdicts.isEmpty else {
                showNotice(String(localized: "ambient.notice.unreadable"))
                return
            }
            // Coverage WITHOUT guessing: the model sometimes omits a region. We do
            // NOT assume omitted == correct (that would stamp a ✓ on a wrong line).
            // Instead, re-ask it to actually grade just the missing math regions.
            let covered = Set(verdicts.map(\.line))
            let missing = lines.enumerated().filter { (i, line) in
                guard !covered.contains(i) else { return false }
                let t = line.text.trimmingCharacters(in: .whitespaces)
                guard !t.hasSuffix(":"), !Self.isOpenLine(t) else { return false }     // header / unfinished
                // Re-grade ANY uncovered region with real content (an equation, a
                // digit, or a worded claim). Only bare/stray fragments are skipped,
                // so the page gets fully covered instead of silently dropping lines.
                return t.contains(where: { $0.isNumber || $0.isLetter || "+-=×÷*/^()√∫π".contains($0) })
            }
            if !missing.isEmpty {
                let numbered = missing.map { "\($0.offset): \($0.element.text)" }.joined(separator: "\n")
                var followUp = context.blocks
                followUp.append(.text("""
                You graded most of page \(pageIndex + 1) but skipped some regions. \
                Using your solution from before, grade EACH of these remaining regions \
                now (read the image; classify correct / wrong / unfinished / skip — a \
                final answer CAN be wrong; never "skip" real work):
                \(numbered)
                Reason briefly, then return the verdicts for these indices as a ```json \
                block: {"regions":[{"i":<index>,"status":"…", …}]}.
                """))
                if let raw2 = try? await AIService.send(system: Self.checkSystem, messages: [.user(followUp)], maxTokens: 2500, temperature: 0) {
                    let still = Set(verdicts.map(\.line))
                    verdicts += Self.parseVerdicts(raw2).filter { !still.contains($0.line) }
                }
            }
            // Cache the completed grade so re-running on this unchanged page is
            // deterministic (identical glyphs every tap).
            checkCache[signature] = verdicts
            await stream(verdicts: verdicts, lines: lines, pageIndex: pageIndex)
            // Nothing settled in the lane (e.g. Subtle with no errors): say so,
            // instead of looking like the tap did nothing.
            if items(onPage: pageIndex).isEmpty {
                showNotice(String(localized: "ambient.notice.allGood"))
            }
        } catch {
            Haptics.error()
            showNotice(error.localizedDescription)
        }
    }

    func dismissDiagnostic() {
        if diagnostic != nil { withAnimation(.easeOut(duration: 0.2)) { diagnostic = nil } }
    }

    // MARK: - 1a guided ladder (reveal in layers)

    func dismissLadder() {
        if guidedLadder != nil { withAnimation(.easeOut(duration: 0.2)) { guidedLadder = nil } }
    }
    /// Reveal one rung deeper (question → hint → step). At the step, the line is also
    /// written faintly as a ghost so it can be traced.
    func advanceLadder() {
        guard var g = guidedLadder else { return }
        g.rung = min(3, g.rung + 1)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { guidedLadder = g }
        if g.rung == 3, let latex = g.step.stepLatex {
            let text = Self.cleanGhost(latex)
            if !text.isEmpty {
                withAnimation(.easeIn(duration: 0.25)) {
                    ghost = GhostSuggestion(pageIndex: g.pageIndex, anchor: g.anchor, text: text,
                                            why: g.step.hint, steps: [], inline: false,
                                            blankToken: Self.cleanBlankToken(g.step.blankToken, in: text))
                }
            }
        }
    }
    func replayLadder() {
        guard var g = guidedLadder else { return }
        ghost = nil
        g.rung = 1
        withAnimation(.easeOut(duration: 0.2)) { guidedLadder = g }
    }

    /// Start the 1a ladder for the page's last line — ONE `next_step` call returns the
    /// nudge/hint/step; the card reveals up to the current rung. Reads the page image.
    func startGuidedLadder(note: Note, pageIndex: Int, darkMode: Bool) async {
        guard sensitivity != .off else { return }
        let pages = note.sortedPages
        guard pages.indices.contains(pageIndex) else { return }
        let page = pages[pageIndex]
        ghost = nil; dismissDiagnostic(); clearGradePrompt()

        let mediaFrames = page.mediaItems.map(\.frame)
        let allOCR = await NoteContextBuilder.ocrLines(for: page)
        let inMedia: (OCRLine) -> Bool = { line in mediaFrames.contains { $0.intersects(line.rect) } }
        let lines = Self.mergeRows(allOCR.filter { !inMedia($0) })
        guard let last = lines.max(by: { $0.rect.maxY < $1.rect.maxY }) else {
            showNotice(String(localized: "ambient.notice.empty")); return
        }
        let focusLine = lines.firstIndex(where: { $0.rect == last.rect })
        let anchor = CGPoint(x: last.rect.minX, y: last.rect.maxY + last.rect.height * 0.7)

        isSuggesting = true
        defer { isSuggesting = false }
        do {
            let context = await NoteContextBuilder.build(note: note, currentPageIndex: pageIndex, darkMode: darkMode)
            let region = context.blocks.compactMap { block -> Data? in
                if case let .imagePNG(data) = block { return data } else { return nil }
            }.first
            let envelope = AIClient.buildEnvelope(lines: lines, focusLine: focusLine,
                                                  guidedLevel: sensitivity.rawValue, askDepth: 3)
            let step = try await AIClient.call(.next_step, envelope: envelope, region: region,
                                               maxTokens: 1400, as: AIClient.NextStep.self)
            guard let step, (step.nudge != nil || step.hint != nil || step.stepLatex != nil) else {
                showNotice(String(localized: "ambient.notice.noSuggestion")); return
            }
            withAnimation(.easeOut(duration: 0.25)) {
                guidedLadder = GuidedLadderState(step: step, rung: 1, anchor: anchor, pageIndex: pageIndex)
            }
        } catch {
            showNotice(error.localizedDescription)
        }
    }

    /// DEV-only (env `CONOTE_DEMO_CHECK`): inject the canonical 3b diagnostic with
    /// synthetic line rects so the surface can be eyeballed in the editor without an
    /// API key. No effect unless the flag is set.
    func injectDemoDiagnostic(pageIndex: Int, pageSize: CGSize) {
        let x = pageSize.width * 0.10
        let top = pageSize.height * 0.20
        let step = pageSize.height * 0.055
        let rects = (0..<5).map { i in
            CGRect(x: x, y: top + CGFloat(i) * step, width: pageSize.width * 0.55, height: pageSize.height * 0.035)
        }
        withAnimation(.easeIn(duration: 0.3)) {
            diagnostic = DiagnosticState(
                pageIndex: pageIndex, ok: [true, true, true, true, false], brokenLine: 4,
                error: AIClient.CheckResult.FirstError(
                    line: 4, why: "You put 2x back in for u. But the substitution was u = x² — so the answer is:",
                    fixLatex: "\\sin(x^2) + C", rubricTag: "back-substitution"),
                praise: "Four clean steps!", lineRects: rects)
        }
    }

    /// 3b "Check my work · straight to the break" (handoff §4.3): reads the page
    /// on-device into a parsed line structure, runs the schema-constrained `check`
    /// Gemini call, and surfaces the line-health map + the FIRST error's diagnostic.
    /// Replaces the streaming verdict-glyph flow for the tutor's check surface.
    func runDiagnostic(note: Note, pageIndex: Int, darkMode: Bool) async {
        guard sensitivity != .off else { return }
        let pages = note.sortedPages
        guard pages.indices.contains(pageIndex) else { return }
        let page = pages[pageIndex]

        notice = nil; ghost = nil; clearGradePrompt(); dismissDiagnostic()
        isChecking = true
        defer { isChecking = false }

        // Same on-device read as checkWork: merge OCR rows, drop the pasted question
        // image's printed text, fall back to the whole inked area when OCR is blank.
        let mediaFrames = page.mediaItems.map(\.frame)
        let allOCR = await NoteContextBuilder.ocrLines(for: page)
        let inMedia: (OCRLine) -> Bool = { line in mediaFrames.contains { $0.intersects(line.rect) } }
        var lines = Self.mergeRows(allOCR.filter { !inMedia($0) })
        if lines.isEmpty, let inkRect = Self.inkBounds(of: page) {
            lines = [OCRLine(text: "", rect: inkRect, confidence: 0)]
        }
        guard !lines.isEmpty else { showNotice(String(localized: "ambient.notice.empty")); return }
        let lineRects = lines.map(\.rect)
        lastLineRects = lineRects

        // Grade with the PROVEN pipeline (reads the page IMAGE + the detailed rubric) —
        // the schema-constrained `check` call was unreliable on real handwriting ("can't
        // read the page"). Map its verdicts onto the 3b diagnostic surface, and reply in
        // the PAGE's language (a Hebrew page gets a Hebrew note, not English).
        let problem = allOCR.filter(inMedia).map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pageIsRTL = lines.map(\.text).joined(separator: " ").isMostlyRTL
        do {
            let context = await NoteContextBuilder.build(note: note, currentPageIndex: pageIndex, darkMode: darkMode)
            var blocks = context.blocks
            blocks.append(.text(Self.checkInstruction(lines: lines, pageNumber: pageIndex + 1, problem: problem)))
            if pageIsRTL {
                blocks.append(.text("The page is in HEBREW — write every \"note\" (and any worded \"fix\") in HEBREW."))
            }
            let raw = try await AIService.send(system: Self.checkSystem, messages: [.user(blocks)], maxTokens: 4500, temperature: 0)
            let verdicts = Self.parseVerdicts(raw)
            guard !verdicts.isEmpty else { showNotice(String(localized: "ambient.notice.unreadable")); return }

            var ok = Array(repeating: true, count: lines.count)
            for v in verdicts where lines.indices.contains(v.line) && !v.unfinished && !v.ignore {
                ok[v.line] = v.ok
            }
            // The FIRST real error, top-down (§4.3 "straight to the break").
            let firstWrong = verdicts
                .filter { !$0.ok && !$0.unfinished && !$0.ignore }
                .min(by: { $0.line < $1.line })
            let error: AIClient.CheckResult.FirstError? = firstWrong.map { v in
                AIClient.CheckResult.FirstError(
                    line: v.line, why: v.note, fixLatex: v.fix ?? "",
                    rubricTag: v.label.trimmingCharacters(in: .whitespaces))
            }
            if let e = error, lines.indices.contains(e.line) { ok[e.line] = false }
            withAnimation(.easeIn(duration: 0.3)) {
                diagnostic = DiagnosticState(pageIndex: pageIndex, ok: ok, brokenLine: error?.line,
                                             error: error, praise: nil, lineRects: lineRects)
            }
            if error == nil { showNotice(String(localized: "ambient.notice.allGood")) }
            Haptics.selection()
        } catch {
            Haptics.error()
            showNotice(error.localizedDescription)
        }
    }

    /// Streams glyphs top-down (120ms each): ✓ on the correct regions, then a
    /// single correction on the FIRST wrong one — and stops there. Anchored to the
    /// region's own OCR rect, and the model decides completeness (so OCR dropping
    /// the "3" in "lim…=3" can't suppress a valid correction).
    private func stream(verdicts: [Verdict], lines: [OCRLine], pageIndex: Int) async {
        let minConf = sensitivity == .subtle ? 0.90 : 0.0
        var placed: [CGRect] = []
        for v in verdicts.sorted(by: { $0.line < $1.line }) {
            guard lines.indices.contains(v.line) else { continue }
            // Unfinished (no answer yet) or non-math (skip) → no glyph.
            if v.unfinished || v.ignore { continue }
            let text = lines[v.line].text.trimmingCharacters(in: .whitespaces)
            // A header/label (ends with ':') is a section title, not work — no glyph.
            if text.hasSuffix(":") || text.hasSuffix("：") { continue }
            let rect = lines[v.line].rect
            // Dedup ONLY a near-touching duplicate (e.g. a fraction's numerator and
            // denominator that OCR split into two rows). The gap must be tiny — two
            // distinct statements the student stacked (x≠1 over x≠-3) sit a real
            // fraction of a line apart and BOTH deserve a glyph, so they must NOT
            // collapse here. Requires strong horizontal overlap too.
            if placed.contains(where: { p in
                let gap = max(p.minY, rect.minY) - min(p.maxY, rect.maxY)
                let overlap = min(p.maxX, rect.maxX) - max(p.minX, rect.minX)
                return gap < 0.25 * min(p.height, rect.height)
                    && overlap > 0.5 * min(p.width, rect.width)
            }) { continue }
            placed.append(rect)
            if v.ok {
                if sensitivity == .subtle { continue } // Subtle: errors only
                withAnimation(.easeOut(duration: 0.3)) {
                    items.append(MarginItem(pageIndex: pageIndex, anchorRect: rect,
                                            glyph: .correct, tone: .correct,
                                            label: "", body: ""))
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            } else if v.confidence >= minConf {
                withAnimation(.easeOut(duration: 0.3)) {
                    items.append(MarginItem(
                        pageIndex: pageIndex, anchorRect: rect,
                        glyph: .attend, tone: .correction,
                        label: v.label.isEmpty ? "Almost —" : v.label,
                        body: v.note, result: v.fix?.isEmpty == true ? nil : v.fix))
                }
                Haptics.selection()
                // Stop at the FIRST wrong line: everything below it usually follows
                // from this one error, so flagging the rest is noise. The student
                // fixes here and re-checks. (Verdicts are sorted top-down, so this
                // is the first error in the worked solution.)
                break
            }
        }
    }

    // MARK: - Ghost next-step

    func dismissGhost() {
        withAnimation(.easeOut(duration: 0.2)) { ghost = nil }
    }

    /// A "grade my answer" glyph anchored to the student's last line — shown after
    /// they finish writing; tapping it runs checkWork on the page.
    @Published var gradePrompt: GradePrompt?

    func offerGrade(pageIndex: Int, anchor: CGPoint) {
        guard !isChecking else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            gradePrompt = GradePrompt(pageIndex: pageIndex, anchor: anchor)
        }
    }
    func clearGradePrompt() {
        if gradePrompt != nil { withAnimation(.easeOut(duration: 0.2)) { gradePrompt = nil } }
    }

    /// Inline "why" → worked steps, shown in the step UI near the line (NOT the AI
    /// chat bubble). Used by the grade-result note, the hint glyph, etc.
    @Published var explanation: StepExplanation?

    func explainSteps(focus: String, anchor: CGPoint, pageIndex: Int, note: Note, darkMode: Bool, itemID: UUID? = nil) async {
        withAnimation(.easeOut(duration: 0.2)) {
            explanation = StepExplanation(pageIndex: pageIndex, anchor: anchor, why: nil, steps: [], isLoading: true, itemID: itemID)
        }
        do {
            let context = await NoteContextBuilder.build(note: note, currentPageIndex: pageIndex, darkMode: darkMode)
            var blocks = context.blocks
            blocks.append(.text("The student wants to understand this point in their work: \"\(focus)\". Explain it as a short ordered sequence of WORKED steps that follow from / correct their actual work on the page. ALWAYS return AT LEAST 2 items in \"steps\" — never leave it empty (that is the whole point). Output JSON ONLY: {\"why\":\"<ONE short sentence, in the student's WRITTEN language, saying which rule/operation and on what>\",\"steps\":[\"<each step: what you do, then ' → ', then the RESULTING expression in $...$; at least 2, at most 5>\"]}. Write \"why\" and \"steps\" in the language of the student's handwriting on the page (e.g. Hebrew for a Hebrew page), not necessarily \(SystemPrompt.languageTarget)."))
            let raw = try await AIService.send(system: Self.explainSystem, messages: [.user(blocks)], maxTokens: 1200)
            let (why, steps, rawHighlights) = Self.parseSteps(raw)
            // Don't clobber a newer request.
            guard explanation?.anchor == anchor, explanation?.isLoading == true else { return }
            let pageSize = note.sortedPages.indices.contains(pageIndex)
                ? note.sortedPages[pageIndex].canvasSize : .zero
            let highlights = Self.resolveHighlights(rawHighlights, pageSize: pageSize)
            withAnimation(.easeOut(duration: 0.2)) {
                explanation = StepExplanation(pageIndex: pageIndex, anchor: anchor, why: why, steps: steps,
                                              isLoading: false, itemID: itemID, highlights: highlights)
            }
        } catch {
            if explanation?.anchor == anchor { explanation = nil }
        }
    }
    func dismissExplanation() {
        if explanation != nil { withAnimation(.easeOut(duration: 0.2)) { explanation = nil } }
    }

    private static let explainSystem = "You are an expert tutor for whatever subject the page shows (math, science, a language, the humanities — never assume it is math). READ the student's handwriting from the page image (OCR is unreliable — trust the image) and any problem statement on the page. Explain the requested point as a SHORT ordered sequence of steps that follow from the student's own work — each step is one action and its result (a worked expression for math; a sentence/fact/step for other subjects). Output ONLY the requested JSON: no prose, no greeting, no chat."

    /// Called when the student writes again — the ghost is stale; clear it and
    /// re-arm so a fresh suggestion can come for the new line.
    func invalidateGhost() {
        if ghost != nil { ghost = nil }
        lastGhostSourceLine = nil
    }

    /// Predict the next line and show it as a ghost. `auto` = fired by the idle
    /// timer (vs the explicit "Suggest next step" button). Auto only COMPLETES an
    /// unfinished line (high-signal); it won't speculate a whole new line — that's
    /// the noisy case, reserved for the manual button.
    func suggestNext(note: Note, pageIndex: Int, darkMode: Bool, auto: Bool = false) async {
        guard ghost == nil else { return }
        let pages = note.sortedPages
        guard pages.indices.contains(pageIndex) else { return }
        let page = pages[pageIndex]
        // Ignore the pasted question image's text — predict from the student's
        // own work, not the problem statement.
        let mediaFrames = page.mediaItems.map(\.frame)
        let lines = Self.mergeRows(await NoteContextBuilder.ocrLines(for: page))
            .filter { line in !mediaFrames.contains { $0.intersects(line.rect) } }
        // An UNFINISHED line (ends with =, an operator, →) is the real target:
        // the student is waiting to fill in its right-hand side, so complete it
        // inline. Only the MANUAL button speculates a brand-new line below.
        let openLine = lines
            .filter { Self.isOpenLine($0.text) }
            .max(by: { $0.rect.maxY < $1.rect.maxY })
        let lowest = lines.max(by: { $0.rect.maxY < $1.rect.maxY })
        // A short bare lowest line (e.g. "x =", or "x" with the '=' lost by OCR)
        // is an unfinished line to COMPLETE, even if isOpenLine didn't catch it.
        let lowestShortIncomplete = lowest.map {
            $0.text.filter({ !$0.isWhitespace }).count <= 4
        } ?? false
        // Idle auto-suggest now targets the last line even when it looks "finished"
        // (was returning nil → "doesn't suggest anything"); the model gives the next
        // step below it. lastGhostSourceLine still dedupes repeats for the same line.
        var target: OCRLine? = openLine ?? lowest
        // No OCR'd line but there IS ink (a diagram, or handwriting OCR can't read) —
        // anchor to the last written row and let the model read it from the image,
        // rather than giving up with "no next step". This applies to the IDLE (auto)
        // path too: math handwriting fails OCR constantly, so without this the ambient
        // ghost silently never fired ("stop writing and nothing shows up") while the
        // manual button — which always had this fallback — worked.
        var fromImage = false
        if target == nil, let row = Self.lastInkRow(of: page) {
            target = OCRLine(text: "", rect: row, confidence: 0)
            fromImage = true
        }
        guard let last = target else { return }
        // OCR'd lines must be non-empty and not a repeat; the image-anchored fallback
        // has no text to dedupe on, so it proceeds.
        if !fromImage {
            guard !last.text.trimmingCharacters(in: .whitespaces).isEmpty,
                  last.text != lastGhostSourceLine else { return }
        }
        let isOpen = openLine != nil || lowestShortIncomplete

        if !auto { isSuggesting = true }
        defer { if !auto { isSuggesting = false } }
        do {
            let context = await NoteContextBuilder.build(note: note, currentPageIndex: pageIndex, darkMode: darkMode)
            var blocks = context.blocks
            // Anchor the model to the student's ACTUAL last line so it continues
            // from there (not back at the top of the page).
            let lastText = last.text.trimmingCharacters(in: .whitespaces)
            // When OCR gave us the text, quote it; otherwise tell the model to read
            // the last line straight off the page image.
            let lineRef = lastText.isEmpty
                ? "The student's LAST handwritten line — READ it from the page image (OCR couldn't)"
                : "The student's LAST handwritten line reads roughly: \"\(lastText)\""
            let instruction = isOpen
                ? "\(lineRef) and it is UNFINISHED. Continue from THERE — give the single next line that directly follows it, completing what they started. For math: do the algebra and write the COMPLETE result that belongs after the '=' (e.g. '2x =' → the value of x; a derivative → the fully simplified form combining ALL factors). For an essay or any other subject: finish that sentence/point correctly. Never restate the left side, never jump back to an earlier step, never a partial fragment. Use LaTeX for math (\\frac{num}{den} NOT a/b, x^{2}, x_{0}, \\sqrt{...}, · for multiply); plain words for non-math. Output ONLY that line — no $ delimiters. If you genuinely can't, output nothing."
                : "\(lineRef). Give the SINGLE most useful next line toward completing the task — continue from there, do NOT jump back to an earlier step. Use LaTeX for math (\\frac{num}{den}, x^{2}, \\sqrt{...}, · for multiply); plain words for non-math. Output ONLY the line — no $ delimiters. ALWAYS give your best next step; output nothing ONLY if the page is blank or truly unreadable."
            blocks.append(.text(instruction))
            blocks.append(.text("ALWAYS include \"steps\": AT LEAST 2 (up to 5) ordered sub-steps that SHOW HOW you got to this next line — never leave it empty. Format EACH step as: what you do, then ' → ', then the RESULT after that step (in $...$ where the content is math, plain words otherwise) — so the student sees the output at each stage. Write \"why\" and \"steps\" in the language of the student's handwriting on the page (e.g. Hebrew for a Hebrew page), not necessarily \(SystemPrompt.languageTarget). Also include \"highlights\": the specific params/terms/values FROM THE STUDENT'S OWN WORK that you used to derive this step (e.g. a factor, a coefficient, a given quantity, a named term — for ANY subject, not just math), at most 4, ONLY ones actually written on the page. Each is {\"label\":\"<the term EXACTLY as it appears>\",\"box\":[x,y,w,h]} where box is the term's location in the page image as fractions 0–1 (x,y = top-left, w,h = size). Omit highlights you can't locate; never invent a box."))
            // Headroom for Gemini 2.5 thinking tokens (which count against the cap)
            // so the {next,why} JSON isn't truncated mid-string.
            // Headroom for Gemini 2.5 thinking tokens + the "steps" array, so the
            // {next,why,steps} JSON isn't truncated (which dropped the steps).
            let raw = try await AIService.send(system: Self.ghostSystem, messages: [.user(blocks)], maxTokens: 2200)
            let (nextRaw, why, steps, rawHighlights, blankToken) = Self.parseGhost(raw)
            let text = Self.cleanGhost(nextRaw)
            guard !text.isEmpty, text.count < 140 else { return }
            // Drop a suggestion that just echoes the line it's completing. The MANUAL
            // button is lenient — only an EXACT echo is rejected, because a legitimate
            // simplification/next step reuses tokens from the line above (that was
            // dropping real suggestions → "no next step"). Auto stays strict (no noise).
            let a = Self.mathKey(text), b = Self.mathKey(last.text)
            // Reject only an EXACT echo of the line being continued (same rule for auto
            // and manual now). The old auto-only `b.contains(a)` test threw away valid
            // next steps that legitimately reuse a token from the current line — a big
            // reason the idle ghost "never showed anything".
            let isEcho = (a == b)
            guard a.count >= 1, !isEcho else { return }
            lastGhostSourceLine = last.text
            let highlights = Self.resolveHighlights(rawHighlights, pageSize: page.canvasSize)
            let anchor = isOpen
                ? CGPoint(x: last.rect.maxX + 14, y: last.rect.midY)                    // inline, centred on the line
                : CGPoint(x: last.rect.minX, y: last.rect.maxY + last.rect.height * 0.7) // new line below, clearing a fraction
            withAnimation(.easeIn(duration: 0.25)) {
                ghost = GhostSuggestion(pageIndex: pageIndex, anchor: anchor, text: text, why: why,
                                        steps: steps, inline: isOpen, highlights: highlights,
                                        blankToken: Self.cleanBlankToken(blankToken, in: text))
            }
        } catch { }
    }

    private static let ghostSystem = "You are an expert tutor giving a student the next step of their work. The subject may be anything — math, science, a language, an essay — so adapt; NEVER assume math. READ their handwriting from the attached page image (OCR misreads math, diagrams, and non-Latin scripts — trust the image). FIRST read any problem statement on the page — typed, printed, or a pasted screenshot/photo, possibly in another language (e.g. Hebrew) — that defines the task. Then actually WORK IT OUT yourself: the genuine next step toward completing THAT task (for math: simplify/factor/take the limit and give the worked result; for an essay or other subject: the next sentence, point, or step) — never just re-copy what the student already wrote, never a half-answer. Output a JSON object: {\"next\":\"<that one line — as LaTeX for math (\\\\frac{num}{den}, x^{2}, \\\\sqrt{...}, · for multiply; no $ delimiters); as plain words for non-math; no extra words>\",\"why\":\"<ONE short sentence, in the student's language, explaining WHY this is the next step>\",\"steps\":[\"<ordered sub-steps leading to <next>, each one short line, LaTeX in $...$ only where the content is math, at most 5>\"],\"blankToken\":\"<the SINGLE token inside <next> that best proves understanding (the substituted variable / key operand) — it appears VERBATIM in <next> and will be masked first in the fill-in ghost; omit if nothing fits>\",\"highlights\":[{\"label\":\"<a param/term/value FROM THE STUDENT'S OWN WORK you used to get <next> — any subject>\",\"box\":[x,y,w,h]}]}. In \"highlights\" the box is the term's location in the page image as fractions 0–1 (top-left x,y + size w,h); include at most 4, only terms actually on the page, and omit any you can't locate. If you can't produce a correct, useful next step, output {}."

    /// Pulls the {next, why} out of the ghost response (tolerates fences / prose /
    /// truncation). Critically, it NEVER falls back to dumping the raw string: a
    /// response that looks like JSON but won't parse returns empty, so we never
    /// write `{"next":"…` braces onto the page as ink.
    private static func parseGhost(_ raw: String) -> (String, String?, [String], [RawHighlight], String?) {
        var src = raw
        if let f = raw.range(of: "```json", options: .caseInsensitive),
           let c = raw.range(of: "```", range: f.upperBound..<raw.endIndex) {
            src = String(raw[f.upperBound..<c.lowerBound])
        } else if let f = raw.range(of: "```"),
                  let c = raw.range(of: "```", range: f.upperBound..<raw.endIndex) {
            src = String(raw[f.upperBound..<c.lowerBound])
        }
        // 1) Strict JSON object — only attempt it when there's actually a "next" key.
        //    A bare LaTeX answer (\frac{x-3}{2\sqrt{x}}) also has { }, and must NOT be
        //    fed to JSONSerialization and then written off as unparseable.
        if src.contains("\"next\""),
           let s = src.firstIndex(of: "{"), let e = src.lastIndex(of: "}"),
           let data = String(src[s...e]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let next = obj["next"] as? String {
            let why = (obj["why"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let steps = (obj["steps"] as? [String])?.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? []
            let blank = (obj["blankToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (next, (why?.isEmpty == false) ? why : nil, steps, parseHighlights(obj), (blank?.isEmpty == false) ? blank : nil)
        }
        // 2) Regex-extract the string values — survives truncation (a cut-off
        //    response with no closing brace) and stray escaping. Highlights are a
        //    nice-to-have, so the truncation path simply omits them.
        let nextVal = firstCapture(#""next"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: src).map(unescapeJSON)
        let whyVal = firstCapture(#""why"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: src).map(unescapeJSON)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let nextVal, !nextVal.isEmpty {
            // Recover steps too (path 1 returned them, but this fallback used to drop
            // them — that's why the "?" sometimes showed a why with no steps).
            let blank = firstCapture(#""blankToken"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: src).map(unescapeJSON)
            return (nextVal, (whyVal?.isEmpty == false) ? whyVal : nil, recoverSteps(in: src), [], (blank?.isEmpty == false) ? blank : nil)
        }
        // 2.5) PROSE fallback — the model frequently ignores "output JSON" and writes
        //    the answer as text: "<answer>\nwhy: <sentence>\nsteps:\n- <s1>\n- <s2>",
        //    often with the math wrapped in $…$. Parse that leniently so the ghost still
        //    appears (this was the "OK round-trip in the log but nothing on the page").
        if !src.contains("\"next\""), let prose = parseProseGhost(src) { return prose }
        // 3) Real broken JSON (an actual "next"/"why" KEY that wouldn't parse) → render
        //    nothing rather than spilling braces/keys as ink. A lone brace from LaTeX no
        //    longer counts here — it used to swallow every \frac/\sqrt answer as empty.
        if src.contains("\"next\"") || src.contains("\"why\"") {
            return ("", nil, [], [], nil)
        }
        // 4) Genuinely plain text — treat the first non-empty line as the next line.
        return (raw, nil, [], [], nil)
    }

    /// The model wrote the next step as PROSE instead of JSON — commonly
    /// "<answer line>\nwhy: <one sentence>\nsteps:\n- <s1>\n- <s2>", with the math
    /// possibly wrapped in $…$. Pull out next / why / steps; nil if there's no answer
    /// line (so the caller can fall through). No blankToken (prose rarely marks one).
    private static func parseProseGhost(_ src: String) -> (String, String?, [String], [RawHighlight], String?)? {
        let whyR = src.range(of: "why:", options: .caseInsensitive)
        let stepsR = src.range(of: "steps:", options: .caseInsensitive)
        let firstLabel = [whyR?.lowerBound, stepsR?.lowerBound].compactMap { $0 }.min()
        // The answer = the first non-empty line BEFORE any why:/steps: label. Skip lines
        // that look like leftover JSON syntax so a malformed object doesn't leak through.
        let head = firstLabel.map { String(src[src.startIndex..<$0]) } ?? src
        let next = head.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("{") && !$0.hasPrefix("\"") } ?? ""
        guard !next.isEmpty else { return nil }
        var why: String?
        if let whyR {
            let end = (stepsR.map { $0.lowerBound > whyR.upperBound } ?? false) ? stepsR!.lowerBound : src.endIndex
            why = String(src[whyR.upperBound..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var steps: [String] = []
        if let stepsR {
            steps = String(src[stepsR.upperBound...])
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: #"^[-•*]+\s*"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"^\d+[.)]\s*"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return (next, (why?.isEmpty == false) ? why : nil, steps, [], nil)
    }

    /// One un-resolved highlight as the model returned it: the term it used + the
    /// normalized [x,y,w,h] box (0–1, page-image space) where it sits in the work.
    struct RawHighlight { let label: String; let box: [Double]? }

    /// Pull the optional "highlights" array out of a parsed JSON object.
    private static func parseHighlights(_ obj: [String: Any]) -> [RawHighlight] {
        guard let arr = obj["highlights"] as? [[String: Any]] else { return [] }
        return arr.prefix(4).compactMap { h in
            guard let label = (h["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty else { return nil }
            let box = (h["box"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
            return RawHighlight(label: label, box: (box?.count == 4) ? box : nil)
        }
    }

    /// Resolve raw highlights to canvas-space: each normalized box → a page rect,
    /// each gets the next palette color (so chip ↔ on-ink box match by index).
    static func resolveHighlights(_ raw: [RawHighlight], pageSize: CGSize) -> [AIHighlight] {
        raw.enumerated().map { i, h in
            let rect: CGRect? = h.box.map { b in
                CGRect(x: b[0] * pageSize.width, y: b[1] * pageSize.height,
                       width: max(10, b[2] * pageSize.width), height: max(10, b[3] * pageSize.height))
            }
            return AIHighlight(label: h.label, rect: rect, colorIndex: i)
        }
    }

    /// Parse {"why","steps"} for the inline explanation (no "next" field, so the
    /// ghost parser — which requires "next" — can't be reused).
    private static func parseSteps(_ raw: String) -> (String?, [String], [RawHighlight]) {
        let src = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = src.firstIndex(of: "{"), let e = src.lastIndex(of: "}"),
           let data = String(src[s...e]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let why = (obj["why"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let steps = (obj["steps"] as? [String])?.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? []
            return ((why?.isEmpty == false) ? why : nil, steps, parseHighlights(obj))
        }
        // Regex fallback (truncation / stray escaping): the why, then each quoted
        // string inside the steps array.
        let why = firstCapture(#""why"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: src).map(unescapeJSON)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var steps: [String] = []
        if let arr = firstCapture(#""steps"\s*:\s*\[(.*)\]"#, in: src),
           let re = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#, options: [.dotMatchesLineSeparators]) {
            for m in re.matches(in: arr, range: NSRange(arr.startIndex..., in: arr)) {
                if let r = Range(m.range(at: 1), in: arr) {
                    let v = unescapeJSON(String(arr[r])).trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { steps.append(v) }
                }
            }
        }
        return ((why?.isEmpty == false) ? why : nil, steps, [])
    }

    /// First capture group of `pattern` in `s`, or nil.
    private static func firstCapture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// Recover the "steps" array even from truncated/malformed JSON: take everything
    /// after `"steps":[` (to the closing `]`, or the end if cut off) and pull out the
    /// quoted string elements.
    private static func recoverSteps(in s: String) -> [String] {
        guard let start = s.range(of: #""steps"\s*:\s*\["#, options: .regularExpression) else { return [] }
        let tail = s[start.upperBound...]
        let body = String(tail.firstIndex(of: "]").map { tail[..<$0] } ?? tail)
        guard let re = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#, options: [.dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: body) else { return nil }
            return unescapeJSON(String(body[r]))
        }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Minimal JSON-string unescape: `\"`→`"`, `\\`→`\` (keeping LaTeX commands
    /// like `\frac` intact). Newlines collapse to spaces.
    private static func unescapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\/", with: "/")
    }

    /// Validate the 2a blank token: clean it, and keep it ONLY if it actually appears
    /// in the (unicode) ghost text so the fill-in split can't fail or blank the wrong span.
    private static func cleanBlankToken(_ token: String?, in text: String) -> String? {
        guard let raw = token?.trimmingCharacters(in: CharacterSet(charactersIn: " `'\"$=")), !raw.isEmpty else { return nil }
        return text.mathToUnicode().contains(raw.mathToUnicode()) ? raw : nil
    }

    private static func cleanGhost(_ raw: String) -> String {
        let lines = raw.split(whereSeparator: \.isNewline).map { String($0) }
        guard var text = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        // \text{…}/\mathrm{…} wrap a worded/Hebrew conclusion — unwrap to the inner
        // text (InkWriter has no \text layout; the braces would render literally).
        for cmd in ["text", "mathrm", "mbox", "operatorname"] {
            text = text.replacingOccurrences(
                of: "\\\\\(cmd)\\s*\\{([^{}]*)\\}", with: "$1",
                options: .regularExpression)
        }
        // Keep LaTeX (\frac, ^, _) — InkWriter lays it out as 2D ink. Strip $…$
        // math delimiters and a leading '='.
        text = text
            .replacingOccurrences(of: "*", with: "·")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " `'\"="))
        // Any JSON skeleton that slipped through (a stray key/brace) → reject.
        if text.contains("\"next\"") || text.contains("\"why\"") || text.hasPrefix("{") {
            return ""
        }
        return text
    }

    /// True when a line is unfinished — it ends with `=` or an operator (so its
    /// right-hand side is still to come). OCR misreads notation, but trailing
    /// `=`/operators survive recognition well enough to drive completion.
    /// Lowercased alphanumerics only — for echo detection (is the suggestion just
    /// a copy of the line it's completing?).
    private static func mathKey(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    // MARK: Ink fallbacks — when OCR reads nothing but the page DOES have ink, the
    // tutor anchors to stroke geometry instead of refusing ("nothing to check" /
    // "no next step"). The model reads the actual content from the page image.

    private static func pageStrokes(_ page: Page) -> [VectorInk.Stroke] {
        page.vectorInkData.flatMap { VectorInk.decode($0) } ?? []
    }

    /// Bounding box of all the page's vector ink (nil if the page is blank).
    private static func inkBounds(of page: Page) -> CGRect? {
        let s = pageStrokes(page)
        guard let first = s.first else { return nil }
        return s.dropFirst().reduce(first.bbox) { $0.union($1.bbox) }
    }

    /// Bounding box of the lowest row of ink — the "last handwritten line".
    private static func lastInkRow(of page: Page) -> CGRect? {
        let s = pageStrokes(page)
        guard !s.isEmpty else { return nil }
        let maxY = s.map { $0.bbox.maxY }.max() ?? 0
        let row = s.filter { $0.bbox.maxY >= maxY - 46 }   // ~one line height
        guard let first = row.first else { return inkBounds(of: page) }
        return row.dropFirst().reduce(first.bbox) { $0.union($1.bbox) }
    }

    static func isOpenLine(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        // Trailing '(' (e.g. a half-written derivative "…)(") is unfinished too.
        return "=+-−×÷*/·→≤≥<>(".contains(last)
    }

    /// Collapses Vision's per-fragment observations into one entry per visual
    /// row: fragments whose vertical spans overlap belong to the same equation
    /// (e.g. "∫ x dx" + "="), so they're concatenated left-to-right and their
    /// rects unioned. Returns rows ordered top-to-bottom. Stacked notation (a
    /// lim's "x→0" under "lim") stays on its own row — little vertical overlap.
    static func mergeRows(_ lines: [OCRLine]) -> [OCRLine] {
        // Pass 1 — same baseline: join fragments that vertically overlap into one
        // row (e.g. "∫ x dx" + "=" + "1").
        let sorted = lines.sorted { $0.rect.minY < $1.rect.minY }
        var rows: [OCRLine] = []
        for line in sorted {
            guard let last = rows.last else { rows.append(line); continue }
            let overlap = min(last.rect.maxY, line.rect.maxY) - max(last.rect.minY, line.rect.minY)
            // Horizontal gap between the running row and this fragment. Tokens of
            // ONE equation sit close; two separate items on the same baseline (a
            // left-aligned equation and a far-right conclusion, e.g. "1+1=2" and
            // "אין נק׳ קיצון") have a big gap and must stay SEPARATE so each is
            // judged on its own.
            let hGap = max(last.rect.minX, line.rect.minX) - min(last.rect.maxX, line.rect.maxX)
            let nearEnough = hGap < 3.0 * max(last.rect.height, line.rect.height)
            if overlap > 0.4 * min(last.rect.height, line.rect.height) && nearEnough {
                rows[rows.count - 1] = join(last, line)
            } else {
                rows.append(line)
            }
        }
        return rows
    }

    /// Joins two OCR fragments into one, text ordered left-to-right, rects unioned.
    private static func join(_ a: OCRLine, _ b: OCRLine) -> OCRLine {
        let leftFirst = a.rect.minX <= b.rect.minX
        return OCRLine(
            text: leftFirst ? "\(a.text) \(b.text)" : "\(b.text) \(a.text)",
            rect: a.rect.union(b.rect),
            confidence: min(a.confidence, b.confidence)
        )
    }

    // MARK: - AI plumbing

    /// One region's verdict, keyed to the OCR region index `i`. `unfinished`
    /// means no answer yet; `ignore` means the model said it's not math (skip).
    /// Both render no glyph but count as "covered" so they aren't backfilled.
    private struct Verdict { var line: Int; var ok: Bool; var unfinished: Bool; var ignore: Bool = false; var note: String; var fix: String?; var label: String; var confidence: Double }

    private static let checkSystem = """
    You are a meticulous tutor checking a student's handwritten work. The subject may be \
    ANYTHING — math, the sciences, a language, the humanities — so adapt to what the page \
    shows; never assume it is math. The page IMAGE is attached, with a NUMBERED list of \
    regions (one per handwriting line) and rough OCR (OFTEN WRONG on handwriting — math \
    notation, chemical formulas, diagrams, non-Latin scripts, messy writing — so READ \
    from the image. For math, a fraction/limit/integral spanning two rows is ONE expression).

    STEP 1 — UNDERSTAND THE PROBLEM. Read the PROBLEM STATEMENT (typed, printed, or a \
    pasted screenshot/photo; may be Hebrew/another language) and each labelled \
    sub-question. (The labels depend on the subject — e.g. for calculus, Hebrew/RTL \
    headers "ת.ה:" = domain, "נקודות קיצון" = extrema; for other subjects they will be \
    whatever that task asks. Read what is actually there.)

    STEP 2 — WORK IT OUT YOURSELF FIRST, in plain text, BEFORE grading anything: determine \
    the correct answers for THIS task, whatever it needs — for math: domain/exclusions, \
    derivative, critical points and signs, asymptotes, limits; for science: the balanced \
    equation, formula, or concept; for a language: the correct grammar/translation; for an \
    essay or history: the accurate facts and sound reasoning. This step is REQUIRED: it is \
    how you avoid calling wrong work "correct". Show this working.
    Also SANITY-CHECK THE FORM of each answer, not only its value. (For math, e.g.: the \
    derivative of a non-constant rational/polynomial is NOT a constant; a domain exclusion \
    must make a denominator zero or a log/√ argument invalid; an extremum must satisfy \
    f'(x)=0 in the domain. Other subjects have their own form checks — a chemical equation \
    must balance, a translation must be grammatical.) If the FORM is impossible, mark it \
    wrong even before checking exactly.

    STEP 3 — GRADE EACH REGION against YOUR OWN solution. An ANSWER is anything the \
    student wrote as a result — an equation, a step, a value, or a worded conclusion \
    ("אין נקודות קיצון" = no critical points, "אין נקודות אי רציפות" = no \
    discontinuities, a monotonicity/asymptote claim). Judge a worded conclusion by \
    comparing it to what YOU computed (e.g. if f'(x)=0 has a solution in the domain, \
    "no critical points" is WRONG).
    GRADE EXACTLY WHAT IS SHOWN. For math, compare the student's sign, number, and \
    variable to YOUR computed value digit-for-digit (if the image shows "x≠1" but the \
    true exclusion is x=−1, that is WRONG — never assume OCR or the student dropped a \
    minus sign; the most common real mistakes are exactly a wrong sign, root, or \
    off-by-one). For NON-math, compare the exact claim/fact/word/translation they wrote \
    to what is actually correct (a wrong date, a misused word, a false statement, an \
    unbalanced equation is WRONG). Do NOT give benefit of the doubt. Marking wrong work \
    "correct" is the worst failure here; when what you see does not match what you \
    determined, it is "wrong".
    GRADE EACH STEP ON ITS OWN, not on whether the final conclusion happens to work \
    out. An intermediate line — a factorization, a derivative, an expansion, an \
    algebra step — is WRONG whenever it differs from yours, EVEN IF the student's \
    eventual answer still comes out right. Example: "x^3-1=(x-1)(x^2-x+1)" is WRONG \
    (it is (x-1)(x^2+x+1)) even though both quadratics have no real roots and the \
    domain ends up identical — the factorization itself is wrong, so mark it wrong \
    and set "fix":"(x-1)(x^{2}+x+1)".
    If the student lists SEVERAL values/conditions on separate lines (e.g. two
    domain exclusions "x≠1" then "x≠-3", or several critical points), grade EACH
    line on its own — a later line being wrong does not excuse an earlier one, and
    a correct line below does not cover a wrong one above.
    Classify EVERY region index, in order:
    - "correct"   — the value shown EQUALS what you computed, exactly. If you can't read it, can't verify it, or are unsure, do NOT mark correct — use "wrong" or a low conf.
    - "wrong"     — a mistake or false claim. "note": one short sentence (words go HERE). "fix": the corrected line — for MATH, bare LaTeX (NO words, NO leading "=") e.g. "-2(x+2)/(x+1)^{3} = 0" or "x = 3" (\\frac{num}{den}, x^{2}, \\sqrt{...}, · for multiply; no $); for NON-math, the corrected plain word/fact/phrase, e.g. "fix":"1789" or "fix":"their (possessive)" or the balanced formula. ALWAYS include "fix" whenever a concrete correction exists — INCLUDING worded claims: if they wrote "no critical points" but there is one at x=-2, set "fix":"x = -2"; if they wrote "x≠-3" but the exclusion is x=-1, set "fix":"x = -1". Omit "fix" ONLY when the correction is purely conceptual with nothing concrete to write. "conf": 0.0–1.0.
    - "unfinished"— it LITERALLY ends with '=' or an operator with nothing after it.
    - "skip"      — ONLY a header/label/stray mark. NEVER "skip" real work or a real answer just because its OCR looks garbled — read the image and grade it.
    Return one entry for EVERY region index, in order — never drop a line.

    OUTPUT: write your STEP 2 working as plain text first, THEN the verdicts as a JSON \
    object fenced in a ```json code block:
    ```json
    {"regions":[{"i":0,"status":"correct"},{"i":1,"status":"wrong","note":"...","fix":"...","conf":0.9},{"i":2,"status":"unfinished"}]}
    ```
    """

    private static func checkInstruction(lines: [OCRLine], pageNumber: Int, problem: String) -> String {
        let numbered = lines.enumerated()
            .map { "\($0.offset): \($0.element.text)" }
            .joined(separator: "\n")
        // The pasted question's own text (OCR), so the model knows the exact task
        // and its required sub-parts — grade each region against THAT.
        let problemBlock = problem.isEmpty ? "" : """

        THE PROBLEM (from the pasted question on the page — grade every region \
        against this task and its sub-parts; OCR may be rough/Hebrew, the image is \
        authoritative):
        \(problem)
        """
        return """
        Grade ONLY the image labeled "Page \(pageNumber) image:" — other page images \
        are background context.\(problemBlock)
        Here are the \(lines.count) student regions on it (rough OCR, read the image \
        for the real content):
        \(numbered)
        Return a status for EVERY region index 0…\(lines.count - 1).
        Write every "note" in \(SystemPrompt.languageTarget).
        """
    }

    private static func parseVerdicts(_ raw: String) -> [Verdict] {
        // The model now reasons first (Step 2) and fences the verdicts in a
        // ```json block; isolate that so the LaTeX braces in its working don't
        // confuse the brace scan.
        var json = raw
        if let fence = raw.range(of: "```json", options: .caseInsensitive),
           let close = raw.range(of: "```", range: fence.upperBound..<raw.endIndex) {
            json = String(raw[fence.upperBound..<close.lowerBound])
        }
        // Preferred path: parse the JSON object holding "regions".
        if let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"),
           let data = String(json[start...end]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = (obj["regions"] ?? obj["items"] ?? obj["lines"]) as? [[String: Any]] {
            let verdicts = arr.compactMap(verdict(from:))
            if !verdicts.isEmpty { return verdicts }
        }
        // Fallback for an unfenced response.
        let raw = json
        // Fallback: a truncated/lightly-malformed response — recover each complete
        // {...} object on its own so we still place the regions we did get.
        return Self.objectMatcher
            .matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            .compactMap { m -> Verdict? in
                guard let r = Range(m.range, in: raw),
                      let data = String(raw[r]).data(using: .utf8),
                      let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return verdict(from: d)
            }
    }

    private static let objectMatcher = try! NSRegularExpression(pattern: "\\{[^{}]*\\}")

    /// Builds a Verdict from one region object. Accepts `i` as number or string.
    private static func verdict(from d: [String: Any]) -> Verdict? {
        let index: Int
        if let n = d["i"] as? NSNumber { index = n.intValue }
        else if let s = d["i"] as? String, let i = Int(s) { index = i }
        else { return nil }
        // Never fabricate a ✓ from a missing verdict: only an explicit "correct"
        // (or ok:true) is correct; an omitted status becomes "skip" (no glyph).
        let status: String
        if let s = d["status"] as? String { status = s.lowercased() }
        else if let ok = d["ok"] as? Bool { status = ok ? "correct" : "wrong" }
        else { status = "skip" }
        return Verdict(
            line: index,
            ok: status == "correct",
            unfinished: status == "unfinished",
            ignore: status == "skip",
            note: d["note"] as? String ?? "",
            fix: d["fix"] as? String,
            label: d["label"] as? String ?? "",
            confidence: (d["conf"] as? Double) ?? 1.0
        )
    }
}

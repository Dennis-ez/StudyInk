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
struct GhostSuggestion {
    var pageIndex: Int
    /// Page-space anchor. For an inline completion it's the MIDDLE of the line
    /// (so a tall fraction straddles it); for a new line below it's the top-left.
    var anchor: CGPoint
    var text: String
    /// One short sentence: WHY this is the next step (revealed on the "?" tap).
    var why: String?
    /// True when completing the current line (after '='), false for a new line.
    var inline: Bool = false
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
        let lines = Self.mergeRows(allOCR.filter { !inMedia($0) })
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

    /// Streams glyphs top-down (120ms each): ✓ on every correct region, a
    /// correction on every wrong one. Anchored to the region's own OCR rect, and
    /// the model decides completeness (so OCR dropping the "3" in "lim…=3" can't
    /// suppress a valid correction).
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
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    // MARK: - Ghost next-step

    func dismissGhost() {
        withAnimation(.easeOut(duration: 0.2)) { ghost = nil }
    }

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
        let target: OCRLine? = openLine ?? ((auto && !lowestShortIncomplete) ? nil : lowest)
        guard let last = target,
              !last.text.trimmingCharacters(in: .whitespaces).isEmpty,
              last.text != lastGhostSourceLine else { return }
        let isOpen = openLine != nil || lowestShortIncomplete

        if !auto { isSuggesting = true }
        defer { if !auto { isSuggesting = false } }
        do {
            let context = await NoteContextBuilder.build(note: note, currentPageIndex: pageIndex, darkMode: darkMode)
            var blocks = context.blocks
            // Anchor the model to the student's ACTUAL last line so it continues
            // from there (not back at the top of the page).
            let lastText = last.text.trimmingCharacters(in: .whitespaces)
            let instruction = isOpen
                ? "The student's LAST handwritten line reads roughly: \"\(lastText)\" and is UNFINISHED. Continue from THERE — give the single next line that directly follows it: do the algebra and write the COMPLETE result that belongs after the '=' (e.g. if they wrote '2x =' give the value of x; if a derivative, the fully simplified form combining ALL factors). Never restate the left side, never jump back to an earlier step, never a partial fragment. LaTeX: fractions \\frac{num}{den} (NOT a/b), x^{2}, x_{0}, \\sqrt{...}, · for multiply. Output ONLY that expression — no $ delimiters, no words. If you genuinely can't, output nothing."
                : "The student's LAST handwritten line reads roughly: \"\(lastText)\". Give the SINGLE most useful next line toward solving the problem — continue from there, do NOT jump back to an earlier step. LaTeX (\\frac{num}{den}, x^{2}, \\sqrt{...}, · for multiply). Output ONLY the expression — no $ delimiters, no words. ALWAYS give your best next step; output nothing ONLY if the page is blank or truly unreadable."
            blocks.append(.text(instruction))
            blocks.append(.text("Write the \"why\" sentence in \(SystemPrompt.languageTarget)."))
            let raw = try await AIService.send(system: Self.ghostSystem, messages: [.user(blocks)], maxTokens: 600)
            let (nextRaw, why) = Self.parseGhost(raw)
            let text = Self.cleanGhost(nextRaw)
            guard !text.isEmpty, text.count < 140 else { return }
            // Drop a suggestion that just echoes the line it's completing.
            let a = Self.mathKey(text), b = Self.mathKey(last.text)
            guard a.count >= 1, a != b, !b.contains(a) else { return }
            lastGhostSourceLine = last.text
            let anchor = isOpen
                ? CGPoint(x: last.rect.maxX + 14, y: last.rect.midY)                    // inline, centred on the line
                : CGPoint(x: last.rect.minX, y: last.rect.maxY + last.rect.height * 0.7) // new line below, clearing a fraction
            withAnimation(.easeIn(duration: 0.25)) {
                ghost = GhostSuggestion(pageIndex: pageIndex, anchor: anchor, text: text, why: why, inline: isOpen)
            }
        } catch { }
    }

    private static let ghostSystem = "You are a calculus/algebra tutor giving a student the next line of their solution. READ their handwriting from the attached page image (OCR misreads lim/∫/fractions — trust the image). FIRST read any problem statement on the page — typed, printed, or a pasted screenshot/photo, possibly in another language (e.g. Hebrew) — that defines the function/task. Then actually DO THE MATH: work out the genuine next step toward solving THAT problem (e.g. fully simplify a derivative, factor, take a limit), and give the worked-out result — never just re-copy what the student already wrote, never a half-expression. Output a JSON object: {\"next\":\"<that one line as LaTeX: \\\\frac{num}{den}, x^{2}, \\\\sqrt{...}, · for multiply; no $ delimiters, no words>\",\"why\":\"<ONE short sentence, in the student's language, explaining WHY this is the next step (which rule/operation and on what)>\"}. If you can't produce a correct, useful line, output {}."

    /// Pulls the {next, why} out of the ghost response (tolerates fences / prose /
    /// truncation). Critically, it NEVER falls back to dumping the raw string: a
    /// response that looks like JSON but won't parse returns empty, so we never
    /// write `{"next":"…` braces onto the page as ink.
    private static func parseGhost(_ raw: String) -> (String, String?) {
        var src = raw
        if let f = raw.range(of: "```json", options: .caseInsensitive),
           let c = raw.range(of: "```", range: f.upperBound..<raw.endIndex) {
            src = String(raw[f.upperBound..<c.lowerBound])
        } else if let f = raw.range(of: "```"),
                  let c = raw.range(of: "```", range: f.upperBound..<raw.endIndex) {
            src = String(raw[f.upperBound..<c.lowerBound])
        }
        // 1) Strict JSON object.
        if let s = src.firstIndex(of: "{"), let e = src.lastIndex(of: "}"),
           let data = String(src[s...e]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let next = obj["next"] as? String {
            let why = (obj["why"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (next, (why?.isEmpty == false) ? why : nil)
        }
        // 2) Regex-extract the string values — survives truncation (a cut-off
        //    response with no closing brace) and stray escaping.
        let nextVal = firstCapture(#""next"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: src).map(unescapeJSON)
        let whyVal = firstCapture(#""why"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: src).map(unescapeJSON)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let nextVal, !nextVal.isEmpty {
            return (nextVal, (whyVal?.isEmpty == false) ? whyVal : nil)
        }
        // 3) It tried to be JSON but we couldn't recover a value → render nothing
        //    rather than spilling braces/keys onto the page.
        if src.contains("\"next\"") || src.contains("\"why\"") || src.contains("{") {
            return ("", nil)
        }
        // 4) Genuinely plain text — treat the whole thing as the next line.
        return (raw, nil)
    }

    /// First capture group of `pattern` in `s`, or nil.
    private static func firstCapture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// Minimal JSON-string unescape: `\"`→`"`, `\\`→`\` (keeping LaTeX commands
    /// like `\frac` intact). Newlines collapse to spaces.
    private static func unescapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\/", with: "/")
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
    You are a meticulous math/study tutor checking a student's handwritten work. The \
    page IMAGE is attached, with a NUMBERED list of regions (one per handwriting line) \
    and rough OCR (OFTEN WRONG on notation — READ the handwriting from the image: \
    limits "lim x→0 sinx/x", integrals "∫x dx", fractions/subscripts/exponents often \
    span two rows; treat a stack as ONE equation).

    STEP 1 — UNDERSTAND THE PROBLEM. Read the PROBLEM STATEMENT (typed, printed, or a \
    pasted screenshot/photo; may be Hebrew/another language; e.g. "y = ((x+2)/(x+1))²") \
    and each labelled sub-question (headers, often Hebrew/RTL: "ת.ה:" = domain, \
    "תחומי עליה/ירידה:" = increase/decrease, "נקודות קיצון" = extrema, asymptotes…).

    STEP 2 — SOLVE IT YOURSELF FIRST, in plain text, BEFORE grading anything: work out \
    the correct answers for THIS function — domain/exclusions, f'(x), where f'(x)=0 \
    (critical points) and the sign of f', asymptotes, limits — whatever the \
    sub-questions need. This step is REQUIRED: it is how you avoid calling wrong work \
    "correct". Show this working.
    Also SANITY-CHECK THE FORM of each answer, not only its value: the derivative of a \
    non-constant rational/polynomial function is NOT a constant (so "f'(x)=6" for \
    f=((x+2)/(x+1))² is wrong on its face); a domain exclusion must make a denominator \
    zero (or a log/√ argument invalid); an extremum must satisfy f'(x)=0 and lie in the \
    domain. If the FORM is impossible, mark it wrong even before computing exactly.

    STEP 3 — GRADE EACH REGION against YOUR OWN solution. An ANSWER is anything the \
    student wrote as a result — an equation, a step, a value, or a worded conclusion \
    ("אין נקודות קיצון" = no critical points, "אין נקודות אי רציפות" = no \
    discontinuities, a monotonicity/asymptote claim). Judge a worded conclusion by \
    comparing it to what YOU computed (e.g. if f'(x)=0 has a solution in the domain, \
    "no critical points" is WRONG).
    GRADE THE EXACT VALUE SHOWN. Compare the student's sign, number, and variable to \
    YOUR computed value digit-for-digit. Do NOT give benefit of the doubt: if the \
    image shows "x≠1" but the true exclusion is x=−1, that is WRONG — never assume OCR \
    or the student dropped a minus sign or swapped a value. The most common real \
    mistakes are exactly these — a wrong sign, a wrong root, an off-by-one. Marking \
    wrong work "correct" is the worst failure here; when the value you see does not \
    equal the value you computed, it is "wrong".
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
    - "wrong"     — a mistake or false claim. "note": one short sentence (words go HERE). "fix": the corrected line as bare LaTeX math — NO words, NO leading "=" — e.g. "-2(x+2)/(x+1)^{3} = 0" or "x = 3" (\\frac{num}{den}, x^{2}, \\sqrt{...}, · for multiply; no $). ALWAYS include "fix" whenever a concrete corrected value or formula exists — INCLUDING when the student's claim was worded: if they wrote "no critical points" but there is one at x=-2, set "fix":"x = -2"; if they wrote "x≠-3" but the exclusion is x=-1, set "fix":"x = -1". Omit "fix" ONLY when the correction is purely conceptual with no value/formula to write. "conf": 0.0–1.0.
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

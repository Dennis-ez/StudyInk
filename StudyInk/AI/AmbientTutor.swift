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
    /// Page-space top-left where the ghost text begins.
    var anchor: CGPoint
    var text: String
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
    /// Transient banner shown after a check (an error, or "nothing to check").
    @Published var notice: String?
    /// The next-step ghost suggestion, if any.
    @Published var ghost: GhostSuggestion?
    /// OCR line rects from the most recent check — used so AI ink (fix-it) lands
    /// in a clear gap instead of over the student's existing work.
    private(set) var lastLineRects: [CGRect] = []
    /// Guards the idle auto-trigger so we only suggest once per writing burst.
    private var lastGhostSourceLine: String?
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
        let lines = Self.mergeRows(await NoteContextBuilder.ocrLines(for: page))
        lastLineRects = lines.map(\.rect)
        guard !lines.isEmpty else {
            showNotice(String(localized: "ambient.notice.empty"))
            return
        }

        do {
            let context = await NoteContextBuilder.build(
                note: note, currentPageIndex: pageIndex, darkMode: darkMode
            )
            var blocks = context.blocks
            blocks.append(.text(Self.checkInstruction(lines: lines, pageNumber: pageIndex + 1)))
            // Per-item y/anchor/note/fix is verbose; give it room so a multi-
            // equation page doesn't truncate mid-array.
            let raw = try await AIService.send(system: Self.checkSystem, messages: [.user(blocks)], maxTokens: 3000)
            let verdicts = Self.parseVerdicts(raw)
            guard !verdicts.isEmpty else {
                showNotice(String(localized: "ambient.notice.unreadable"))
                return
            }
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
        for v in verdicts.sorted(by: { $0.line < $1.line }) {
            guard lines.indices.contains(v.line) else { continue }
            // The model marks a still-unfinished region as such — no glyph for it.
            if v.unfinished { continue }
            let rect = lines[v.line].rect
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

    /// Predict the single next line the student is about to write and show it as
    /// ghost text below the last line. Gated to Helpful sensitivity.
    func suggestNext(note: Note, pageIndex: Int, darkMode: Bool) async {
        guard ghost == nil else { return }
        let pages = note.sortedPages
        guard pages.indices.contains(pageIndex) else { return }
        let page = pages[pageIndex]
        let lines = Self.mergeRows(await NoteContextBuilder.ocrLines(for: page))
        // An UNFINISHED line (ends with =, an operator, →) is the real target:
        // the student is waiting to fill in its right-hand side, so complete it
        // inline — even if some later scribble sits lower on the page. Only when
        // nothing is open do we predict a brand-new line below the lowest work.
        let openLine = lines
            .filter { Self.isOpenLine($0.text) }
            .max(by: { $0.rect.maxY < $1.rect.maxY })
        let lowest = lines.max(by: { $0.rect.maxY < $1.rect.maxY })
        guard let last = openLine ?? lowest,
              !last.text.trimmingCharacters(in: .whitespaces).isEmpty,
              last.text != lastGhostSourceLine else { return }
        let isOpen = openLine != nil

        do {
            let context = await NoteContextBuilder.build(note: note, currentPageIndex: pageIndex, darkMode: darkMode)
            var blocks = context.blocks
            let instruction = isOpen
                ? "The student's current line ends with an operator and is UNFINISHED — read the page and predict ONLY what comes right after it to complete THIS line (e.g. the value after '='). Reply with ONLY that, plain math, no words, no label. If unsure, reply with nothing."
                : "Predict the SINGLE next line this student is about to write to continue. Reply with ONLY that expression in plain math — no words, no label. If there's no clear next step, reply with nothing."
            blocks.append(.text(instruction))
            let raw = try await AIService.send(system: Self.ghostSystem, messages: [.user(blocks)], maxTokens: 80)
            let text = Self.cleanGhost(raw)
            guard !text.isEmpty, text.count < 60 else { return }
            lastGhostSourceLine = last.text
            let anchor = isOpen
                ? CGPoint(x: last.rect.maxX + 14, y: last.rect.minY)   // inline, after the operator
                : CGPoint(x: last.rect.minX, y: last.rect.maxY + 12)   // new line below
            withAnimation(.easeIn(duration: 0.25)) {
                ghost = GhostSuggestion(pageIndex: pageIndex, anchor: anchor, text: text)
            }
        } catch { }
    }

    private static let ghostSystem = "You quietly predict the next line a student is about to write to continue their math/study work. READ their handwriting from the attached page image (the OCR text often misreads notation like lim/∫/fractions — trust the image). Output ONLY that single next line as plain math text — no explanation, no label, no markdown. If unsure, output nothing."

    private static func cleanGhost(_ raw: String) -> String {
        guard let first = raw.split(separator: "\n").first else { return "" }
        return String(first).trimmingCharacters(in: CharacterSet(charactersIn: " `'\"*"))
    }

    /// True when a line is unfinished — it ends with `=` or an operator (so its
    /// right-hand side is still to come). OCR misreads notation, but trailing
    /// `=`/operators survive recognition well enough to drive completion.
    static func isOpenLine(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return "=+-−×÷*/·→≤≥<>".contains(last)
    }

    /// Collapses Vision's per-fragment observations into one entry per visual
    /// row: fragments whose vertical spans overlap belong to the same equation
    /// (e.g. "∫ x dx" + "="), so they're concatenated left-to-right and their
    /// rects unioned. Returns rows ordered top-to-bottom. Stacked notation (a
    /// lim's "x→0" under "lim") stays on its own row — little vertical overlap.
    static func mergeRows(_ lines: [OCRLine]) -> [OCRLine] {
        let sorted = lines.sorted { $0.rect.minY < $1.rect.minY }
        var rows: [OCRLine] = []
        for line in sorted {
            guard let last = rows.last else { rows.append(line); continue }
            let overlap = min(last.rect.maxY, line.rect.maxY) - max(last.rect.minY, line.rect.minY)
            if overlap > 0.4 * min(last.rect.height, line.rect.height) {
                let leftFirst = last.rect.minX <= line.rect.minX
                rows[rows.count - 1] = OCRLine(
                    text: leftFirst ? "\(last.text) \(line.text)" : "\(line.text) \(last.text)",
                    rect: last.rect.union(line.rect),
                    confidence: min(last.confidence, line.confidence)
                )
            } else {
                rows.append(line)
            }
        }
        return rows
    }

    // MARK: - AI plumbing

    /// One region's verdict, keyed to the OCR region index `i`. `unfinished`
    /// means the region has no answer yet (model's call, not OCR's) → no glyph.
    private struct Verdict { var line: Int; var ok: Bool; var unfinished: Bool; var note: String; var fix: String?; var label: String; var confidence: Double }

    private static let checkSystem = """
    You are a meticulous math/study tutor. The page IMAGE is attached, and you are \
    given a NUMBERED list of regions — one per line of the student's handwriting — \
    with rough OCR text (often WRONG on notation, so READ the handwriting from the \
    image: limits "lim x→0 sinx/x", integrals "∫x dx", fractions, subscripts, \
    exponents — these often span two rows, treat the stack as one equation). \
    For EVERY region index, look at that line in the image and classify it:
    - "correct"   — the math is right
    - "wrong"     — there is a mistake (add "note": one short sentence, and "fix": the full corrected line in plain math, no LaTeX, and "conf": 0.0–1.0)
    - "unfinished"— it ends with '=' or an operator with nothing after, or is a question with no answer yet
    - "skip"      — the region is not math (a heading, stray mark, label)
    You MUST return one entry for EVERY region index given, in order. Do not skip a \
    region just because its OCR text looks garbled — read the image. \
    Respond with ONLY a JSON object:
    {"regions":[{"i":0,"status":"correct"},{"i":1,"status":"wrong","note":"...","fix":"...","conf":0.9},{"i":2,"status":"unfinished"}]}
    No prose outside the JSON.
    """

    private static func checkInstruction(lines: [OCRLine], pageNumber: Int) -> String {
        let numbered = lines.enumerated()
            .map { "\($0.offset): \($0.element.text)" }
            .joined(separator: "\n")
        return """
        Grade ONLY the image labeled "Page \(pageNumber) image:" — other page images \
        are background context. Here are the \(lines.count) regions on it (rough OCR, \
        read the image for the real content):
        \(numbered)
        Return a status for EVERY region index 0…\(lines.count - 1).
        """
    }

    private static func parseVerdicts(_ raw: String) -> [Verdict] {
        // Preferred path: parse the whole JSON object.
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
           let data = String(raw[start...end]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = (obj["regions"] ?? obj["items"] ?? obj["lines"]) as? [[String: Any]] {
            let verdicts = arr.compactMap(verdict(from:))
            if !verdicts.isEmpty { return verdicts }
        }
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
        let status = (d["status"] as? String ?? (d["ok"] as? Bool == false ? "wrong" : "correct")).lowercased()
        if status == "skip" { return nil }
        return Verdict(
            line: index,
            ok: status == "correct",
            unfinished: status == "unfinished",
            note: d["note"] as? String ?? "",
            fix: d["fix"] as? String,
            label: d["label"] as? String ?? "",
            confidence: (d["conf"] as? Double) ?? 1.0
        )
    }
}

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
        guard !lines.isEmpty else {
            showNotice(String(localized: "ambient.notice.empty"))
            return
        }

        do {
            let context = await NoteContextBuilder.build(
                note: note, currentPageIndex: pageIndex, darkMode: darkMode
            )
            var blocks = context.blocks
            blocks.append(.text(Self.checkInstruction(lines: lines)))
            let raw = try await AIService.send(system: Self.checkSystem, messages: [.user(blocks)])
            let verdicts = Self.parseVerdicts(raw)
            guard !verdicts.isEmpty else {
                showNotice(String(localized: "ambient.notice.unreadable"))
                return
            }
            await stream(verdicts: verdicts, lines: lines, pageSize: page.canvasSize, pageIndex: pageIndex)
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

    /// Streams glyphs top-down (120ms each): ✓ on every correct statement, a
    /// correction on every wrong one. Each verdict is placed by its `y` fraction,
    /// snapped to the nearest matching OCR row when one exists for pixel accuracy.
    private func stream(verdicts: [Verdict], lines: [OCRLine], pageSize: CGSize, pageIndex: Int) async {
        let minConf = sensitivity == .subtle ? 0.90 : 0.0
        for v in verdicts.sorted(by: { $0.y < $1.y }) {
            let (rect, matched) = Self.anchorRect(for: v, lines: lines, pageSize: pageSize)
            // If we snapped to an OCR row that's clearly unfinished (ends with =),
            // it isn't right OR wrong yet — skip it.
            if let matched, Self.isOpenLine(matched.text) { continue }
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

    /// Resolves a verdict's page-space anchor rect. Primary signal is the model's
    /// `y` fraction; we snap to a matching OCR row when one exists (pixel-accurate
    /// and gives fix-it a real line to write under), and synthesize a rect at `y`
    /// when OCR missed the statement entirely (e.g. a stacked limit). Also returns
    /// the matched OCR row, if any, so the caller can skip unfinished lines.
    private static func anchorRect(for v: Verdict, lines: [OCRLine], pageSize: CGSize) -> (CGRect, OCRLine?) {
        let pageY = v.y * pageSize.height
        let key = normalize(v.anchor)

        // 1) Text match: an OCR row whose normalized text shares a prefix with the
        //    anchor (only for keys with real signal), nearest to the model's y.
        if key.count >= 2 {
            let matches = lines.filter { row in
                let t = normalize(row.text)
                guard !t.isEmpty else { return false }
                return t.hasPrefix(key) || key.hasPrefix(t) || t.contains(key)
            }
            if let best = matches.min(by: { abs($0.rect.midY - pageY) < abs($1.rect.midY - pageY) }) {
                return (best.rect, best)
            }
        }

        // 2) No text match — snap to the nearest OCR row if one sits at this height.
        let band = max(pageSize.height * 0.05, 30)
        if let near = lines.min(by: { abs($0.rect.midY - pageY) < abs($1.rect.midY - pageY) }),
           abs(near.rect.midY - pageY) <= band {
            return (near.rect, near)
        }

        // 3) OCR missed it — place by the model's y alone so the glyph still lands
        //    on the right line.
        let heights = lines.map(\.rect.height).sorted()
        let h = heights.isEmpty ? 28 : heights[heights.count / 2]
        let x = lines.map(\.rect.minX).min() ?? pageSize.width * 0.1
        let w = max(pageSize.width * 0.3, 120)
        return (CGRect(x: x, y: pageY - h / 2, width: w, height: h), nil)
    }

    /// Lowercased, alphanumerics only — robust to OCR mangling symbols/spacing.
    private static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
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

    /// A verdict the model returns. Position is anchored by `y` (a fraction of
    /// page height, 0=top … 1=bottom) plus an `anchor` snippet — NOT an OCR line
    /// index — so stacked notation that OCR fragments still lands correctly.
    private struct Verdict { var y: CGFloat; var anchor: String; var ok: Bool; var note: String; var fix: String?; var label: String; var confidence: Double }

    private static let checkSystem = """
    You are an attentive math/study tutor reviewing a student's HANDWRITTEN work. \
    The page IMAGE is attached — READ the handwriting directly from it; recognise \
    limits (lim x→0 sinx/x), integrals (∫x dx), fractions, subscripts and exponents \
    correctly even when they're stacked over two rows. Find every COMPLETED \
    equation/statement on the page and decide if it is mathematically correct. \
    For EACH one, report:
    - "y": its vertical CENTER as a fraction of page height, 0.0 (top) … 1.0 (bottom).
    - "anchor": the first 2–6 characters of the statement as written (e.g. "lim", "∫x", "3x=6").
    - "ok": true if correct, false if wrong.
    - when false also: "label" (e.g. "Almost —"), "note" (one short sentence on the mistake), "fix" (the full corrected line in plain math, no LaTeX), "conf" (0.0–1.0).
    Judge EVERY completed equation — especially limits and integrals; never skip one. \
    OMIT only genuinely UNFINISHED work: a line ending in '=' or an operator with \
    nothing after it, or a bare question with no answer yet. \
    Respond with ONLY a JSON object:
    {"items":[{"y":0.12,"anchor":"1+3","ok":true},{"y":0.55,"anchor":"∫x","ok":false,"label":"Almost —","note":"...","fix":"∫x dx = x²/2 + C","conf":0.9}]}
    No prose outside the JSON.
    """

    private static func checkInstruction(lines: [OCRLine]) -> String {
        // Rough OCR as a hint only — the model reads the image for the real
        // content and reports each statement's vertical position itself.
        let hint = lines.map(\.text).joined(separator: " / ")
        return """
        Check my handwritten work from the page image. (Rough OCR for reference, \
        often wrong on notation: \(hint))
        Return the JSON verdict with a y position and anchor for each statement.
        """
    }

    private static func parseVerdicts(_ raw: String) -> [Verdict] {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { return [] }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = (obj["items"] ?? obj["lines"]) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let yNum = d["y"] as? NSNumber else { return nil }
            let y = min(1, max(0, CGFloat(yNum.doubleValue)))
            return Verdict(
                y: y,
                anchor: (d["anchor"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                ok: d["ok"] as? Bool ?? true,
                note: d["note"] as? String ?? "",
                fix: d["fix"] as? String,
                label: d["label"] as? String ?? "",
                confidence: (d["conf"] as? Double) ?? 1.0
            )
        }
    }
}

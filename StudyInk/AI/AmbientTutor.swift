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

        isChecking = true
        defer { isChecking = false }
        clear(pageIndex: pageIndex)

        let lines = await NoteContextBuilder.ocrLines(for: page)
        guard !lines.isEmpty else { return }

        do {
            let context = await NoteContextBuilder.build(
                note: note, currentPageIndex: pageIndex, darkMode: darkMode
            )
            var blocks = context.blocks
            blocks.append(.text(Self.checkInstruction(lines: lines)))
            let raw = try await AIService.send(system: Self.checkSystem, messages: [.user(blocks)])
            let verdicts = Self.parseVerdicts(raw)
            await stream(verdicts: verdicts, lines: lines, pageIndex: pageIndex)
        } catch {
            Haptics.error()
        }
    }

    /// Streams ✓ marks top-down (120ms/line), then the first correction.
    private func stream(verdicts: [Verdict], lines: [OCRLine], pageIndex: Int) async {
        let minConf = sensitivity == .subtle ? 0.90 : 0.0
        var firstErrorEmitted = false
        for v in verdicts.sorted(by: { $0.line < $1.line }) {
            guard lines.indices.contains(v.line) else { continue }
            let rect = lines[v.line].rect
            if v.ok {
                if sensitivity == .subtle { continue } // Subtle: errors only
                withAnimation(.easeOut(duration: 0.3)) {
                    items.append(MarginItem(pageIndex: pageIndex, anchorRect: rect,
                                            glyph: .correct, tone: .correct,
                                            label: "", body: ""))
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            } else if !firstErrorEmitted, v.confidence >= minConf {
                firstErrorEmitted = true
                withAnimation(.easeOut(duration: 0.3)) {
                    items.append(MarginItem(
                        pageIndex: pageIndex, anchorRect: rect,
                        glyph: .attend, tone: .correction,
                        label: v.label.isEmpty ? "Almost —" : v.label,
                        body: v.note, result: v.fix?.isEmpty == true ? nil : v.fix))
                }
                Haptics.selection()
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
        let lines = await NoteContextBuilder.ocrLines(for: page)
        guard let last = lines.last, !last.text.trimmingCharacters(in: .whitespaces).isEmpty,
              last.text != lastGhostSourceLine else { return }

        do {
            let context = await NoteContextBuilder.build(note: note, currentPageIndex: pageIndex, darkMode: darkMode)
            var blocks = context.blocks
            blocks.append(.text("Predict the SINGLE next line this student is about to write to continue. Reply with ONLY that expression in plain math — no words, no label. If there's no clear next step, reply with nothing."))
            let raw = try await AIService.send(system: Self.ghostSystem, messages: [.user(blocks)], maxTokens: 80)
            let text = Self.cleanGhost(raw)
            guard !text.isEmpty, text.count < 60 else { return }
            lastGhostSourceLine = last.text
            let anchor = CGPoint(x: last.rect.minX, y: last.rect.maxY + 12)
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

    // MARK: - AI plumbing

    private struct Verdict { var line: Int; var ok: Bool; var note: String; var fix: String?; var label: String; var confidence: Double }

    private static let checkSystem = """
    You are an attentive math/study tutor reviewing a student's HANDWRITTEN work, \
    line by line. The page IMAGE is attached — READ the actual handwriting from it. \
    The OCR text you are given is often WRONG for math notation (limits "lim x→0", \
    integrals, fractions, subscripts, exponents) — trust the image, use the line \
    numbers only to anchor your verdicts to positions. For each line decide if it \
    is mathematically correct. Respond with ONLY a JSON object of the form:
    {"lines":[{"i":0,"ok":true},{"i":1,"ok":false,"label":"Almost —","note":"<one short sentence on the mistake>","fix":"<the corrected expression>","conf":0.9}]}
    Keep "note" to one sentence. "fix" is the corrected line in plain math. Omit \
    fields you are unsure of. No prose outside the JSON.
    """

    private static func checkInstruction(lines: [OCRLine]) -> String {
        let numbered = lines.enumerated()
            .map { "\($0.offset): \($0.element.text)" }
            .joined(separator: "\n")
        return """
        Read my handwriting from the page image and check each line. These rough OCR \
        guesses are ONLY for line numbering (they misread notation like lim/∫/fractions):
        \(numbered)
        Return the JSON verdict.
        """
    }

    private static func parseVerdicts(_ raw: String) -> [Verdict] {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { return [] }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["lines"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let i = d["i"] as? Int else { return nil }
            let ok = d["ok"] as? Bool ?? true
            return Verdict(
                line: i, ok: ok,
                note: d["note"] as? String ?? "",
                fix: d["fix"] as? String,
                label: d["label"] as? String ?? "",
                confidence: (d["conf"] as? Double) ?? 1.0
            )
        }
    }
}

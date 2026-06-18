import SwiftUI
import PencilKit

/// Explain This Page + Quiz Me, built on the bubble system.
extension AITutorController {
    /// Sends the full page and drops a summary bubble at the top-right corner,
    /// with highlights across the page's key concepts.
    func explainCurrentPage() async {
        guard let page = currentPage else { return }
        let pageSize = page.canvasSize
        let anchor = CGPoint(x: pageSize.width - 120, y: 80)
        await ask(
            question: String(localized: "ai.explainPage.question"),
            anchor: anchor,
            systemHint: """
            EXPLAIN PAGE MODE: Summarize what this page covers and the key concepts on it.
            Use highlight annotations to mark the most important expressions or definitions across the page (use several annotations).
            """
        )
    }

    // Quiz Me grew out of the bubble system into its own card flow — see
    // QuizController / QuizView.

    /// Asks the model for a simple polyline sketch and inks it onto the live
    /// canvas as real strokes (erasable, lassoable, undoable like handwriting).
    func drawSketch(request: String, on canvas: PKCanvasView?) async {
        guard let page = currentPage, let canvas else { return }
        let pageSize = page.canvasSize
        beginTask(); defer { endTask() }

        do {
            let prompt = """
            SKETCH MODE: Draw "\(request)" as a simple, clean line drawing — like a quick whiteboard sketch.
            Respond with ONLY a JSON object:
            {"strokes": [{"points": [[x, y], [x, y], ...]}, ...]}
            Coordinates live in a 100×100 box, origin top-left. Use 3-25 strokes with 2-60 points each.
            Connect points smoothly; prefer fewer, longer strokes over many tiny ones.
            """
            let raw = try await AIService.send(
                system: SystemPrompt.tutor(subjectContext: note?.subjectContext ?? "calculus1", directAnswer: true),
                messages: [.user(text: prompt)],
                maxTokens: 3000
            )
            guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
                  let data = String(raw[start...end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["strokes"] as? [[String: Any]], !items.isEmpty else {
                errorMessage = String(localized: "ai.sketch.failed")
                return
            }

            // Land the sketch in a box at the center of the current page.
            let side = min(pageSize.width, pageSize.height) * 0.45
            let box = CGRect(
                x: (pageSize.width - side) / 2,
                y: (pageSize.height - side) / 2,
                width: side, height: side
            )
            // Accent blue reads on both light and dark canvases, and marks the
            // ink as the tutor's rather than the student's.
            let ink = PKInk(.pen, color: UIColor(hex: "#0A84FF") ?? .systemBlue)

            var strokes: [PKStroke] = []
            for item in items.prefix(25) {
                guard let pairs = item["points"] as? [[Any]] else { continue }
                let controlPoints = pairs.prefix(60).enumerated().compactMap { index, pair -> PKStrokePoint? in
                    guard pair.count >= 2,
                          let x = (pair[0] as? NSNumber)?.doubleValue,
                          let y = (pair[1] as? NSNumber)?.doubleValue else { return nil }
                    let location = CGPoint(
                        x: box.minX + min(max(x, 0), 100) / 100 * box.width,
                        y: box.minY + min(max(y, 0), 100) / 100 * box.height
                    )
                    return PKStrokePoint(
                        location: location,
                        timeOffset: Double(index) * 0.02,
                        size: CGSize(width: 3.5, height: 3.5),
                        opacity: 1, force: 1,
                        azimuth: 0, altitude: .pi / 2
                    )
                }
                guard controlPoints.count >= 2 else { continue }
                strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: controlPoints, creationDate: Date())))
            }
            guard !strokes.isEmpty else {
                errorMessage = String(localized: "ai.sketch.failed")
                return
            }
            appendInkUndoably(strokes, to: canvas)
            Haptics.tap()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Apple-Notes-Math style "Answer in Ink": works out the answer to a
    /// question in the note and writes it next to that question as handwritten
    /// strokes (hand-style font → real PencilKit ink via InkWriter).
    func answerInInk(request: String, on canvas: PKCanvasView?, colorHex: String, penWidth: Double) async {
        guard let note, let page = currentPage, let canvas else { return }
        let pageSize = page.canvasSize
        beginTask(); defer { endTask() }

        do {
            let context = await NoteContextBuilder.build(note: note, currentPageIndex: currentPageIndex, darkMode: isDarkMode)
            var blocks = context.blocks
            blocks.append(.text("""
            INK ANSWER MODE: The student asked: "\(request)".
            FIRST read any problem statement on the page (typed, printed, or a pasted screenshot/photo — possibly Hebrew/another language) that defines the function/task, so you answer the RIGHT question in context.
            Solve/answer it from the note's content (do the math properly; show the result, not the working, unless asked).
            Respond with ONLY a JSON object:
            {"answer": "<the answer as it should be written on the page, as LaTeX: fractions \\\\frac{num}{den} (NOT a/b), exponents x^{2}, subscripts x_{0}, roots \\\\sqrt{...}, · for multiply; no $ delimiters; \\n between lines, at most 4 lines>",
             "anchor": "<the exact text of the question as it appears in the note OCR, copied verbatim, or null if unsure>"}
            """))

            let raw = try await AIService.send(
                system: SystemPrompt.tutor(subjectContext: note.subjectContext ?? "calculus1", directAnswer: true),
                messages: [.user(blocks)],
                maxTokens: 800
            )
            guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
                  let data = String(raw[start...end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answer = object["answer"] as? String, !answer.isEmpty else {
                errorMessage = String(localized: "ai.draw.failed")
                return
            }

            // Anchor the ink next to the question it answers.
            let lines = await NoteContextBuilder.ocrLines(for: page)
            var anchorRect: CGRect?
            if let anchor = object["anchor"] as? String, !anchor.isEmpty {
                var probe = AIAnnotationModel(kind: .highlight, matchString: anchor, colorToken: "aiHighlightBlue")
                probe = AIResponseParser.resolve(annotations: [probe], against: lines).first ?? probe
                anchorRect = probe.rect
            }

            // Match the handwriting size to the question's line height.
            let fontSize = max(16, min(34, (anchorRect?.height ?? 24) * 0.95))
            let textWidth = InkWriter.width(of: answer, fontSize: fontSize)
            let margin: CGFloat = 24
            var topLeft: CGPoint
            if let rect = anchorRect {
                if rect.maxX + 16 + textWidth <= pageSize.width - margin {
                    // Beside the question.
                    topLeft = CGPoint(x: rect.maxX + 16, y: rect.midY - fontSize * 0.7)
                } else {
                    // No room to the right — directly underneath it.
                    topLeft = CGPoint(x: max(margin, rect.minX), y: rect.maxY + 8)
                }
            } else if let lastLine = lines.max(by: { $0.rect.maxY < $1.rect.maxY }) {
                topLeft = CGPoint(x: max(margin, lastLine.rect.minX), y: lastLine.rect.maxY + 16)
            } else {
                topLeft = CGPoint(x: margin * 2, y: pageSize.height * 0.4)
            }
            // Keep the whole block on the page.
            topLeft.x = min(topLeft.x, max(margin, pageSize.width - margin - textWidth))
            topLeft.x = max(topLeft.x, margin)
            topLeft.y = max(margin, min(topLeft.y, pageSize.height - margin - InkWriter.lineHeight(fontSize: fontSize) * 4))

            // Adapt the colour the same way the pen does (iOS 26 renders ink
            // colours literally, so the AI ink must already be the DISPLAY
            // colour or it renders faint/wrong on the pinned-light canvas).
            let base = InkColorAdapter.displayColor(UIColor(hex: colorHex) ?? .label, darkMode: isDarkMode)
            let ink = PKInk(.pen, color: base)
            // InkWriter traces the glyph CONTOUR, so the stroke must be ~the
            // glyph's stem width or letters render hollow/outlined. Scale it to
            // the font size for a solid, filled-in handwritten look.
            let strokes = InkWriter.strokes(
                for: answer,
                topLeft: topLeft,
                fontSize: fontSize,
                ink: ink,
                strokeWidth: max(2.4, fontSize * 0.135)
            )
            guard !strokes.isEmpty else {
                errorMessage = String(localized: "ai.draw.failed")
                return
            }
            appendInkUndoably(strokes, to: canvas)
            Haptics.tap()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension AITutorController {
    /// Writes text as handwritten ink at an EXPLICIT page-space location. Used
    /// by the ambient tutor, where the caller already knows exactly where the
    /// ink goes (the glyph's line rect / the ghost's anchor) — so there's no AI
    /// round-trip and no OCR anchor-matching to land it in the wrong place.
    func writeInk(text: String, at pagePoint: CGPoint, fontSize: CGFloat = 22, colorHex: String, avoid: [CGRect] = [], center: Bool = false, on canvas: PKCanvasView?) {
        guard let canvas, let page = currentPage else { return }
        let pageSize = page.canvasSize
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        let textWidth = InkWriter.width(of: cleaned, fontSize: fontSize)
        let lineH = InkWriter.lineHeight(fontSize: fontSize)
        let blockH = lineH * CGFloat(cleaned.components(separatedBy: "\n").count)
        let margin: CGFloat = 24
        var topLeft = pagePoint
        // Inline placement (after a '='): treat pagePoint.y as the line's MIDDLE
        // and lift a tall result (a fraction) so it straddles the line instead of
        // hanging below into the next one.
        if center {
            let m = InkWriter.firstLineMetrics(of: cleaned, fontSize: fontSize)
            topLeft.y = pagePoint.y - (m.ascent + m.descent) / 2
        }
        // Keep the whole block on the page.
        topLeft.x = min(topLeft.x, max(margin, pageSize.width - margin - textWidth))
        topLeft.x = max(topLeft.x, margin)
        topLeft.y = max(margin, min(topLeft.y, pageSize.height - margin - blockH))

        // Don't write over existing ink: if the block would overlap an occupied
        // line, drop it just below that line. (Column-aware — `intersects` only
        // trips when the x-ranges overlap too, so other columns don't push it.)
        var guardCount = 0
        while guardCount < 16 {
            let block = CGRect(x: topLeft.x, y: topLeft.y, width: max(textWidth, 8), height: blockH)
            guard let hit = avoid.first(where: { $0.intersects(block) }) else { break }
            let next = hit.maxY + 6
            if next + blockH > pageSize.height - margin { break } // no room; leave as is
            topLeft.y = next
            guardCount += 1
        }

        // Adapt the colour the way the pen does (iOS 26 renders ink colours
        // literally on the pinned-light canvas), and trace with a stem-width
        // stroke so the glyphs read solid rather than hollow outlines.
        let base = InkColorAdapter.displayColor(UIColor(hex: colorHex) ?? .label, darkMode: isDarkMode)
        let ink = PKInk(.pen, color: base)
        let strokes = InkWriter.strokes(
            for: cleaned,
            topLeft: topLeft,
            fontSize: fontSize,
            ink: ink,
            strokeWidth: max(2.4, fontSize * 0.135)   // stem-width so glyphs fill solid, not hollow
        )
        guard !strokes.isEmpty else { return }
        appendInkUndoably(strokes, to: canvas)
        Haptics.tap()
    }

    /// Appends AI strokes to the canvas as a single undoable (and redoable) edit,
    /// so the undo/redo buttons remove/restore the AI's writing like any stroke.
    func appendInkUndoably(_ strokes: [PKStroke], to canvas: PKCanvasView) {
        let before = canvas.drawing
        registerInkUndo(restoring: before, on: canvas)
        canvas.drawing = before.appending(PKDrawing(strokes: strokes))
    }

    /// Registers an undo that restores `drawing`; performing it re-registers the
    /// inverse, so the manager's redo brings the AI ink back.
    private func registerInkUndo(restoring drawing: PKDrawing, on canvas: PKCanvasView) {
        canvas.undoManager?.registerUndo(withTarget: canvas) { [weak self] target in
            let current = target.drawing
            self?.registerInkUndo(restoring: current, on: target)
            target.drawing = drawing
        }
    }
}

/// Subject context selector (Calculus 1 / Discrete Math 1 / custom) for the note.
struct SubjectContextMenu: View {
    @ObservedObject var note: Note
    @State private var showCustomAlert = false
    @State private var customText = ""

    var body: some View {
        Menu {
            Picker("ai.subject", selection: subjectBinding) {
                Text("ai.subject.calculus1").tag("calculus1")
                Text("ai.subject.discrete1").tag("discrete1")
            }
            Button {
                customText = note.subjectContext.flatMap { ["calculus1", "discrete1"].contains($0) ? nil : $0 } ?? ""
                showCustomAlert = true
            } label: {
                Label("ai.subject.custom", systemImage: "pencil")
            }
        } label: {
            // Inside the overflow menu a bare icon rendered as a nameless row.
            Label("ai.subject", systemImage: "books.vertical")
        }
        .accessibilityLabel(Text("ai.subject"))
        .alert(Text("ai.subject.custom"), isPresented: $showCustomAlert) {
            TextField("ai.subject.customPlaceholder", text: $customText)
            Button("action.cancel", role: .cancel) {}
            Button("action.done") {
                let trimmed = customText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    note.subjectContext = trimmed
                    PersistenceController.shared.save()
                }
            }
        }
    }

    private var subjectBinding: Binding<String> {
        Binding(
            get: { note.subjectContext ?? "calculus1" },
            set: { note.subjectContext = $0; PersistenceController.shared.save() }
        )
    }
}

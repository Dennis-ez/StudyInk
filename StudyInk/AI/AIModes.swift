import SwiftUI
import PencilKit

/// Explain This Page + Quiz Me, built on the bubble system.
extension AITutorController {
    /// Sends the full page and drops a summary bubble at the top-right corner,
    /// with highlights across the page's key concepts.
    func explainCurrentPage() async {
        guard let page = currentPage else { return }
        let pageSize = PageSize.from(id: page.pageSizeID).size
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
        let pageSize = PageSize.from(id: page.pageSizeID).size

        do {
            let prompt = """
            SKETCH MODE: Draw "\(request)" as a simple, clean line drawing — like a quick whiteboard sketch.
            Respond with ONLY a JSON object:
            {"strokes": [{"points": [[x, y], [x, y], ...]}, ...]}
            Coordinates live in a 100×100 box, origin top-left. Use 3-25 strokes with 2-60 points each.
            Connect points smoothly; prefer fewer, longer strokes over many tiny ones.
            """
            let raw = try await AIService.send(
                system: SystemPrompt.tutor(subjectContext: note?.subjectContext ?? "calculus1"),
                messages: [.user(text: prompt)],
                maxTokens: 3000
            )
            guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
                  let data = String(raw[start...end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["strokes"] as? [[String: Any]], !items.isEmpty else {
                errorMessage = String(localized: "ai.draw.failed")
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
                errorMessage = String(localized: "ai.draw.failed")
                return
            }
            canvas.drawing = canvas.drawing.appending(PKDrawing(strokes: strokes))
            Haptics.tap()
        } catch {
            errorMessage = error.localizedDescription
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
            Image(systemName: "books.vertical")
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

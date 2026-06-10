import SwiftUI

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

    /// Generates 3–5 questions from the note and stacks them as bubble cards on
    /// the current page. The student answers inside each bubble via Ask More;
    /// Claude grades inline with annotations pointing back into the note.
    func startQuiz() async {
        guard let note, let page = currentPage else { return }
        let pageSize = PageSize.from(id: page.pageSizeID).size

        do {
            let context = await NoteContextBuilder.build(note: note, currentPageIndex: currentPageIndex, darkMode: isDarkMode)
            var blocks = context.blocks
            blocks.append(.text("""
            QUIZ MODE: Generate 3-5 quiz questions testing understanding of this note's content, in the language the note is written in.
            Respond with ONLY a JSON object:
            {"questions": [{"question": "<question text, LaTeX allowed>", "match_string": "<exact related string from the note OCR, or null>"}]}
            """))

            let raw = try await ClaudeService.send(
                system: SystemPrompt.tutor(subjectContext: note.subjectContext ?? "calculus1"),
                messages: [.init(role: "user", content: blocks)],
                maxTokens: 1200
            )
            guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
                  let data = String(raw[start...end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let questions = object["questions"] as? [[String: Any]], !questions.isEmpty else {
                errorMessage = String(localized: "ai.quiz.failed")
                return
            }

            let lines = await NoteContextBuilder.ocrLines(for: page)
            for (index, item) in questions.prefix(5).enumerated() {
                guard let questionText = item["question"] as? String else { continue }

                // Anchor at the related note content when it resolves; cascade otherwise.
                var anchor = CGPoint(x: pageSize.width - 180, y: 90 + Double(index) * 60)
                if let match = item["match_string"] as? String {
                    var probe = AIAnnotationModel(kind: .highlight, matchString: match, colorToken: "aiHighlightBlue")
                    probe = AIResponseParser.resolve(annotations: [probe], against: lines).first ?? probe
                    if let rect = probe.rect { anchor = CGPoint(x: rect.midX, y: rect.midY) }
                }

                var bubble = AIBubbleModel(
                    pageIndex: currentPageIndex,
                    anchorX: anchor.x, anchorY: anchor.y,
                    x: Double(pageSize.width) - 360,
                    y: 70 + Double(index) * 130
                )
                bubble.tone = .explanation
                bubble.thread = [AIExchange(question: nil, answer: String(localized: "ai.quiz.prefix \(index + 1)") + " " + questionText)]
                bubble.chips = []
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(Double(index) * 0.08)) {
                    bubbles.append(bubble)
                }
            }
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

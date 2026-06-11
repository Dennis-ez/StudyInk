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

    // Quiz Me grew out of the bubble system into its own card flow — see
    // QuizController / QuizView.
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

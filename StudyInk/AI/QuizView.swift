import SwiftUI

struct QuizQuestion: Identifiable {
    let id = UUID()
    let question: String
    let answer: String
}

/// Drives a quiz session: generates question+answer pairs from the note, then
/// walks through them card by card with self-grading and a final score.
@MainActor
final class QuizController: ObservableObject {
    @Published var isPresented = false
    @Published var isLoading = false
    @Published var questions: [QuizQuestion] = []
    @Published var index = 0
    @Published var revealed = false
    @Published var correctCount = 0
    @Published var errorMessage: String?

    private var lastRequest: (note: Note, pageIndex: Int, darkMode: Bool)?

    var isFinished: Bool { !questions.isEmpty && index >= questions.count }
    var current: QuizQuestion? { questions.indices.contains(index) ? questions[index] : nil }

    func start(note: Note, pageIndex: Int, darkMode: Bool) async {
        lastRequest = (note, pageIndex, darkMode)
        isPresented = true
        isLoading = true
        errorMessage = nil
        questions = []
        index = 0
        revealed = false
        correctCount = 0

        do {
            let context = await NoteContextBuilder.build(note: note, currentPageIndex: pageIndex, darkMode: darkMode)
            var blocks = context.blocks
            blocks.append(.text("""
            QUIZ MODE: Generate 4-6 quiz questions testing understanding of this note's content, in the language the note is written in.
            Each question needs a model answer (concise but complete; LaTeX allowed in both).
            Respond with ONLY a JSON object:
            {"questions": [{"question": "<question text>", "answer": "<model answer>"}]}
            """))

            let raw = try await AIService.send(
                system: SystemPrompt.tutor(subjectContext: note.subjectContext ?? "calculus1"),
                messages: [.user(blocks)],
                maxTokens: 2000
            )
            guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
                  let data = String(raw[start...end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["questions"] as? [[String: Any]], !items.isEmpty else {
                errorMessage = String(localized: "ai.quiz.failed")
                isLoading = false
                return
            }
            questions = items.prefix(6).compactMap { item in
                guard let question = item["question"] as? String, !question.isEmpty else { return nil }
                return QuizQuestion(question: question, answer: item["answer"] as? String ?? "")
            }
            if questions.isEmpty { errorMessage = String(localized: "ai.quiz.failed") }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func grade(correct: Bool) {
        if correct { correctCount += 1 }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            revealed = false
            index += 1
        }
    }

    func restart() async {
        guard let request = lastRequest else { return }
        await start(note: request.note, pageIndex: request.pageIndex, darkMode: request.darkMode)
    }
}

/// Card-by-card quiz: progress, question, reveal answer, self-grade, score.
struct QuizView: View {
    @ObservedObject var quiz: QuizController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if quiz.isLoading {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("quiz.loading")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = quiz.errorMessage {
                    ContentUnavailableView {
                        Label("ai.quiz.failed", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(verbatim: error)
                    } actions: {
                        Button("quiz.retry") { Task { await quiz.restart() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if quiz.isFinished {
                    scoreView
                } else if quiz.current != nil {
                    questionView
                }
            }
            .navigationTitle(Text("quiz.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var questionView: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Progress header: count + bar.
            HStack {
                Text(verbatim: "\(quiz.index + 1) / \(quiz.questions.count)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ProgressView(value: Double(quiz.index), total: Double(quiz.questions.count))
                .tint(Color.accentColor)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AIRichText(content: quiz.current?.question ?? "")
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SemanticColor.aiMessageBubble, in: RoundedRectangle(cornerRadius: 14))

                    if quiz.revealed {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("quiz.answer", systemImage: "checkmark.seal")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            AIRichText(content: quiz.current?.answer ?? "")
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }

            Spacer(minLength: 0)

            if quiz.revealed {
                // Self-grading: the student judges their own attempt.
                HStack(spacing: 12) {
                    Button {
                        quiz.grade(correct: false)
                    } label: {
                        Label("quiz.missed", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(SemanticColor.destructive)

                    Button {
                        quiz.grade(correct: true)
                    } label: {
                        Label("quiz.gotIt", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SemanticColor.success)
                }
            } else {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { quiz.revealed = true }
                } label: {
                    Label("quiz.showAnswer", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private var scoreView: some View {
        VStack(spacing: 18) {
            Image(systemName: quiz.correctCount == quiz.questions.count ? "trophy.fill" : "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
            Text("quiz.score \(quiz.correctCount) \(quiz.questions.count)")
                .font(.title2.weight(.semibold))
            ProgressView(value: Double(quiz.correctCount), total: Double(max(quiz.questions.count, 1)))
                .tint(Color.accentColor)
                .frame(maxWidth: 280)
            HStack(spacing: 12) {
                Button("quiz.again") { Task { await quiz.restart() } }
                    .buttonStyle(.bordered)
                Button("action.done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

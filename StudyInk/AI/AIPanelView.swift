import SwiftUI

/// Secondary reading surface: a 320pt right-side drawer with the full AI history
/// for this note and room for long mathematical explanations. Mirrors in RTL.
struct AIPanelView: View {
    @ObservedObject var tutor: AITutorController
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.aiAccent) private var aiAccent
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private var isLoading: Bool { !tutor.loadingBubbleIDs.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Composer up top — at the bottom of a tall drawer it was a reach.
            composer
            Divider()
            if let bubbleID = tutor.panelBubbleID,
               let bubble = tutor.bubbles.first(where: { $0.id == bubbleID }) ?? tutor.history.first(where: { $0.id == bubbleID }) {
                threadDetail(bubble)
            } else {
                historyList
            }
        }
        .frame(width: 320)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .studyGlass(cornerRadius: 24)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .transition(.move(edge: layoutDirection == .rightToLeft ? .leading : .trailing))
    }

    /// Ask directly from the panel: follows up on the open thread, or starts a
    /// new bubble when viewing the history list.
    private var composer: some View {
        let canSend = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
        return HStack(spacing: 8) {
            TextField(
                tutor.panelBubbleID == nil ? "ai.askPlaceholder" : "ai.askMore",
                text: $input,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .focused($inputFocused)
            .onSubmit(send)
            Button(action: send) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    // Circular send in the AI accent.
                    Lucide("arrow-up", size: 14)
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(canSend ? aiAccent : Color.secondary.opacity(0.4)))
                }
            }
            .disabled(!canSend)
            .accessibilityLabel(Text("ai.send"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(SemanticColor.aiMessageBubble.opacity(0.35))
    }

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isLoading else { return }
        input = ""
        inputFocused = false
        Task { await tutor.askFromPanel(question: question) }
    }

    private var header: some View {
        HStack {
            if tutor.panelBubbleID != nil {
                Button {
                    tutor.panelBubbleID = nil
                } label: {
                    Lucide("chevron-left", size: 18)
                        .foregroundStyle(SemanticColor.textMutedColor)
                }
                .accessibilityLabel(Text("action.back"))
            }
            // Serif header in the AI accent — the tutor's voice.
            Text(tutor.panelBubbleID == nil ? "ai.history" : "ai.thread")
                .font(.fraunces(18, weight: .semibold, relativeTo: .headline))
                .foregroundStyle(aiAccent)
            Spacer()
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    tutor.panelOpen = false
                }
            } label: {
                Lucide("x", size: 18)
                    .foregroundStyle(SemanticColor.textMutedColor)
            }
            .accessibilityLabel(Text("action.close"))
        }
        .padding(14)
    }

    private var historyList: some View {
        Group {
            if tutor.history.isEmpty && tutor.bubbles.isEmpty {
                ContentUnavailableView("ai.history.empty", systemImage: "bubble.left.and.text.bubble.right")
            } else {
                List {
                    if !tutor.bubbles.isEmpty {
                        Section(header: Text("ai.history.active")) {
                            ForEach(tutor.bubbles) { bubble in historyRow(bubble) }
                        }
                    }
                    if !tutor.history.isEmpty {
                        Section(header: Text("ai.history.past")) {
                            ForEach(tutor.history) { bubble in historyRow(bubble) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func historyRow(_ bubble: AIBubbleModel) -> some View {
        Button {
            tutor.panelBubbleID = bubble.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if let question = bubble.thread.first?.question {
                    Text(question)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Text(bubble.latestAnswer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    Text("ai.history.page \(bubble.pageIndex + 1)")
                    Text(bubble.createdAt, style: .time)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func threadDetail(_ bubble: AIBubbleModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(bubble.thread) { exchange in
                    if let question = exchange.question, !question.isEmpty {
                        // You → the primary accent at low opacity.
                        Text(question)
                            .font(.subheadline)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: question.isMostlyRTL ? .trailing : .leading)
                            .background(SemanticColor.userMessageBubble.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if !exchange.answer.isEmpty {
                        // AI → the light paper card tone with a hairline.
                        AIRichText(content: exchange.answer)
                            .padding(10)
                            .background(SemanticColor.aiMessageBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(SemanticColor.separator, lineWidth: 1)
                            )
                    }
                }
                // Quick-reply chips — same suggestions the floating bubble offers,
                // so following up from the panel is one tap, not retyping.
                if !bubble.chips.isEmpty && !tutor.loadingBubbleIDs.contains(bubble.id) {
                    chipsRow(bubble)
                }
            }
            .padding(14)
        }
    }

    private func chipsRow(_ bubble: AIBubbleModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(bubble.chips, id: \.self) { chip in
                    Button {
                        Haptics.tap()
                        Task { await tutor.followUp(bubbleID: bubble.id, question: chip) }
                    } label: {
                        Text(chip)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(aiAccent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(SemanticColor.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(SemanticColor.separator, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

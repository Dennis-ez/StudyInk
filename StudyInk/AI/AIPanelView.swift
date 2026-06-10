import SwiftUI

/// Secondary reading surface: a 320pt right-side drawer with the full AI history
/// for this note and room for long mathematical explanations. Mirrors in RTL.
struct AIPanelView: View {
    @ObservedObject var tutor: AITutorController
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let bubbleID = tutor.panelBubbleID,
               let bubble = tutor.bubbles.first(where: { $0.id == bubbleID }) ?? tutor.history.first(where: { $0.id == bubbleID }) {
                threadDetail(bubble)
            } else {
                historyList
            }
        }
        .frame(width: 320)
        .background(SemanticColor.aiPanelBackground)
        .overlay(alignment: .leading) { Divider() }
        .transition(.move(edge: layoutDirection == .rightToLeft ? .leading : .trailing))
    }

    private var header: some View {
        HStack {
            if tutor.panelBubbleID != nil {
                Button {
                    tutor.panelBubbleID = nil
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel(Text("action.back"))
            }
            Text(tutor.panelBubbleID == nil ? "ai.history" : "ai.thread")
                .font(.headline)
            Spacer()
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    tutor.panelOpen = false
                }
            } label: {
                Image(systemName: "xmark")
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
                        Text(question)
                            .font(.subheadline)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: question.isMostlyRTL ? .trailing : .leading)
                            .background(SemanticColor.userMessageBubble.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !exchange.answer.isEmpty {
                        AIRichText(content: exchange.answer)
                            .padding(10)
                            .background(SemanticColor.aiMessageBubble.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(14)
        }
    }
}

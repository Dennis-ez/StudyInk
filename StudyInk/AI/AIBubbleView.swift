import SwiftUI

/// A floating AI tutor card on the canvas: blurred material, tone-colored left
/// strip, speech tail toward its anchor, threaded follow-ups, quick-reply chips,
/// and pin / dismiss / open-in-panel / insert-into-note actions.
struct AIBubbleView: View {
    let bubble: AIBubbleModel
    let isLoading: Bool
    let transform: CanvasTransform
    @ObservedObject var tutor: AITutorController
    var onInsertTextBox: (TextBoxModel) -> Void

    @State private var followUpText = ""
    @State private var dragStart: CGPoint?
    @State private var appeared = false
    @FocusState private var followUpFocused: Bool

    private var isRTL: Bool { bubble.latestAnswer.isMostlyRTL }

    var body: some View {
        let screenPos = transform.toScreen(CGPoint(x: bubble.x, y: bubble.y))
        let width = bubble.width * transform.zoomScale

        Group {
            if bubble.isCollapsed {
                collapsedChip
            } else {
                card.frame(width: max(width, 260))
            }
        }
        .position(x: screenPos.x + max(width, 260) / 2, y: screenPos.y + 80)
        .scaleEffect(appeared ? 1 : 0.8)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { appeared = true }
        }
        .gesture(dragGesture)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("ai.bubble.accessibility"))
        .accessibilityValue(Text(bubble.latestAnswer))
    }

    // MARK: - Collapsed (pinned) state

    private var collapsedChip: some View {
        Button {
            tutor.toggleCollapsed(bubbleID: bubble.id)
        } label: {
            HStack(spacing: 6) {
                avatar
                Text(String(bubble.latestAnswer.prefix(20)))
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(SemanticColor.aiBubbleBorder))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            thread
            if isLoading { loadingRow }
            if !bubble.chips.isEmpty && !isLoading { chipsRow }
            askMoreField
            footer
        }
        .background(tail.offset(x: isRTL ? 12 : -12, y: 28), alignment: isRTL ? .topTrailing : .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(SemanticColor.aiBubbleBorder, lineWidth: 1)
        )
        .overlay(alignment: isRTL ? .trailing : .leading) {
            // Tone strip: blue explanation, green encouragement, orange correction, red error.
            UnevenRoundedRectangle(
                topLeadingRadius: isRTL ? 0 : 14, bottomLeadingRadius: isRTL ? 0 : 14,
                bottomTrailingRadius: isRTL ? 14 : 0, topTrailingRadius: isRTL ? 14 : 0
            )
            .fill(Color(bubble.tone.colorToken))
            .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }

    private var header: some View {
        HStack(spacing: 8) {
            avatar
            Text("ai.tutorName")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                tutor.pin(bubbleID: bubble.id)
            } label: {
                Image(systemName: bubble.isPinned ? "pin.fill" : "pin")
                    .font(.caption)
            }
            .accessibilityLabel(Text("ai.pin"))
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    tutor.dismiss(bubbleID: bubble.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .accessibilityLabel(Text("ai.dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var avatar: some View {
        Image(systemName: "graduationcap.circle.fill")
            .font(.system(size: 18))
            .foregroundStyle(SemanticColor.accentBlue)
            .symbolRenderingMode(.hierarchical)
    }

    private var thread: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(bubble.thread) { exchange in
                if let question = exchange.question, !question.isEmpty {
                    Text(question)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(SemanticColor.userMessageBubble.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                }
                if !exchange.answer.isEmpty {
                    AIRichText(content: exchange.answer)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxHeight: 380)
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("ai.thinking")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// Quick-reply chips Claude suggested; horizontal scroll when they overflow.
    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(bubble.chips, id: \.self) { chip in
                    Button {
                        sendFollowUp(chip)
                    } label: {
                        Text(chip)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(SemanticColor.aiMessageBubble, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 4)
    }

    private var askMoreField: some View {
        HStack(spacing: 8) {
            TextField("ai.askMore", text: $followUpText, axis: .vertical)
                .font(.caption)
                .textFieldStyle(.plain)
                .focused($followUpFocused)
                .lineLimit(1...3)
                .onSubmit { sendFollowUp(followUpText) }
            Button {
                sendFollowUp(followUpText)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(followUpText.isEmpty ? Color.secondary : SemanticColor.accentBlue)
            }
            .disabled(followUpText.isEmpty || isLoading)
            .accessibilityLabel(Text("ai.send"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(SemanticColor.aiMessageBubble.opacity(0.4))
    }

    private var footer: some View {
        HStack {
            Button {
                if let box = tutor.insertAnswerIntoNote(bubbleID: bubble.id) {
                    onInsertTextBox(box)
                }
            } label: {
                Label("ai.insertIntoNote", systemImage: "text.badge.plus")
                    .font(.caption2)
            }
            .disabled(bubble.latestAnswer.isEmpty)
            Spacer()
            Button {
                tutor.panelBubbleID = bubble.id
                tutor.panelOpen = true
            } label: {
                Label("ai.openInPanel", systemImage: "sidebar.trailing")
                    .font(.caption2)
            }
            .accessibilityLabel(Text("ai.openInPanel"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Speech-bubble tail pointing back toward the anchor content.
    private var tail: some View {
        Triangle()
            .fill(.regularMaterial)
            .overlay(Triangle().stroke(SemanticColor.aiBubbleBorder, lineWidth: 1))
            .frame(width: 14, height: 16)
            .rotationEffect(.degrees(isRTL ? 90 : -90))
    }

    // MARK: - Actions

    private func sendFollowUp(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isLoading else { return }
        followUpText = ""
        followUpFocused = false
        Task { await tutor.followUp(bubbleID: bubble.id, question: question) }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragStart == nil { dragStart = CGPoint(x: bubble.x, y: bubble.y) }
                guard let start = dragStart else { return }
                tutor.move(bubbleID: bubble.id, to: CGPoint(
                    x: start.x + value.translation.width / transform.zoomScale,
                    y: start.y + value.translation.height / transform.zoomScale
                ))
            }
            .onEnded { _ in dragStart = nil }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

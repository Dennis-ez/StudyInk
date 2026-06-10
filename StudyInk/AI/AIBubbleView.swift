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
            .studyGlassCapsule()
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
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .studyGlass(cornerRadius: 22)
        // The response tone (explanation/encouragement/correction/error)
        // shows as a soft colored glow around the glass.
        .shadow(color: Color(bubble.tone.colorToken).opacity(0.32), radius: 18, y: 6)
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }

    private var header: some View {
        HStack(spacing: 8) {
            avatar
            Text("ai.tutorName")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Circle()
                .fill(Color(bubble.tone.colorToken))
                .frame(width: 7, height: 7)
            Spacer()
            Button {
                Haptics.tap()
                tutor.pin(bubbleID: bubble.id)
            } label: {
                Image(systemName: bubble.isPinned ? "pin.fill" : "pin")
                    .font(.caption)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("ai.pin"))
            Button {
                Haptics.tap()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    tutor.dismiss(bubbleID: bubble.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("ai.dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var avatar: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [SemanticColor.accentBlue, Color(red: 0.62, green: 0.36, blue: 0.96)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 26, height: 26)
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: SemanticColor.accentBlue.opacity(0.4), radius: 4, y: 1)
    }

    /// Natural height for short threads; scrolls once content exceeds ~320pt.
    private var thread: some View {
        ViewThatFits(in: .vertical) {
            threadContent
            ScrollView { threadContent }
        }
        .frame(maxHeight: 320)
    }

    private var threadContent: some View {
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
                        Haptics.tap()
                        sendFollowUp(chip)
                    } label: {
                        Text(chip)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(SemanticColor.accentBlue)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(SemanticColor.accentBlue.opacity(0.35), lineWidth: 0.8))
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
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SemanticColor.aiBubbleBorder.opacity(0.6), lineWidth: 0.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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

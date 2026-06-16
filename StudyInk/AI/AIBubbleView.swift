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
    @State private var resizeStartWidth: Double?
    @State private var resizeStartHeight: Double?
    @State private var appeared = false
    @State private var shimmerPhase = false
    @FocusState private var followUpFocused: Bool
    @Environment(\.aiAccent) private var aiAccent
    @Environment(\.colorScheme) private var colorScheme

    /// Frosted card fill over the live canvas: lighter in light mode, denser in
    /// dark so text stays legible against the page.
    private var cardMaterial: Material {
        colorScheme == .dark ? .regularMaterial : .ultraThinMaterial
    }

    private var isRTL: Bool { bubble.latestAnswer.isMostlyRTL }

    /// Bubbles scale with the page (clamped for legibility) so they read as
    /// page content, not floating chrome.
    private var pageZoom: CGFloat {
        min(max(transform.zoomScale, 0.6), 1.8)
    }

    var body: some View {
        let screenPos = transform.toScreen(CGPoint(x: bubble.x, y: bubble.y))
        let cardWidth = max(bubble.width, 300)

        Group {
            if bubble.isCollapsed {
                collapsedChip
            } else {
                card.frame(width: cardWidth)
            }
        }
        .scaleEffect(pageZoom * (appeared ? 1 : 0.8), anchor: .top)
        .position(x: screenPos.x + cardWidth * pageZoom / 2, y: screenPos.y + 90 * pageZoom)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(DS.Motion.bubbleAppear) { appeared = true }
        }
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
        // Foolscap card styling: a frosted material over the live canvas with a
        // hairline in the AI accent and a soft lift off the page; the tone shows
        // as a colored shoulder along the leading edge.
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(cardMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(aiAccent.opacity(0.22), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color(bubble.tone.colorToken))
                .frame(width: 4)
                .padding(.vertical, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .elevation(.e3)
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }

    /// Bottom-corner grip resizes width and thread height together.
    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(6)
            .contentShape(Rectangle().scale(2))
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if resizeStartWidth == nil {
                            resizeStartWidth = bubble.width
                            resizeStartHeight = bubble.maxHeight ?? 320
                        }
                        guard let start = resizeStartWidth else { return }
                        tutor.resize(
                            bubbleID: bubble.id,
                            width: start + value.translation.width / pageZoom,
                            maxHeight: (resizeStartHeight ?? 320) + value.translation.height / pageZoom
                        )
                    }
                    .onEnded { _ in
                        resizeStartWidth = nil
                        resizeStartHeight = nil
                    }
            )
            .accessibilityLabel(Text("media.resize"))
    }

    private var header: some View {
        HStack(spacing: 7) {
            avatar
            Text("ai.tutorName")
                .font(.fraunces(13, weight: .semibold, relativeTo: .footnote))
                .foregroundStyle(aiAccent)
            Spacer(minLength: 4)
            headerButton(bubble.isPinned ? "pin.fill" : "pin", label: "ai.pin") {
                Haptics.tap()
                tutor.pin(bubbleID: bubble.id)
            }
            headerButton("xmark", label: "ai.dismiss") {
                Haptics.tap()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    tutor.dismiss(bubbleID: bubble.id)
                }
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        // The header is the drag handle — the scrollable thread below would
        // otherwise swallow drags.
        .highPriorityGesture(dragGesture)
    }

    /// Soft circular header control — pin / dismiss.
    private func headerButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(.black.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private var avatar: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(aiAccent)
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    /// Natural height for short threads; scrolls once content exceeds the
    /// (user-resizable) cap.
    private var thread: some View {
        ViewThatFits(in: .vertical) {
            threadContent
            ScrollView { threadContent }
        }
        .frame(maxHeight: bubble.maxHeight ?? 320)
    }

    private var threadContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(bubble.thread) { exchange in
                if let question = exchange.question, !question.isEmpty {
                    Text(question)
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(aiAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if !exchange.answer.isEmpty {
                    AIRichText(content: exchange.answer)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// Thinking state (spec): two shimmer placeholder bars + three tone-colored
    /// pulsing dots, in place of the answer body.
    private var loadingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            shimmerBar(widthFraction: 1.0)
            HStack(spacing: 8) {
                shimmerBar(widthFraction: 0.55)
                thinkingDots
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityLabel(Text("ai.thinking"))
    }

    private func shimmerBar(widthFraction: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(aiAccent.opacity(0.12))
            .frame(height: 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(x: widthFraction, anchor: .leading)
            .opacity(shimmerPhase ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: shimmerPhase)
    }

    private var thinkingDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(bubble.tone.colorToken))
                    .frame(width: 5, height: 5)
                    .opacity(shimmerPhase ? 0.3 : 1)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18),
                        value: shimmerPhase
                    )
            }
        }
        .onAppear { shimmerPhase = true }
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
                            .foregroundStyle(aiAccent)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(aiAccent.opacity(0.35), lineWidth: 0.8))
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
                    .foregroundStyle(followUpText.isEmpty ? Color.secondary : aiAccent)
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
                // Position maps through the *real* zoom; pageZoom is the clamped
                // display scale. Dividing by the clamp made drags overshoot or
                // lag whenever zoomed past the clamp range.
                tutor.move(bubbleID: bubble.id, to: CGPoint(
                    x: start.x + value.translation.width / transform.zoomScale,
                    y: start.y + value.translation.height / transform.zoomScale
                ))
            }
            .onEnded { _ in dragStart = nil }
    }
}

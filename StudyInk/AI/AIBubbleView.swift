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
    @State private var shimmerPhase = false
    @FocusState private var followUpFocused: Bool
    @Environment(\.aiAccent) private var aiAccent
    @Environment(\.colorScheme) private var colorScheme

    /// Frosted card fill over the live canvas: lighter in light mode, denser in
    /// dark so text stays legible against the page.
    private var cardMaterial: Material {
        colorScheme == .dark ? .regularMaterial : .ultraThinMaterial
    }

    /// The tone strip colour, per the v2 redline:
    /// teaching → primary accent · correct → success · correction → aiCircle ·
    /// error → destructive. Mapped from the model's existing tone cases.
    private var toneColor: Color {
        switch bubble.tone {
        case .explanation:   return Color.accentColor
        case .encouragement: return SemanticColor.success
        case .correction:    return AppTheme.current.aiCircleColor
        case .error:         return SemanticColor.destructive
        }
    }

    private var isRTL: Bool { bubble.latestAnswer.isMostlyRTL }

    /// The bubble is a FIXED-size chat card (like the check-my-work note) — it
    /// stays anchored to its page point as you scroll/zoom, but never scales with
    /// the zoom, so its text stays a consistent, readable size.
    private var pageZoom: CGFloat { 1 }

    var body: some View {
        let screenPos = transform.toScreen(CGPoint(x: bubble.x, y: bubble.y))
        // v2 redline: keep the bubble compact (~304). Honour a user resize but
        // never balloon into a panel.
        let cardWidth = min(max(bubble.width, 304), 320)

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
                Lucide("chevron-down", size: 14)
                    .foregroundStyle(SemanticColor.textMutedColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .studyGlassCapsule()
        }
        .buttonStyle(.plain)
        // Draggable while pinned/collapsed — re-anchors like the full card.
        .simultaneousGesture(dragGesture)
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
        // v2 redline: frosted `surface` material over the live canvas, r18 with a
        // 1px `separator` hairline and an e3 lift. A 4px full-height tone strip
        // sits flush against the leading edge; the body padding (inline-start 18)
        // clears it.
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SemanticColor.surface.opacity(colorScheme == .dark ? 0.94 : 0.88))
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(cardMaterial))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(toneColor)
                .frame(width: 4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(SemanticColor.separator, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .elevation(.e3)
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }

    private var header: some View {
        HStack(spacing: 8) {
            avatar
            Text("ai.tutorName")
                .font(.fraunces(13, weight: .medium, relativeTo: .footnote))
                .foregroundStyle(SemanticColor.textMutedColor)
            Spacer(minLength: 4)
            // Pin keeps an SF Symbol — there is no bundled Lucide pin glyph.
            headerButton(bubble.isPinned ? "pin.fill" : "pin", label: "ai.pin") {
                Haptics.tap()
                tutor.pin(bubbleID: bubble.id)
            }
            Button {
                Haptics.tap()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    tutor.dismiss(bubbleID: bubble.id)
                }
            } label: {
                Lucide("x", size: 16)
                    .foregroundStyle(SemanticColor.textMutedColor)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("ai.dismiss"))
        }
        .padding(.leading, 18)
        .padding(.trailing, 15)
        .padding(.top, 13)
        .padding(.bottom, 5)
        .contentShape(Rectangle())
        // The header is the drag handle — the scrollable thread below would
        // otherwise swallow drags.
        .highPriorityGesture(dragGesture)
    }

    /// Soft circular header control — pin.
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

    /// 22pt AI-accent circle with a radiant white sparkles glyph.
    private var avatar: some View {
        Circle()
            .fill(aiAccent)
            .frame(width: 22, height: 22)
            .overlay(
                Lucide("sparkles", size: 12)
                    .foregroundStyle(.white)
            )
    }

    /// Natural height for short threads; scrolls once content exceeds the
    /// (user-resizable) cap.
    private var thread: some View {
        ScrollViewReader { proxy in
            ViewThatFits(in: .vertical) {
                threadContent
                ScrollView { threadContent }
            }
            .frame(maxHeight: 360)   // fixed, scrollable thread (no resize handle)
            // Asking a new question (or the answer streaming in) scrolls to the end.
            .onChange(of: bubble.thread.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("threadBottom", anchor: .bottom) }
            }
            .onChange(of: bubble.thread.last?.answer) { _, _ in
                proxy.scrollTo("threadBottom", anchor: .bottom)
            }
        }
    }

    private var threadContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(bubble.thread) { exchange in
                if let question = exchange.question, !question.isEmpty {
                    // Q → right-aligned accent chip.
                    Text(question)
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(aiAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if !exchange.answer.isEmpty {
                    // A → left-aligned body (AIRichText owns its own typography
                    // and inline KaTeX; kept as-is per spec).
                    AIRichText(content: exchange.answer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Color.clear.frame(height: 1).id("threadBottom")   // scroll-to-end anchor
        }
        .padding(.leading, 18)
        .padding(.trailing, 15)
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
        .padding(.leading, 18)
        .padding(.trailing, 15)
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
                    .fill(toneColor)
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
                        // chip/13/medium · surface fill · 1px separator · pill ·
                        // AI-accent text.
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
            .padding(.leading, 18)
            .padding(.trailing, 15)
        }
        .padding(.vertical, 4)
    }

    private var askMoreField: some View {
        let canSend = !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
        return HStack(spacing: 8) {
            TextField("ai.askMore", text: $followUpText, axis: .vertical)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .focused($followUpFocused)
                .lineLimit(1...3)
                .onSubmit { sendFollowUp(followUpText) }
            // Trailing circular send in the AI accent.
            Button {
                sendFollowUp(followUpText)
            } label: {
                Lucide("arrow-up", size: 14)
                    .foregroundStyle(.white)
                    .frame(width: 23, height: 23)
                    .background(Circle().fill(canSend ? aiAccent : Color.secondary.opacity(0.4)))
            }
            .disabled(!canSend)
            .accessibilityLabel(Text("ai.send"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(SemanticColor.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(SemanticColor.separator, lineWidth: 1))
        .padding(.leading, 18)
        .padding(.trailing, 15)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            // Insert into note → AI accent.
            Button {
                if let box = tutor.insertAnswerIntoNote(bubbleID: bubble.id) {
                    onInsertTextBox(box)
                }
            } label: {
                Text("ai.insertIntoNote")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(aiAccent)
            }
            .buttonStyle(.plain)
            .disabled(bubble.latestAnswer.isEmpty)
            Spacer()
            // Open in panel → primary accent.
            Button {
                tutor.panelBubbleID = bubble.id
                tutor.panelOpen = true
            } label: {
                HStack(spacing: 3) {
                    Text("ai.openInPanel")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("ai.openInPanel"))
        }
        .padding(.leading, 18)
        .padding(.trailing, 15)
        .padding(.top, 6)
        .padding(.bottom, 13)
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
        // Measure translation in GLOBAL space, not the bubble's own (moving) frame.
        // A local DragGesture reads translation relative to the view it's on — but
        // that view moves as we drag it, so the reference frame shifts under the
        // finger and the bubble vibrates. Global space is stable.
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
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

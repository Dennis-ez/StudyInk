import SwiftUI

/// Feature 5b — **AI chat · The thread lives in the margin** (handoff §4.5, `ChatPeer.dc.html`).
/// Chat is NOT a side panel: each exchange is a thread pinned to the line that prompted
/// it, collapsed to a connector chip until opened. Threads are keyed by {col,line}.

struct MarginThread: Identifiable, Equatable {
    enum Speaker { case you, margin }
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        var speaker: Speaker
        var text: String
    }
    let id = UUID()
    var anchor: AIClient.Anchor
    var preview: String          // the first question, shown on the collapsed chip
    var resolved: Bool = false
    var turns: [Turn] = []
    var followups: [String] = []
}

/// The collapsed node — a connector pill in the right margin: "Thread on line N · <q> · K ›"
/// with a ✦ (or a success ✓ when resolved).
struct ThreadChip: View {
    let thread: MarginThread
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 7) {
                if thread.resolved { TutorGlyph(kind: .correct).frame(width: 16, height: 16) }
                else { Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold)).foregroundStyle(AITokens.ai) }
                Text("Thread on line \(thread.anchor.line + 1)")
                    .font(AITokens.mono(9)).tracking(0.4).foregroundStyle(AITokens.textFainter)
                Text("· \(thread.preview)")
                    .font(.system(size: 12)).foregroundStyle(AITokens.textMuted).lineLimit(1)
                Text("\(thread.turns.count) ›").font(.system(size: 11, weight: .bold)).foregroundStyle(AITokens.textFaint)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(AITokens.cardBg, in: Capsule())
            .overlay(Capsule().strokeBorder(AITokens.cardRing))
        }
        .buttonStyle(.plain)
    }
}

/// The open node — the mini-conversation card with YOU / MARGIN bubbles, mono speaker
/// labels, follow-up prompts, and the action chips.
struct MarginThreadView: View {
    let thread: MarginThread
    var onResolve: () -> Void
    var onShowOnPage: () -> Void
    var onFollowup: (String) -> Void
    var onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Thread · line \(thread.anchor.line + 1)")
                    .font(AITokens.mono(9)).tracking(0.6).foregroundStyle(AITokens.textFainter)
                Spacer()
                Button(action: onCollapse) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(AITokens.textFaint)
                }
                .buttonStyle(.plain)
            }
            ForEach(thread.turns) { turn in bubble(turn) }
            if !thread.followups.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(thread.followups, id: \.self) { f in
                        Button { onFollowup(f) } label: {
                            Text(f).font(.system(size: 12)).foregroundStyle(AITokens.ai)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(AITokens.ai.opacity(0.08), in: Capsule())
                                .overlay(Capsule().strokeBorder(AITokens.ai.opacity(0.25)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                TutorChip(title: "ambient.chat.gotIt", systemImage: "checkmark",
                          accent: AITokens.success, action: onResolve)
                TutorChip(title: "ambient.chat.showOnPage", style: .ghost, action: onShowOnPage)
            }
        }
        .padding(12)
        .frame(maxWidth: 300, alignment: .leading)
        .background(AITokens.cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AITokens.cardRing))
        .shadow(color: AITokens.cardShadow.opacity(0.3), radius: 18, y: 8)
    }

    @ViewBuilder private func bubble(_ turn: MarginThread.Turn) -> some View {
        let isYou = turn.speaker == .you
        VStack(alignment: isYou ? .trailing : .leading, spacing: 3) {
            Text(isYou ? "YOU" : "MARGIN")
                .font(AITokens.mono(8)).tracking(0.8).foregroundStyle(AITokens.textFainter)
            Text(turn.text)
                .font(.system(size: 13))
                .foregroundStyle(isYou ? .white : AITokens.textInk)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background {
                    if isYou {
                        UnevenRoundedRectangle(cornerRadii: .init(topLeading: 13, bottomLeading: 13, bottomTrailing: 4, topTrailing: 13))
                            .fill(AITokens.inkStudent)
                    } else {
                        UnevenRoundedRectangle(cornerRadii: .init(topLeading: 13, bottomLeading: 4, bottomTrailing: 13, topTrailing: 13))
                            .fill(AITokens.aiInkTagBg)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: isYou ? .trailing : .leading)
    }
}

/// One conversation bubble — YOU (slate, right) / MARGIN (amber, left), mono speaker
/// label, uneven radii. The MARGIN answer renders via AIRichText so math/RTL are handled.
struct ThreadBubbleRow: View {
    enum Speaker { case you, margin }
    let speaker: Speaker
    let text: String

    /// Any Hebrew ⇒ read right-to-left and hug the right edge (the design is RTL when
    /// the content is Hebrew). AIRichText already right-aligns the answer's own text.
    private var rtl: Bool { text.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) } }

    var body: some View {
        let isYou = speaker == .you
        // Hebrew rows go to the right; otherwise the usual YOU-right / MARGIN-left.
        let trailing = rtl || isYou
        return VStack(alignment: trailing ? .trailing : .leading, spacing: 3) {
            Text(isYou ? "YOU" : "MARGIN")
                .font(AITokens.mono(8)).tracking(0.8).foregroundStyle(AITokens.textFainter)
            Group {
                if isYou {
                    Text(text).font(.system(size: 13)).foregroundStyle(.white)
                        .multilineTextAlignment(rtl ? .trailing : .leading)
                        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                } else {
                    AIRichText(content: text).font(.system(size: 13)).foregroundStyle(AITokens.textInk)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background {
                if isYou {
                    UnevenRoundedRectangle(cornerRadii: .init(topLeading: 13, bottomLeading: 13, bottomTrailing: 4, topTrailing: 13))
                        .fill(AITokens.inkStudent)
                } else {
                    UnevenRoundedRectangle(cornerRadii: .init(topLeading: 13, bottomLeading: 4, bottomTrailing: 13, topTrailing: 13))
                        .fill(AITokens.aiInkTagBg)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}

/// Feature 5b live — renders an existing `AIBubbleModel` chat thread as a margin thread
/// (collapsed connector chip / open YOU·MARGIN conversation), reusing the AITutorController
/// wiring (followUp / dismiss / toggleCollapsed). Replaces the AIBubbleView card chrome.
struct MarginThreadBubble: View {
    let bubble: AIBubbleModel
    let isLoading: Bool
    let transform: CanvasTransform
    @ObservedObject var tutor: AITutorController
    @State private var followUpText = ""
    @State private var appeared = false
    @State private var dragOffset: CGSize = .zero
    @State private var keyboardHeight: CGFloat = 0
    @FocusState private var focused: Bool

    private var rows: [(speaker: ThreadBubbleRow.Speaker, text: String)] {
        var out: [(ThreadBubbleRow.Speaker, String)] = []
        for (i, ex) in bubble.thread.enumerated() {
            // Hide a system-seeded first question (the ghost's "explain this step" prompt).
            let hideQ = i == 0 && bubble.hidesLeadQuestion == true
            if !hideQ, let q = ex.question, !q.trimmingCharacters(in: .whitespaces).isEmpty { out.append((.you, q)) }
            if !ex.answer.trimmingCharacters(in: .whitespaces).isEmpty { out.append((.margin, ex.answer)) }
        }
        return out
    }
    private var preview: String {
        if let t = bubble.title, !t.isEmpty { return t }
        if bubble.hidesLeadQuestion != true, let q = bubble.thread.first?.question, !q.isEmpty { return q }
        return String(bubble.latestAnswer.prefix(24))
    }
    private var canSend: Bool { !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading }

    var body: some View {
        let pos = transform.toScreen(CGPoint(x: bubble.x, y: bubble.y))
        // Always spawn fully on screen (never cut off), even for a bubble anchored near
        // an edge. Drag moves it (committed to the model on release). When the keyboard
        // is up, raise it so the input + send button stay visible above it.
        let screen = UIScreen.main.bounds
        let bottomLimit = screen.height - 190 - keyboardHeight - (keyboardHeight > 0 ? 60 : 0)
        let cx = min(max(pos.x + 150, 168), max(168, screen.width - 168))
        let cy = min(max(pos.y + 84, 150), max(150, bottomLimit))
        return Group {
            if bubble.isCollapsed { chip } else { open }
        }
        .scaleEffect(appeared ? 1 : 0.86, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .offset(dragOffset)
        .position(x: cx, y: cy)
        .animation(.easeOut(duration: 0.25), value: keyboardHeight)
        .onAppear { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { appeared = true } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            if focused, let f = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect { keyboardHeight = f.height }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
    }

    /// Drag to move — measured in GLOBAL space (stable) and committed to the model
    /// once on release, like the old bubble.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { dragOffset = $0.translation }
            .onEnded { v in
                let z = max(transform.zoomScale, 0.01)
                tutor.move(bubbleID: bubble.id, to: CGPoint(
                    x: bubble.x + v.translation.width / z,
                    y: bubble.y + v.translation.height / z))
                dragOffset = .zero
            }
    }

    private var chip: some View {
        Button { tutor.toggleCollapsed(bubbleID: bubble.id) } label: {
            HStack(spacing: 7) {
                Image(systemName: bubble.isPinned ? "pin.fill" : "sparkle").font(.system(size: 11, weight: .semibold)).foregroundStyle(AITokens.ai)
                Text("Thread").font(AITokens.mono(9)).tracking(0.4).foregroundStyle(AITokens.textFainter)
                Text("· \(preview)").font(.system(size: 12)).foregroundStyle(AITokens.textMuted).lineLimit(1)
                Text("\(bubble.thread.count) ›").font(.system(size: 11, weight: .bold)).foregroundStyle(AITokens.textFaint)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(AITokens.cardBg, in: Capsule())
            .overlay(Capsule().strokeBorder(AITokens.cardRing))
        }
        .buttonStyle(.plain)
    }

    private var open: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(AITokens.textFainter)
                Text("Thread").font(AITokens.mono(9)).tracking(0.6).foregroundStyle(AITokens.textFainter)
                Spacer()
                // Pin to keep the thread anchored on the page (collapses to a small chip).
                Button { tutor.pin(bubbleID: bubble.id) } label: {
                    Image(systemName: bubble.isPinned ? "pin.fill" : "pin").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(bubble.isPinned ? AITokens.ai : AITokens.textFaint)
                }.buttonStyle(.plain)
                Button { tutor.toggleCollapsed(bubbleID: bubble.id) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(AITokens.textFaint)
                }.buttonStyle(.plain)
                Button { tutor.dismiss(bubbleID: bubble.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(AITokens.textFaint)
                }.buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)   // the header is the drag handle
            // Long threads scroll instead of running off the card; auto-scroll to the
            // newest message when a row arrives, the answer updates, or thinking starts.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            ThreadBubbleRow(speaker: row.speaker, text: row.text)
                        }
                        if isLoading {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkle").font(.system(size: 12, weight: .semibold)).foregroundStyle(AITokens.ai).breathing()
                                Text("ai.thinking").font(.system(size: 12)).foregroundStyle(AITokens.textFaint)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("threadBottom")
                    }
                }
                .frame(maxHeight: 260)
                .onChange(of: rows.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("threadBottom", anchor: .bottom) } }
                .onChange(of: bubble.latestAnswer) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("threadBottom", anchor: .bottom) } }
                .onChange(of: isLoading) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("threadBottom", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("threadBottom", anchor: .bottom) }
            }
            if !bubble.chips.isEmpty && !isLoading {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(bubble.chips, id: \.self) { c in
                        Button { Task { await tutor.followUp(bubbleID: bubble.id, question: c) } } label: {
                            Text(c).font(.system(size: 12)).foregroundStyle(AITokens.ai)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(AITokens.ai.opacity(0.08), in: Capsule())
                                .overlay(Capsule().strokeBorder(AITokens.ai.opacity(0.25)))
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("ai.askMore", text: $followUpText, axis: .vertical)
                    .font(.system(size: 13)).textFieldStyle(.plain).focused($focused).onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                        .foregroundStyle(canSend ? AITokens.ai : AITokens.textFaint)
                }.buttonStyle(.plain).disabled(!canSend)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(AITokens.chipBg, in: Capsule())
            TutorChip(title: "ambient.chat.gotIt", systemImage: "checkmark",
                      accent: AITokens.success, action: { tutor.dismiss(bubbleID: bubble.id) })
        }
        .padding(12).frame(width: 300, alignment: .leading)
        .background(AITokens.cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AITokens.cardRing))
        .shadow(color: AITokens.cardShadow.opacity(0.3), radius: 18, y: 8)
        .environment(\.layoutDirection, bubble.latestAnswer.isMostlyRTL ? .rightToLeft : .leftToRight)
    }

    private func send() {
        let q = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        followUpText = ""; focused = false
        Task { await tutor.followUp(bubbleID: bubble.id, question: q) }
    }
}

/// The "+ ask about this line" dashed affordance that starts a new anchored thread.
struct AskAboutLineButton: View {
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text("ambient.chat.askAboutLine").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(AITokens.ai)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                .foregroundStyle(AITokens.ai.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }
}

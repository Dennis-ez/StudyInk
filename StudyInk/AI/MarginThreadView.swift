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

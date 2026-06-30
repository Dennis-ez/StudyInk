import SwiftUI

/// Feature 3b — **Check my work · Straight to the break** (handoff §4.3, `CheckWork.dc.html`).
/// Diagnostic-first: jump to the FIRST error with a precise why; the health-map gives
/// whole-page context at a glance. (No 3a tick-streak/score.)

/// The line-health map — one dot per line (success ✓ / correction), a halo on the
/// broken one. Lives in the toolbar; pops in over 0.3s.
struct LineHealthMap: View {
    /// `ok[i]` = line i passed. `brokenLine` gets the halo.
    let ok: [Bool]
    let brokenLine: Int?
    @State private var shown = false

    var body: some View {
        HStack(spacing: 6) {
            Text("lines").font(AITokens.mono(9)).tracking(0.6).foregroundStyle(AITokens.textFainter)
            ForEach(Array(ok.enumerated()), id: \.offset) { i, passed in
                Circle()
                    .fill(passed ? AITokens.success : AITokens.correction)
                    .frame(width: 8, height: 8)
                    .overlay {
                        if i == brokenLine {
                            Circle().strokeBorder(AITokens.correction.opacity(0.5), lineWidth: 2)
                                .frame(width: 16, height: 16)
                        }
                    }
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.4)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8).delay(Double(i) * 0.04), value: shown)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(AITokens.cardBg, in: Capsule())
        .overlay(Capsule().strokeBorder(AITokens.cardRing))
        .onAppear { shown = true }
    }
}

/// The diagnostic card for the first error — correction accent, mono timing kicker,
/// the why, a worked fix, and the action row.
struct DiagnosticCard: View {
    let error: AIClient.CheckResult.FirstError
    /// Seconds the check took ("found in 0.3s").
    var foundIn: Double = 0.3
    var onFixIt: () -> Void
    var onShowRule: () -> Void
    var onReplay: () -> Void

    var body: some View {
        TutorCard(kicker: "found in \(String(format: "%.1f", foundIn))s",
                  title: "Line \(error.line + 1) — \(error.rubricTag)",
                  accent: .correction) {
            VStack(alignment: .leading, spacing: 10) {
                Text(error.why).font(.system(size: 13.5)).foregroundStyle(AITokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                // The worked fix in the student's own notation.
                AIRichText(content: "$\(error.fixLatex)$").font(.system(size: 13))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AITokens.workedBox, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .environment(\.layoutDirection, .leftToRight)   // math is an LTR island
                HStack(spacing: 8) {
                    TutorChip(title: "ambient.fixIt", systemImage: "checkmark",
                              accent: AITokens.success, action: onFixIt)
                    TutorChip(title: "ambient.showRule", style: .ghost, action: onShowRule)
                    Spacer(minLength: 0)
                    Button(action: onReplay) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AITokens.textFaint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// The idle affordance — a breathing "✦ Find my mistake" pill that parks in the right
/// margin; tap to run the check.
struct FindMistakePill: View {
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.system(size: 12, weight: .semibold))
                Text("ambient.findMistake").font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(AITokens.ai)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(AITokens.cardBg, in: Capsule())
            .overlay(Capsule().strokeBorder(AITokens.ai.opacity(0.35)))
            .shadow(color: AITokens.ai.opacity(0.14), radius: 7, y: 2)
        }
        .buttonStyle(.plain)
        .breathing()
    }
}

/// The in-place spotlight over the broken line (canvas overlay): tinted fill + inset
/// ring; place it at the line's page rect mapped to screen.
struct LineSpotlight: View {
    let screenRect: CGRect
    @State private var shown = false
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(AITokens.correction.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(AITokens.correction.opacity(0.5), lineWidth: 1.5))
            .frame(width: screenRect.width + 14, height: screenRect.height + 8)
            .position(x: screenRect.midX, y: screenRect.midY)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeIn(duration: 0.3)) { shown = true } }
    }
}

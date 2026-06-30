import SwiftUI

/// DEV harness — launch with `CONOTE_GALLERY=1` to eyeball the five tutor surfaces on
/// paper with the canonical demo content (no API key needed). Lets us pixel-check the
/// `design_handoff_conote_ai` builds against the `.dc.html` references.
struct TutorGallery: View {
    @State private var rung = 1
    @State private var selectedVerb: CircleVerb? = .explain

    private let step = AIClient.NextStep(
        nudge: "You've set the integral up. Notice cos(x²) — its inside isn't a plain x. What kind of move untangles a function-inside-a-function?",
        hint: "Let u be the inside of the cosine. Then differentiate it to find du — and watch for the 2x already sitting in front.",
        stepLatex: "u = x^2,\\ du = 2x\\,dx", blankToken: "x^2", confidence: 0.92, value: 0.8)

    private let firstError = AIClient.CheckResult.FirstError(
        line: 4, why: "You put 2x back in for u. But the substitution was u = x² — so the answer is:",
        fixLatex: "\\sin(x^2) + C", rubricTag: "back-substitution")

    private let circle = AIClient.CircleResult(
        explain: "A chain of proteins in the inner mitochondrial membrane. Electrons released from glucose hop down it; each hop pumps H⁺ out, building a gradient that drives ATP synthase.",
        simpler: "A bucket brigade for electrons. Each hand-off shoves a proton uphill, storing 'pressure' that later rushes back through a turbine (ATP synthase) and spins out ATP.",
        analogy: "A hydroelectric dam. The chain pumps water (H⁺) up behind the dam; ATP synthase is the turbine the water spins as it floods back down.",
        quiz: nil)

    private var thread: MarginThread {
        MarginThread(anchor: .init(col: "A", line: 1), preview: "where did 2x go?", resolved: false,
                     turns: [.init(speaker: .you, text: "where did the 2x go?"),
                             .init(speaker: .margin, text: "Good eye — what did you multiply by when you set du = 2x dx? Look at where that factor lands.")],
                     followups: ["show me the substitution", "is the 2x always there?"])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header("Glyphs · ✓ ~ ? ✦ !")
                HStack(spacing: 16) {
                    TutorGlyph(kind: .correct); TutorGlyph(kind: .correction)
                    TutorGlyph(kind: .hint); TutorGlyph(kind: .spark).breathing(); TutorGlyph(kind: .error)
                }

                header("1a · Guided ladder — reveal in layers")
                Picker("rung", selection: $rung) { Text("1").tag(1); Text("2").tag(2); Text("3").tag(3) }
                    .pickerStyle(.segmented).frame(width: 160)
                GuidedLadderCard(step: step, rung: rung, onAdvance: { rung = min(3, rung + 1) },
                                 onReplay: { rung = 1 }, onDismiss: {})

                header("2a · Suggest next step — the fill-in ghost")
                GhostTraceLayer(fullText: "= sin(u) + C", blankToken: "u",
                                why: nil, onAccept: { _ in }, onDismiss: {})

                header("3b · Check my work — straight to the break")
                LineHealthMap(ok: [true, true, true, true, false], brokenLine: 4)
                DiagnosticCard(error: firstError, foundIn: 0.3, onFixIt: {}, onShowRule: {}, onReplay: {})
                FindMistakePill(onTap: {})

                header("4b · Circle to ask — the selection morphs")
                Text("electron transport chain").font(AITokens.caveat(26)).foregroundStyle(AITokens.inkStudent)
                    .circledSpanPill()
                SelectionRail(selected: selectedVerb, onVerb: { selectedVerb = $0 }, onClose: {})
                if let v = selectedVerb { CircleAnswerCard(verb: v, result: circle) }

                header("5b · AI chat — the thread lives in the margin")
                ThreadChip(thread: thread, onOpen: {})
                MarginThreadView(thread: thread, onResolve: {}, onShowOnPage: {}, onFollowup: { _ in }, onCollapse: {})
                AskAboutLineButton(onTap: {})
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .background(AITokens.paper.ignoresSafeArea())
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(AITokens.mono(10, .semibold)).tracking(1.0).foregroundStyle(AITokens.ai)
            .padding(.top, 4)
    }
}

import SwiftUI

/// DEV harness — launch with `CONOTE_GALLERY=1` (all, scrolling) or a section key
/// (`glyphs`/`dial`/`1a`/`2a`/`3b`/`4b`/`5b`/`rtl`) to eyeball one tutor surface
/// centered for a clean screenshot. Canonical demo content, no API key needed; lets us
/// pixel-check the `design_handoff_conote_ai` builds against the `.dc.html` references.
struct TutorGallery: View {
    @State private var rung = 1
    @State private var selectedVerb: CircleVerb? = .explain
    @State private var dial = 2   // 0 off · 1 subtle · 2 helpful

    private var section: String {
        ProcessInfo.processInfo.environment["CONOTE_GALLERY"].flatMap { $0 == "1" ? "all" : $0 } ?? "all"
    }

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
        Group {
            if section == "all" {
                ScrollView { VStack(alignment: .leading, spacing: 26) { everything }.padding(28).frame(maxWidth: 560, alignment: .leading) }
            } else {
                ScrollView { VStack(alignment: .leading, spacing: 18) { sectionView(section) }.padding(28).frame(maxWidth: 520, alignment: .leading) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AITokens.paper.ignoresSafeArea())
    }

    @ViewBuilder private var everything: some View {
        sectionView("glyphs"); sectionView("dial"); sectionView("1a"); sectionView("2a")
        sectionView("3b"); sectionView("4b"); sectionView("5b"); sectionView("rtl")
    }

    @ViewBuilder private func sectionView(_ key: String) -> some View {
        switch key {
        case "glyphs":
            header("Glyphs · ✓ ~ ? ✦ !")
            HStack(spacing: 18) {
                TutorGlyph(kind: .correct); TutorGlyph(kind: .correction)
                TutorGlyph(kind: .hint); TutorGlyph(kind: .spark).breathing(); TutorGlyph(kind: .error)
            }
        case "dial":
            header("Sensitivity dial · Off / Subtle / Helpful")
            Picker("dial", selection: $dial) { Text("Off").tag(0); Text("Subtle").tag(1); Text("Helpful").tag(2) }
                .pickerStyle(.segmented).frame(width: 240)
            Group {
                switch dial {
                case 0:
                    Text("Guided help is off — nothing will surface")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(AITokens.textFaint)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(AITokens.chipBg, in: Capsule())
                case 1:
                    HStack(spacing: 8) { Circle().fill(AITokens.subtleDot).frame(width: 12, height: 12)
                        Text("rung-0 cue · static dot").font(AITokens.mono(10)).foregroundStyle(AITokens.textFainter) }
                default:
                    HStack(spacing: 8) { TutorGlyph(kind: .spark).breathing().frame(width: 28, height: 28)
                        Text("rung-0 cue · breathing ✦").font(AITokens.mono(10)).foregroundStyle(AITokens.textFainter) }
                }
            }
        case "1a":
            header("1a · Guided ladder — reveal in layers")
            Picker("rung", selection: $rung) { Text("1").tag(1); Text("2").tag(2); Text("3").tag(3) }
                .pickerStyle(.segmented).frame(width: 160)
            GuidedLadderCard(step: step, rung: rung, onAdvance: { rung = min(3, rung + 1) },
                             onReplay: { rung = 1 }, onDismiss: {})
        case "2a":
            header("2a · Suggest next step — the fill-in ghost")
            GhostTraceLayer(fullText: "= sin(u) + C", blankToken: "u", why: nil, onAccept: { _ in }, onDismiss: {})
        case "3b":
            header("3b · Check my work — straight to the break")
            LineHealthMap(ok: [true, true, true, true, false], brokenLine: 4)
            DiagnosticCard(error: firstError, foundIn: 0.3, onFixIt: {}, onShowRule: {}, onReplay: {})
            FindMistakePill(onTap: {})
        case "4b":
            header("4b · Circle to ask — the selection morphs")
            HStack(spacing: 10) {
                Text("electron transport chain").font(AITokens.caveat(26)).foregroundStyle(AITokens.inkStudent).circledSpanPill()
                SelectionRail(selected: selectedVerb, onVerb: { selectedVerb = $0 }, onClose: {})
            }
            if let v = selectedVerb { CircleAnswerCard(verb: v, result: circle) }
        case "5b":
            header("5b · AI chat — the thread lives in the margin")
            ThreadChip(thread: thread, onOpen: {})
            MarginThreadView(thread: thread, onResolve: {}, onShowOnPage: {}, onFollowup: { _ in }, onCollapse: {})
            AskAboutLineButton(onTap: {})
        case "rtl":
            header("RTL · lane mirrors, card unfolds inline-end")
            GuidedLadderCard(step: AIClient.NextStep(
                nudge: "הגדרת את האינטגרל. שים לב ל-cos(x²) — מה שבפנים אינו x פשוט. איזו פעולה מתירה פונקציה בתוך פונקציה?",
                hint: nil, stepLatex: nil, blankToken: nil, confidence: 0.9, value: 0.8),
                rung: 1, onAdvance: {}, onReplay: {}, onDismiss: {})
                .environment(\.layoutDirection, .rightToLeft)
        default:
            EmptyView()
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(AITokens.mono(10, .semibold)).tracking(1.0).foregroundStyle(AITokens.ai).padding(.top, 4)
    }
}

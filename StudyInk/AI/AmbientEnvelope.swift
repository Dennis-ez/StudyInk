import Foundation

/// On-device "read & classify first" layer (handoff §5.2, §6.1): turn recognized
/// OCR lines into the `AIClient.Envelope` the model receives — subject classified and
/// direction detected locally, the page reduced to a PARSED line structure (not raw
/// strokes). This is the v1 single-column ordering; the multi-column + messy-order
/// layout pass is a follow-up (task #54), but the envelope shape is final.

/// A lightweight, deterministic subject classifier. Heuristic keyword/symbol scoring —
/// good enough to pick the rubric (math vs chemistry vs essay vs …); can be swapped for
/// an on-device ML classifier later without changing callers.
enum SubjectClassifier {
    static func classify(_ rawText: String) -> String {
        let text = rawText.lowercased()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "general" }

        func hits(_ needles: [String]) -> Int { needles.reduce(0) { $0 + (text.contains($1) ? 1 : 0) } }

        var score: [String: Int] = [:]
        score["chemistry"] = hits(["mol", "reaction", "redox", "h₂o", "h2o", "co2", "co₂", "acid", "base",
                                   " ph ", "ph=", "bond", "oxid", "electron", "ion", "valence", "→ "]) // arrow + charge balance
        score["biology"]   = hits(["cell", "mitochond", "dna", "rna", "gene", "genotype", "phenotype", "atp",
                                   "enzyme", "membrane", "photosynth", "transport chain", "allele", "ratio"])
        score["physics"]   = hits(["velocity", "accelerat", "force", "newton", "momentum", "energy", "joule",
                                   "m/s", "kg", "= u + at", "v=u", "gravity", "friction", "voltage", "current"])
        score["history"]   = hits(["war", "revolution", "century", "treaty", "empire", "nationalism", "thesis",
                                   "because", "evidence", "claim", "1789", "1914", "regime", "monarch"])
        score["language"]  = hits(["tense", "verb", "preterite", "conjugat", "subjunctive", "noun", "adjective",
                                   "plural", "gender", "ayer", "comí", "comi", "fue", "était", "preterito"])
        score["code"]      = hits(["func ", "def ", "return ", "var ", "let ", "const ", "import ", "();", "{}",
                                   "println", "console.", "for(", "while(", "=> "])
        score["music"]     = hits(["chord", "tempo", "key signature", "scale", "octave", "treble", "♩", "♪",
                                   "minor", "major", "interval"])
        // Math: count notation symbols, which are strong signals even with little prose.
        let mathSymbols = ["∫", "∑", "√", "∂", "≤", "≥", "≠", "π", "→", "\\frac", "lim", "sin", "cos", "tan",
                           "log", "dx", "dy", "^2", "x²", "=", "+", "−", "·", "/"]
        score["math"] = mathSymbols.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }

        let best = score.max { a, b in a.value < b.value }
        // A page with essentially no signal (or only a stray "=") reads as general.
        guard let best, best.value >= 2 else { return "general" }
        return best.key
    }
}

extension AIClient {
    /// Page direction from its dominant script (drives lane mirroring + the reply language).
    static func direction(of text: String) -> String { text.isMostlyRTL ? "rtl" : "ltr" }

    /// Reply language from the page's dominant script — a Hebrew page must get a Hebrew
    /// reply (not the device language). Extend as more scripts are supported.
    static func locale(for text: String) -> String {
        for s in text.unicodeScalars where (0x0590...0x05FF).contains(s.value) { return "he-IL" }
        return Locale.current.identifier
    }

    /// Build the structured envelope from on-device OCR lines. Lines are ordered
    /// top→bottom and indexed within a single column "A" (v1); `focusLine` is the line
    /// the surface is anchored to. Subject, direction, AND locale are classified locally
    /// so the tutor speaks the page's language.
    static func buildEnvelope(
        lines: [OCRLine], focusLine: Int?, level: String = "high_school",
        guidedLevel: String, askDepth: Int
    ) -> Envelope {
        let ordered = lines.sorted { $0.rect.minY < $1.rect.minY }
        let structure = ordered.enumerated().map { i, line in
            PageLine(col: "A", line: i, latex: line.text)
        }
        let allText = ordered.map(\.text).joined(separator: " ")
        let focus = focusLine.map { Anchor(col: "A", line: $0) }
        return Envelope(
            locale: locale(for: allText),
            direction: direction(of: allText),
            subject: SubjectClassifier.classify(allText),
            level: level,
            page: PageStructure(structure: structure, focus: focus),
            guidedLevel: guidedLevel,
            askDepth: askDepth
        )
    }
}

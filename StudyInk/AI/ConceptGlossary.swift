import SwiftUI

/// A named study concept the student might write (Lagrange, L'Hôpital, …) with
/// the strings to recognise it by (English + Hebrew) and a short definition in
/// both languages. Tapping a recognised term shows its definition — instantly
/// from here, or via the AI for anything not listed (see ConceptLookup).
struct Concept {
    let title: String
    /// Lowercased strings to match in OCR text — include common spellings and the
    /// Hebrew name. The LONGEST alias that appears wins, so "mean value theorem"
    /// beats a bare "mean".
    let aliases: [String]
    let definitionEN: String
    let definitionHE: String
}

enum ConceptGlossary {
    static let concepts: [Concept] = [
        Concept(title: "L'Hôpital's rule",
                aliases: ["l'hôpital", "l'hopital", "lhopital", "l'hospital", "hopital", "לופיטל", "כלל לופיטל"],
                definitionEN: "For a 0/0 or ∞/∞ limit, lim f/g = lim f′/g′ when the right-hand limit exists — differentiate top and bottom separately.",
                definitionHE: "לגבול מהצורה 0/0 או ∞/∞: lim f/g שווה ל-lim f′/g′ כאשר הגבול קיים — גוזרים את המונה ואת המכנה בנפרד."),
        Concept(title: "Lagrange multipliers",
                aliases: ["lagrange multiplier", "lagrange multipliers", "lagrange", "לגראנז'", "לגראנז", "כופלי לגראנז'"],
                definitionEN: "To optimise f under a constraint g = 0, solve ∇f = λ∇g together with g = 0; λ is the multiplier.",
                definitionHE: "כדי למצוא קיצון של f תחת אילוץ g = 0 פותרים ∇f = λ∇g יחד עם g = 0; λ הוא הכופל."),
        Concept(title: "Derivative",
                aliases: ["derivative", "נגזרת"],
                definitionEN: "The instantaneous rate of change of a function — the slope of its tangent line, f′(x) = lim_{h→0} (f(x+h)−f(x))/h.",
                definitionHE: "קצב השינוי הרגעי של פונקציה — שיפוע המשיק, f′(x) = lim_{h→0} (f(x+h)−f(x))/h."),
        Concept(title: "Integral",
                aliases: ["integral", "integration", "אינטגרל", "אינטגרציה"],
                definitionEN: "The (signed) area under a curve; the inverse of differentiation via the Fundamental Theorem of Calculus.",
                definitionHE: "השטח (עם סימן) שמתחת לגרף; הפעולה ההפוכה לגזירה לפי המשפט היסודי של החשבון."),
        Concept(title: "Limit",
                aliases: ["limit", "גבול"],
                definitionEN: "The value f(x) approaches as x approaches a point — the foundation of continuity, derivatives and integrals.",
                definitionHE: "הערך שאליו f(x) שואפת כאשר x שואף לנקודה — הבסיס לרציפות, נגזרות ואינטגרלים."),
        Concept(title: "Continuity",
                aliases: ["continuous", "continuity", "רציפות", "רציפה"],
                definitionEN: "A function is continuous at a if lim_{x→a} f(x) = f(a): no jumps, holes or breaks there.",
                definitionHE: "פונקציה רציפה ב-a אם lim_{x→a} f(x) = f(a): ללא קפיצות, חורים או שברים בנקודה."),
        Concept(title: "Mean Value Theorem",
                aliases: ["mean value theorem", "משפט הערך הממוצע", "לגראנז' (ערך ממוצע)"],
                definitionEN: "If f is continuous on [a,b] and differentiable on (a,b), some c has f′(c) = (f(b)−f(a))/(b−a).",
                definitionHE: "אם f רציפה ב-[a,b] וגזירה ב-(a,b), קיים c שעבורו f′(c) = (f(b)−f(a))/(b−a)."),
        Concept(title: "Rolle's theorem",
                aliases: ["rolle", "rolle's theorem", "רול", "משפט רול"],
                definitionEN: "If f is continuous on [a,b], differentiable on (a,b) and f(a)=f(b), some c in (a,b) has f′(c)=0.",
                definitionHE: "אם f רציפה ב-[a,b], גזירה ב-(a,b) ו-f(a)=f(b), קיים c ב-(a,b) שעבורו f′(c)=0."),
        Concept(title: "Taylor series",
                aliases: ["taylor series", "taylor", "maclaurin", "טור טיילור", "טיילור", "מקלורן"],
                definitionEN: "Approximates a function near a point by a power series of its derivatives: Σ f⁽ⁿ⁾(a)(x−a)ⁿ/n!.",
                definitionHE: "קירוב של פונקציה סביב נקודה בטור חזקות של נגזרותיה: Σ f⁽ⁿ⁾(a)(x−a)ⁿ/n!."),
        Concept(title: "Chain rule",
                aliases: ["chain rule", "כלל השרשרת"],
                definitionEN: "Derivative of a composition: (f(g(x)))′ = f′(g(x))·g′(x).",
                definitionHE: "נגזרת של הרכבה: (f(g(x)))′ = f′(g(x))·g′(x)."),
        Concept(title: "Riemann sum",
                aliases: ["riemann sum", "riemann", "סכום רימן", "רימן"],
                definitionEN: "Approximates an integral by summing rectangle areas Σ f(xᵢ)Δx; its limit is the definite integral.",
                definitionHE: "קירוב של אינטגרל בעזרת סכום שטחי מלבנים Σ f(xᵢ)Δx; הגבול שלו הוא האינטגרל המסוים."),
        Concept(title: "Gradient",
                aliases: ["gradient", "גרדיאנט", "שיפוע (וקטור)"],
                definitionEN: "The vector of partial derivatives ∇f; it points in the direction of steepest increase of f.",
                definitionHE: "וקטור הנגזרות החלקיות ∇f; מצביע בכיוון העלייה התלולה ביותר של f."),
        Concept(title: "Eigenvalue",
                aliases: ["eigenvalue", "eigenvector", "eigen", "ערך עצמי", "וקטור עצמי"],
                definitionEN: "A scalar λ with Av = λv for some non-zero v — v is only scaled, not rotated, by the matrix A.",
                definitionHE: "סקלר λ שעבורו Av = λv עבור v ≠ 0 — המטריצה A רק מותחת את v ולא מסובבת אותו."),
        Concept(title: "Determinant",
                aliases: ["determinant", "דטרמיננטה", "דטרמיננט"],
                definitionEN: "A scalar from a square matrix giving its volume-scaling factor; zero means the matrix is singular (non-invertible).",
                definitionHE: "סקלר של מטריצה ריבועית המבטא את מקדם שינוי הנפח; אפס פירושו שהמטריצה סינגולרית (לא הפיכה)."),
        Concept(title: "Newton's method",
                aliases: ["newton's method", "newton method", "newton-raphson", "שיטת ניוטון", "ניוטון-רפסון"],
                definitionEN: "Iteratively finds a root: x_{n+1} = x_n − f(x_n)/f′(x_n), converging quadratically near a simple root.",
                definitionHE: "מציאת שורש באיטרציות: x_{n+1} = x_n − f(x_n)/f′(x_n), עם התכנסות ריבועית ליד שורש פשוט."),
        Concept(title: "Asymptote",
                aliases: ["asymptote", "asymptotic", "אסימפטוטה", "אסימפטוטי"],
                definitionEN: "A line a curve approaches but never reaches — horizontal, vertical or oblique.",
                definitionHE: "ישר שאליו הגרף מתקרב אך לא נוגע — אופקי, אנכי או משופע."),
    ]

    /// The longest concept alias that appears in `text` (case- and
    /// diacritic-insensitive), or nil. Returns the matched alias's script too, so
    /// the caller can show the Hebrew or English definition.
    static func match(in text: String) -> (concept: Concept, hebrew: Bool)? {
        let hay = text.lowercased()
        var best: (Concept, Bool, Int)?
        for concept in concepts {
            for alias in concept.aliases {
                guard hay.localizedCaseInsensitiveContains(alias) else { continue }
                let hebrew = alias.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) }
                if best == nil || alias.count > best!.2 { best = (concept, hebrew, alias.count) }
            }
        }
        guard let b = best else { return nil }
        return (b.0, b.1)
    }
}

/// A recognised concept the student tapped, with where it sits on the page and
/// its definition (nil while an AI lookup is in flight).
struct ConceptHit: Identifiable, Equatable {
    let id = UUID()
    var term: String
    var pageRect: CGRect
    var definition: String?
}

enum ConceptLookup {
    /// Glossary first (instant); for an unlisted term, ask the AI for a short
    /// definition if it's configured. Returns nil when nothing is recognised.
    static func define(lineText: String, preferHebrew: Bool) async -> ConceptHit? {
        // (rect is filled by the caller — this only resolves term + definition.)
        if let (concept, hebrew) = ConceptGlossary.match(in: lineText) {
            let useHebrew = hebrew || preferHebrew
            return ConceptHit(term: concept.title,
                              pageRect: .zero,
                              definition: useHebrew ? concept.definitionHE : concept.definitionEN)
        }
        return nil
    }

    /// AI fallback: is there a named concept in this line, and what's a one-line
    /// definition? Returns nil for ordinary working lines so the card never pops
    /// on a non-concept. Only call when `AIConfig.isConfigured`.
    static func defineWithAI(lineText: String) async -> ConceptHit? {
        let prompt = """
        The student tapped this line of their notes: "\(lineText.prefix(200))".
        If it names a specific mathematical/scientific CONCEPT, theorem, or method \
        (e.g. L'Hôpital's rule, Lagrange multipliers, eigenvalue), reply with ONLY a \
        JSON object {"term":"<name>","definition":"<one or two sentence definition in \(SystemPrompt.languageTarget)>"}. \
        If it's just ordinary work with no named concept, reply exactly {}.
        """
        guard let raw = try? await AIService.send(
            system: "You define study concepts concisely. Output only the JSON described.",
            messages: [.user([.text(prompt)])],
            maxTokens: 400,
            temperature: 0
        ) else { return nil }
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let term = obj["term"] as? String, !term.isEmpty,
              let def = obj["definition"] as? String, !def.isEmpty else { return nil }
        return ConceptHit(term: term, pageRect: .zero, definition: def)
    }
}

/// A floating card with a tapped concept's definition, anchored just below the
/// term on the page.
struct ConceptDefinitionCard: View {
    let hit: ConceptHit
    let transform: CanvasTransform
    var onClose: () -> Void

    var body: some View {
        let anchor = transform.toScreen(hit.pageRect)
        let screenW = UIScreen.main.bounds.width
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed.fill").font(.caption).foregroundStyle(SemanticColor.aiCircleStroke)
                Text(verbatim: hit.term).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Spacer(minLength: 12)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("action.cancel"))
            }
            if let def = hit.definition {
                Text(verbatim: def)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(13)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .position(x: min(max(anchor.midX, 170), screenW - 170),
                  y: max(anchor.maxY + 64, 96))
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }
}

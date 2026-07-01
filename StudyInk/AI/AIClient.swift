import Foundation

/// The Conote Gemini **prompt contract** (handoff §6). Every tutor surface is ONE
/// structured call: the page is read + classified on-device first, so direction,
/// subject, and the reconstructed step order arrive as explicit inputs; the model is
/// constrained to a `responseSchema` (`responseMimeType: application/json`) so a
/// malformed answer can't be mis-rendered. Provider-agnostic — Gemini uses the native
/// schema path; Claude / OpenAI-compatible get the schema enforced via the prompt and
/// the same tolerant JSON decode.
enum AIClient {

    // MARK: Gating (§6.4) — gate every candidate, then rank in the Arbiter.

    static let confMark = 0.82      // corrections / general marks
    static let confGhost = 0.88     // the ghost is held to a higher bar
    static let valueMin = 0.0       // high value + low confidence → stay silent

    // MARK: Envelope (§6.1) — sent with every call.

    struct Anchor: Codable, Equatable, Hashable {
        var col: String
        var line: Int
    }
    struct PageLine: Encodable {
        var col: String
        var line: Int
        var latex: String
    }
    struct PageStructure: Encodable {
        /// PARSED logical order, NOT raw strokes.
        var structure: [PageLine]
        /// The anchor in question.
        var focus: Anchor?
    }
    struct Envelope: Encodable {
        var locale: String          // reply in THIS language, e.g. "he-IL"
        var direction: String       // "ltr" | "rtl"
        var subject: String         // classified on-device before the call
        var level: String           // e.g. "high_school"
        var page: PageStructure
        var guidedLevel: String     // "off" | "subtle" | "helpful"
        var askDepth: Int           // 1 nudge · 2 hint · 3 step
    }

    // MARK: System instruction (§6.2 — verbatim, prepended to every call).

    static let system = """
    You are Conote, an ambient handwriting tutor reading a student's page. Always obey:

    1) SPEAK THE PAGE. Reply in `locale`. Mirror `direction`. Keep math and code as LTR LaTeX islands.
    2) GRADE BY THE SUBJECT'S RUBRIC. Use `subject`; never assume arithmetic. Chemistry balances atoms AND
       charge; an essay needs claim→evidence; language needs tense/agreement; biology needs precise concepts.
    3) READ THE PARSED STRUCTURE, not pixels. Refer to lines by {col,line}. Trust the reconstructed order.
    4) NEVER OUT-RUN askDepth. 1 = a single guiding question (no answer). 2 = one hint. 3 = the next step.
       Reveal nothing deeper than askDepth requests.

    Output ONLY valid JSON matching the provided schema. Be concise, warm, and never condescending. If your
    confidence is below the caller's threshold, return null for the content fields and set "confidence". Never
    fabricate; if the page is ambiguous, prefer a question over a guess.
    """

    // MARK: Intents (§6.3)

    enum Intent: String {
        case next_step, check, circle, chat

        /// The literal USER instruction that precedes the envelope for this surface.
        var userPrompt: String {
            switch self {
            case .next_step:
                return """
                Continue the work at `focus`. Return a one-line guiding QUESTION (nudge, no answer), a one-line HINT, \
                and the next STEP as LaTeX. The UI reveals only up to askDepth. For the fill-in ghost, also return \
                `blankToken`: the single token in stepLatex that best proves understanding (it will be masked first).
                """
            case .check:
                return """
                Verify each line in `structure` against the `subject` rubric. Return a verdict per line and the FIRST \
                error only, with a fix in the student's own notation. Lead with one short, genuine piece of praise.
                """
            case .circle:
                return """
                The circled span is attached as an image, with its surrounding context. Reply IN `locale` — \
                match the page's language EXACTLY (a Hebrew page → answer in Hebrew). \
                "explain": a genuinely useful, concrete explanation of what this is and why it matters — specific, \
                up to ~60 words, never vague or a restatement of the term. \
                "simpler": the same idea in the plainest everyday words, ≤ 35 words.
                """
            case .chat:
                return """
                Answer the student's open question using page context. Cite lines as {col,line}. Be Socratic first — \
                prefer a guiding question unless they asked outright. Stay in `locale`. Offer two short follow-up prompts.
                """
            }
        }

        /// Gemini `responseSchema` (OpenAPI subset) for this intent.
        var schema: [String: Any] {
            func obj(_ props: [String: Any], required: [String] = []) -> [String: Any] {
                var s: [String: Any] = ["type": "OBJECT", "properties": props]
                if !required.isEmpty { s["required"] = required }
                return s
            }
            let str: [String: Any] = ["type": "STRING"]
            let strNull: [String: Any] = ["type": "STRING", "nullable": true]
            let num: [String: Any] = ["type": "NUMBER"]
            let int: [String: Any] = ["type": "INTEGER"]
            let bool: [String: Any] = ["type": "BOOLEAN"]
            switch self {
            case .next_step:
                return obj([
                    "intent": str, "nudge": strNull, "hint": strNull, "stepLatex": strNull,
                    "blankToken": strNull, "confidence": num, "value": num
                ], required: ["confidence"])
            case .check:
                let lineVerdict = obj(["line": int, "ok": bool, "confidence": ["type": "NUMBER", "nullable": true]],
                                      required: ["line", "ok"])
                let firstError: [String: Any] = [
                    "type": "OBJECT", "nullable": true,
                    "properties": ["line": int, "why": str, "fixLatex": str, "rubricTag": str],
                    "required": ["line", "why", "fixLatex", "rubricTag"]
                ]
                return obj([
                    "intent": str, "praise": strNull,
                    "lines": ["type": "ARRAY", "items": lineVerdict],
                    "firstError": firstError
                ], required: ["lines"])
            case .circle:
                let quiz: [String: Any] = ["type": "OBJECT", "nullable": true,
                                           "properties": ["q": str, "a": str], "required": ["q", "a"]]
                return obj(["intent": str, "explain": str, "simpler": str, "quiz": quiz],
                           required: ["explain", "simpler"])
            case .chat:
                let citeItem = obj(["col": str, "line": int], required: ["col", "line"])
                return obj([
                    "intent": str, "reply": str,
                    "cite": ["type": "ARRAY", "items": citeItem],
                    "followups": ["type": "ARRAY", "items": str]
                ], required: ["reply"])
            }
        }
    }

    // MARK: Decode targets (§6.3 schemas)

    struct NextStep: Decodable {
        var nudge: String?
        var hint: String?
        var stepLatex: String?
        var blankToken: String?
        var confidence: Double?
        var value: Double?
    }
    struct CheckResult: Decodable {
        struct LineVerdict: Decodable { var line: Int; var ok: Bool; var confidence: Double? }
        struct FirstError: Decodable { var line: Int; var why: String; var fixLatex: String; var rubricTag: String }
        var praise: String?
        var lines: [LineVerdict]
        var firstError: FirstError?
    }
    struct CircleResult: Decodable {
        struct Quiz: Decodable { var q: String; var a: String }
        var explain: String
        var simpler: String
        var analogy: String?
        var quiz: Quiz?
    }
    struct ChatResult: Decodable {
        var reply: String
        var cite: [Anchor]?
        var followups: [String]?
    }

    // MARK: The call

    /// Run a structured tutor call: build the envelope + per-feature user prompt (only
    /// the anchored region crop is attached, never the whole page), constrain to the
    /// schema, and decode tolerantly. Returns nil on a null/below-confidence payload —
    /// the caller then stays silent (§6.4).
    static func call<T: Decodable>(
        _ intent: Intent, envelope: Envelope, region: Data? = nil,
        extra: String? = nil, maxTokens: Int = 1200, as type: T.Type
    ) async throws -> T? {
        let envJSON = encodeEnvelope(envelope)
        var userText = intent.userPrompt + "\n\nENVELOPE:\n" + envJSON
        if let extra, !extra.isEmpty { userText += "\n\n" + extra }

        let raw: String
        if AIConfig.provider == .gemini {
            var content: [AIContent] = [.text(userText)]
            if let region { content.append(.imagePNG(region)) }
            raw = try await GeminiService.sendStructured(
                system: system, messages: [.user(content)], schema: intent.schema,
                maxTokens: maxTokens, temperature: 0.2)
        } else {
            // Providers without a native schema get it enforced through the prompt.
            let augmented = userText + "\n\nOutput ONLY minified JSON matching this schema (no prose, no code fences):\n"
                + jsonString(intent.schema)
            var content: [AIContent] = [.text(augmented)]
            if let region { content.append(.imagePNG(region)) }
            raw = try await AIService.send(system: system, messages: [.user(content)], maxTokens: maxTokens, temperature: 0.2)
        }
        return decode(raw, as: T.self)
    }

    // MARK: JSON helpers

    static func encodeEnvelope(_ envelope: Envelope) -> String {
        guard let data = try? JSONEncoder().encode(envelope),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Decode a (possibly fenced / prose-wrapped / truncated) JSON reply into `T`,
    /// extracting the first `{ … }` object. Returns nil rather than throwing so a
    /// malformed/empty reply just means "stay silent".
    static func decode<T: Decodable>(_ raw: String, as type: T.Type) -> T? {
        var src = raw
        if let f = raw.range(of: "```json", options: .caseInsensitive),
           let c = raw.range(of: "```", range: f.upperBound..<raw.endIndex) {
            src = String(raw[f.upperBound..<c.lowerBound])
        } else if let f = raw.range(of: "```"),
                  let c = raw.range(of: "```", range: f.upperBound..<raw.endIndex) {
            src = String(raw[f.upperBound..<c.lowerBound])
        }
        guard let s = src.firstIndex(of: "{"), let e = src.lastIndex(of: "}"),
              let data = String(src[s...e]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

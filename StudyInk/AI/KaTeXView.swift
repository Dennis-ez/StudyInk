import SwiftUI
import SwiftMath

// Math/markdown rendering for AI responses. Heavy math (fractions, integrals,
// sums, roots, matrices, display math) is typeset in true 2D by SwiftMath's
// MTMathUILabel — a native UIView, no WebView, no WebContent process churn.
// Light inline math (x², a_i, \alpha) folds to unicode and stays in the prose
// flow; **bold**/bullets render through AttributedString markdown.

extension String {
    /// LaTeX → readable unicode for plain-text rendering. Handles delimited math
    /// ($…$, $$…$$, \(…\), \[…\]) AND the bare \cdot / \int / x^{2} the model often
    /// emits undelimited, via InkWriter's LaTeX parser (symbols, \frac, scripts).
    /// Used for the prose blocks and the simpler standalone Text renderers
    /// (guided mode); the rich bubble promotes heavy math to typeset blocks.
    func mathToUnicode() -> String {
        var s = replacingOccurrences(of: "\\$", with: "$")
            .replacingOccurrences(of: "￥", with: "$")
        guard s.contains("$") || s.contains("\\") else { return s }
        for delimiter in ["$$", "$", "\\(", "\\)", "\\[", "\\]"] {
            s = s.replacingOccurrences(of: delimiter, with: " ")
        }
        return InkWriter.plainText(from: s)
    }
}

// MARK: - Message segmentation

/// One piece of an AI message: prose (possibly with light inline math already
/// folded to unicode) or a heavy LaTeX expression to typeset in 2D.
enum MathSegment {
    case text(String)
    case math(latex: String, display: Bool)
}

struct IndexedMathSegment: Identifiable {
    let id: Int
    let segment: MathSegment
}

enum MathSegmenter {
    // Ordered alternation: display $$…$$ (g1) · display \[…\] (g2) ·
    // inline $…$ (g3) · inline \(…\) (g4). dotall so display math may wrap lines.
    private static let pattern =
        "\\$\\$([\\s\\S]+?)\\$\\$" +
        "|\\\\\\[([\\s\\S]+?)\\\\\\]" +
        "|\\$([^$]+?)\\$" +
        "|\\\\\\(([\\s\\S]+?)\\\\\\)"

    private static let regex = try? NSRegularExpression(pattern: pattern)

    /// Heavy constructs read far better typeset in 2D than folded to a line. The
    /// app is math-tutoring, so equations and function-bearing expressions are
    /// typeset too (the chat/steps should show real LaTeX, not folded unicode);
    /// only bare single symbols ($x$, $x^2$) stay inline.
    private static func isComplex(_ latex: String) -> Bool {
        let heavy = ["\\frac", "\\dfrac", "\\tfrac", "\\int", "\\iint", "\\oint",
                     "\\sum", "\\prod", "\\lim", "\\sqrt", "\\binom", "\\begin",
                     "\\matrix", "\\cases", "\\over", "\\partial", "\\\\",
                     // functions / operators / relations — an equation reads better typeset.
                     "=", "\\ln", "\\log", "\\sin", "\\cos", "\\tan", "\\cot",
                     "\\cdot", "\\times", "\\div", "\\to", "\\rightarrow", "\\infty",
                     "\\pi", "\\leq", "\\geq", "\\neq", "\\le", "\\ge", "\\pm",
                     "\\in", "\\cup", "\\cap", "\\Rightarrow"]
        if heavy.contains(where: latex.contains) { return true }
        // Multi-symbol scripts (x^{n+1}, a_{ij}) stack better than inline.
        return latex.contains("^{") || latex.contains("_{")
    }

    /// A heavy expression is only promoted to a typeset block if SwiftMath can
    /// actually parse it — otherwise it falls back to the unicode prose path.
    private static func parses(_ latex: String) -> Bool {
        var error: NSError?
        let list = MTMathListBuilder.build(fromString: latex, error: &error)
        return error == nil && list != nil
    }

    /// Can this LaTeX be typeset in 2D? (Exposes `parses` for standalone renderers.)
    static func typesets(_ latex: String) -> Bool { parses(latex) }

    static func segments(from raw: String) -> [IndexedMathSegment] {
        let s = raw.replacingOccurrences(of: "\\$", with: "$")
            .replacingOccurrences(of: "￥", with: "$")
        guard let regex else { return [IndexedMathSegment(id: 0, segment: .text(s))] }

        let ns = s as NSString
        var out: [MathSegment] = []
        var pending = ""   // prose + folded light inline math, flushed before a block
        var last = 0

        func flushText() {
            if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.text(pending))
            }
            pending = ""
        }

        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                pending += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            }
            last = m.range.location + m.range.length

            let display = m.range(at: 1).location != NSNotFound || m.range(at: 2).location != NSNotFound
            var latex = ""
            for g in 1...4 where m.range(at: g).location != NSNotFound {
                latex = ns.substring(with: m.range(at: g)); break
            }

            if (display || isComplex(latex)), parses(latex) {
                flushText()
                out.append(.math(latex: latex, display: display))
            } else {
                // Light inline math stays in the sentence, folded to unicode.
                pending += InkWriter.plainText(from: latex)
            }
        }
        if last < ns.length { pending += ns.substring(from: last) }
        flushText()

        if out.isEmpty { out = [.text(s)] }
        return out.enumerated().map { IndexedMathSegment(id: $0.offset, segment: $0.element) }
    }
}

// MARK: - Typeset math block (SwiftMath)

/// Renders one LaTeX expression as native 2D math. Wrapped in a horizontal
/// scroller by the caller so a wide equation never clips.
struct MathBlockView: UIViewRepresentable {
    let latex: String
    let display: Bool
    let color: UIColor
    let fontSize: CGFloat

    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.backgroundColor = .clear
        label.displayErrorInline = false
        label.contentInsets = UIEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)
        configure(label)
        return label
    }

    func updateUIView(_ label: MTMathUILabel, context: Context) {
        configure(label)
    }

    private func configure(_ label: MTMathUILabel) {
        label.latex = latex
        label.labelMode = display ? .display : .text
        label.textColor = color
        label.fontSize = fontSize
        label.textAlignment = .left
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: MTMathUILabel, context: Context) -> CGSize? {
        configure(label)
        let size = label.intrinsicContentSize
        return CGSize(width: max(size.width, 1), height: max(size.height, fontSize))
    }
}

/// One LaTeX expression rendered as the AI's "ink" — typeset in 2D when it parses
/// (in the given accent colour), otherwise the unicode-folded text. Used for the
/// on-page next-step preview, which should look like real math, not raw `$...$`.
struct AIInkMath: View {
    let latex: String
    var color: Color
    var fontSize: CGFloat = 20

    var body: some View {
        // Strip any delimiters the model slipped in so SwiftMath sees clean LaTeX.
        let clean = latex
            .replacingOccurrences(of: "$$", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "\\(", with: "").replacingOccurrences(of: "\\)", with: "")
            .replacingOccurrences(of: "\\[", with: "").replacingOccurrences(of: "\\]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if MathSegmenter.typesets(clean) {
            MathBlockView(latex: clean, display: false, color: UIColor(color), fontSize: fontSize)
        } else {
            Text(verbatim: clean.mathToUnicode())
                .font(.fraunces(fontSize, weight: .semibold, relativeTo: .title3).italic())
                .foregroundStyle(color)
        }
    }
}

// MARK: - Rich AI text

/// Rich text for AI answers: prose (markdown + folded inline math) interleaved
/// with typeset 2D math blocks. RTL-aware for Hebrew. No WebView.
struct AIRichText: View {
    let content: String
    @Environment(\.colorScheme) private var colorScheme

    private var rtl: Bool { content.isMostlyRTL }
    private var mathColor: UIColor {
        UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
    }

    var body: some View {
        VStack(alignment: rtl ? .trailing : .leading, spacing: 6) {
            ForEach(MathSegmenter.segments(from: content)) { item in
                switch item.segment {
                case .text(let text):
                    ProseBlock(text: text, rtl: rtl)
                case .math(let latex, let display):
                    ScrollView(.horizontal, showsIndicators: false) {
                        MathBlockView(latex: latex, display: display,
                                      color: mathColor, fontSize: display ? 19 : 17)
                    }
                    .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
    }
}

/// A prose paragraph: bare/inline math folded to unicode, line-start bullets
/// normalised, inline **bold** etc. via AttributedString markdown.
private struct ProseBlock: View {
    let text: String
    let rtl: Bool

    private var attributed: AttributedString {
        var t = text.mathToUnicode()
        t = t.replacingOccurrences(
            of: "(?m)^[ \\t]*[*•\\-][ \\t]+", with: "•  ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: t, options: options)) ?? AttributedString(t)
    }

    var body: some View {
        Text(attributed)
            .font(.subheadline)
            .multilineTextAlignment(rtl ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .textSelection(.enabled)
    }
}

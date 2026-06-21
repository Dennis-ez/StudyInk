import SwiftUI

// Native math/markdown rendering for AI responses. Previously this drove a
// per-message WKWebView (KaTeX) — each spun up a WebContent process (~2–4s to
// launch, leaking on teardown). We now render entirely natively: LaTeX is folded
// to readable unicode via InkWriter's parser (x^2 → x², \frac{a}{b} → a/b,
// \neq → ≠), and **bold** / bullets render through AttributedString markdown.
// No web processes, instant, no leaks.

extension String {
    /// LaTeX ($…$, $$…$$) → readable unicode for plain-text rendering.
    /// Tolerates the markdown-escaped `\$` / fullwidth `￥` delimiters models emit.
    func mathToUnicode() -> String {
        var s = replacingOccurrences(of: "\\$", with: "$")
            .replacingOccurrences(of: "￥", with: "$")
        guard s.contains("$") else { return s }
        // $$…$$ (display, may span lines) first, then $…$ (inline, single line).
        for pattern in ["\\$\\$([\\s\\S]*?)\\$\\$", "\\$([^$\\n]*?)\\$"] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let full = Range(m.range, in: s),
                      let inner = Range(m.range(at: 1), in: s) else { continue }
                s.replaceSubrange(full, with: InkWriter.plainText(from: String(s[inner])))
            }
        }
        return s.replacingOccurrences(of: "$", with: "")
    }
}

/// Rich text for AI answers: native SwiftUI `Text` with math folded to unicode and
/// **bold**/bullets via markdown. RTL-aware for Hebrew. No WebView.
struct AIRichText: View {
    let content: String

    private var attributed: AttributedString {
        // 1) math → unicode, 2) line-start bullets → •, 3) inline markdown.
        var text = content.mathToUnicode()
        text = text.replacingOccurrences(
            of: "(?m)^[ \\t]*[*•\\-][ \\t]+", with: "•  ", options: .regularExpression)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        Text(attributed)
            .font(.subheadline)
            .multilineTextAlignment(content.isMostlyRTL ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: content.isMostlyRTL ? .trailing : .leading)
            .environment(\.layoutDirection, content.isMostlyRTL ? .rightToLeft : .leftToRight)
            .textSelection(.enabled)
    }
}

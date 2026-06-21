import SwiftUI

// Native math/markdown rendering for AI responses. Previously this drove a
// per-message WKWebView (KaTeX) — each spun up a WebContent process (~2–4s to
// launch, leaking on teardown). We now render entirely natively: LaTeX is folded
// to readable unicode via InkWriter's parser (x^2 → x², \frac{a}{b} → a/b,
// \neq → ≠), and **bold** / bullets render through AttributedString markdown.
// No web processes, instant, no leaks.

extension String {
    /// LaTeX → readable unicode for plain-text rendering. Handles delimited math
    /// ($…$, $$…$$, \(…\), \[…\]) AND the bare \cdot / \int / x^{2} the model often
    /// emits undelimited, via InkWriter's LaTeX parser (symbols, \frac, scripts).
    func mathToUnicode() -> String {
        // Unescape the markdown-escaped \$ / fullwidth ￥ delimiters models emit,
        // then drop ALL math delimiters so the parser sees clean LaTeX.
        var s = replacingOccurrences(of: "\\$", with: "$")
            .replacingOccurrences(of: "￥", with: "$")
        guard s.contains("$") || s.contains("\\") else { return s }
        for delimiter in ["$$", "$", "\\(", "\\)", "\\[", "\\]"] {
            s = s.replacingOccurrences(of: delimiter, with: " ")
        }
        // Convert the whole thing (prose passes through untouched; only LaTeX
        // commands/braces/scripts are interpreted).
        return InkWriter.plainText(from: s)
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

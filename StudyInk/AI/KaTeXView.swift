import SwiftUI
import WebKit

/// Renders mixed text + LaTeX via KaTeX in a WKWebView. CSS variables switch with
/// the app appearance (dark canvas text vs. light), injected at load and on change.
struct KaTeXView: UIViewRepresentable {
    let content: String
    var isRTL = false
    @Binding var contentHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    /// One shared web-content process for ALL KaTeX views. Without it every math
    /// bubble spun up its OWN WebContent process (each ~2–4s to launch, and they
    /// leaked on teardown). Sharing the pool collapses that to a single process.
    private static let sharedPool = WKProcessPool()

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = Self.sharedPool
        config.userContentController.add(context.coordinator, name: "height")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.markLoaded(content: content, dark: colorScheme == .dark)
        load(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Record what we're loading *before* kicking it off — recording only on
        // didFinish meant every re-render mid-load restarted the load forever.
        if context.coordinator.lastContent != content || context.coordinator.lastDark != (colorScheme == .dark) {
            context.coordinator.markLoaded(content: content, dark: colorScheme == .dark)
            load(into: webView)
        }
    }

    private func load(into webView: WKWebView) {
        let dark = colorScheme == .dark
        let textColor = dark ? "#FFFFFF" : "#000000"
        // Models (Gemini especially) often emit markdown-escaped delimiters like
        // \$x\$ — KaTeX's auto-render doesn't treat those as math, so normalize
        // them back to plain $ before shipping the text to the web view.
        let normalized = content
            .replacingOccurrences(of: "\\$", with: "$")
            .replacingOccurrences(of: "￥", with: "$")
        let escaped = normalized
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let html = """
        <!DOCTYPE html><html dir="\(isRTL ? "rtl" : "ltr")"><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
        <style>
          :root { color-scheme: \(dark ? "dark" : "light"); }
          body {
            margin: 0; padding: 2px;
            font: -apple-system-body; font-size: 15px;
            color: \(textColor); background: transparent;
            direction: \(isRTL ? "rtl" : "ltr");
            overflow-wrap: break-word;
          }
          .katex { font-size: 1.05em; }
        </style></head><body><div id="c"></div>
        <script>
          const raw = `\(escaped)`;
          // Minimal markdown: HTML-escape first, then bold / bullets / breaks.
          // Math delimiters pass through untouched for KaTeX's auto-render.
          let html = raw
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/\\*\\*([^*\\n]+)\\*\\*/g, '<b>$1</b>')
            .replace(/(^|\\n)[ \\t]*[*•-][ \\t]+/g, '$1&bull; ')
            .replace(/\\n/g, '<br>');
          document.getElementById('c').innerHTML = html;
          window.addEventListener('load', () => {
            renderMathInElement(document.getElementById('c'), {
              delimiters: [
                {left: '$$', right: '$$', display: true},
                {left: '\\\\[', right: '\\\\]', display: true},
                {left: '$', right: '$', display: false},
                {left: '\\\\(', right: '\\\\)', display: false}
              ],
              throwOnError: false
            });
            window.webkit.messageHandlers.height.postMessage(document.body.scrollHeight);
          });
        </script></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let parent: KaTeXView
        private(set) var lastContent: String = ""
        private(set) var lastDark = false

        init(_ parent: KaTeXView) { self.parent = parent }

        func markLoaded(content: String, dark: Bool) {
            lastContent = content
            lastDark = dark
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "height", let height = message.body as? CGFloat {
                DispatchQueue.main.async {
                    let clamped = max(height, 20)
                    // Ignore sub-point jitter so height updates can't ping-pong layout.
                    if abs(self.parent.contentHeight - clamped) > 1 {
                        self.parent.contentHeight = clamped
                    }
                }
            }
        }
    }
}

/// Drop-in rich text view: plain SwiftUI Text normally, KaTeX WebView when the
/// content carries LaTeX. Handles RTL alignment for Hebrew responses.
struct AIRichText: View {
    let content: String
    @State private var height: CGFloat = 24

    var body: some View {
        if content.containsLaTeX {
            KaTeXView(content: content, isRTL: content.isMostlyRTL, contentHeight: $height)
                .frame(height: height)
        } else {
            Text(content)
                .font(.subheadline)
                .multilineTextAlignment(content.isMostlyRTL ? .trailing : .leading)
                .frame(maxWidth: .infinity, alignment: content.isMostlyRTL ? .trailing : .leading)
                .environment(\.layoutDirection, content.isMostlyRTL ? .rightToLeft : .leftToRight)
        }
    }
}

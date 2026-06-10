import SwiftUI
import WebKit

/// Renders mixed text + LaTeX via KaTeX in a WKWebView. CSS variables switch with
/// the app appearance (dark canvas text vs. light), injected at load and on change.
struct KaTeXView: UIViewRepresentable {
    let content: String
    var isRTL = false
    @Binding var contentHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "height")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        load(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastContent != content || context.coordinator.lastDark != (colorScheme == .dark) {
            load(into: webView)
        }
    }

    private func load(into webView: WKWebView) {
        let dark = colorScheme == .dark
        let textColor = dark ? "#FFFFFF" : "#000000"
        let escaped = content
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
          document.getElementById('c').innerText = raw;
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
        Coordinator.pending[ObjectIdentifier(webView)] = (content, dark)
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static var pending: [ObjectIdentifier: (String, Bool)] = [:]
        let parent: KaTeXView
        var lastContent: String = ""
        var lastDark = false

        init(_ parent: KaTeXView) { self.parent = parent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "height", let height = message.body as? CGFloat {
                DispatchQueue.main.async { self.parent.contentHeight = max(height, 20) }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let (content, dark) = Self.pending.removeValue(forKey: ObjectIdentifier(webView)) {
                lastContent = content
                lastDark = dark
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

import AppKit
import SwiftUI
import WebKit

enum MathTextSupport {
    static func containsMath(_ text: String) -> Bool {
        if text.contains("$") { return true }
        if text.contains("\\(") || text.contains("\\[") { return true }
        if text.contains("\\begin{") { return true }
        return false
    }
}

/// A `WKWebView` that never swallows scroll gestures: the rendered content
/// fits its frame, so wheel/trackpad events are forwarded to the enclosing
/// SwiftUI `ScrollView`. Without this, hovering over a maths reply (which
/// renders in a web view) blocks scrolling of the agent transcript.
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// Renders markdown with LaTeX math (via MathJax) inside a `WKWebView` and
/// reports its own height so it can sit in normal SwiftUI layout.
struct MathTextView: NSViewRepresentable {
    let markdown: String
    var fontSize: CGFloat = 14
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "height")
        configuration.userContentController = controller

        let webView = PassthroughWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear

        context.coordinator.webView = webView
        context.coordinator.render(markdown: markdown, fontSize: fontSize)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.heightBinding = $height
        if context.coordinator.renderedMarkdown != markdown || context.coordinator.renderedFontSize != fontSize {
            context.coordinator.render(markdown: markdown, fontSize: fontSize)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var heightBinding: Binding<CGFloat>
        private(set) var renderedMarkdown = ""
        private(set) var renderedFontSize: CGFloat = 14
        weak var webView: WKWebView?

        init(height: Binding<CGFloat>) {
            self.heightBinding = height
        }

        func render(markdown: String, fontSize: CGFloat) {
            renderedMarkdown = markdown
            renderedFontSize = fontSize
            webView?.loadHTMLString(Self.html(markdown: markdown, fontSize: fontSize), baseURL: nil)
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.name == "height", let value = message.body as? NSNumber else { return }
            let newHeight = CGFloat(truncating: value)
            guard newHeight > 0 else { return }
            DispatchQueue.main.async { [heightBinding] in
                if abs(heightBinding.wrappedValue - newHeight) > 0.5 {
                    heightBinding.wrappedValue = newHeight
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        static func html(markdown: String, fontSize: CGFloat) -> String {
            let encoded = jsonString(markdown)
            return """
                <!doctype html>
                <html><head><meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <style>
                :root { color-scheme: light dark; }
                html, body { background: transparent; overflow: hidden; }
                body { margin: 0; padding: 0; font-family: -apple-system, system-ui, sans-serif; font-size: \(Int(fontSize))px; line-height: 1.45; color: CanvasText; overflow-wrap: break-word; }
                #content > *:first-child { margin-top: 0; }
                #content > *:last-child { margin-bottom: 0; }
                p { margin: 0.4em 0; }
                ul, ol { margin: 0.4em 0; padding-left: 1.3em; }
                h1, h2, h3, h4 { margin: 0.6em 0 0.3em; }
                pre { background: rgba(127,127,127,0.15); padding: 8px 10px; border-radius: 6px; overflow-x: auto; }
                code { font-family: ui-monospace, Menlo, monospace; font-size: 0.92em; }
                pre code { font-size: 0.9em; }
                a { color: -webkit-link; }
                </style>
                <script>
                window.MathJax = {
                  tex: { inlineMath: [['$','$']], displayMath: [['$$','$$']] },
                  svg: { fontCache: 'global' },
                  options: { skipHtmlTags: ['script','noscript','style','textarea','pre','code'] }
                };
                </script>
                <script src="https://cdn.jsdelivr.net/npm/marked@12/marked.min.js"></script>
                <script src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg.js"></script>
                </head>
                <body>
                <div id="content"></div>
                <script>
                (function () {
                  const md = \(encoded);
                  const el = document.getElementById('content');
                  function escapeHtml(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
                  try { el.innerHTML = window.marked ? marked.parse(md) : escapeHtml(md); }
                  catch (e) { el.textContent = md; }
                  function report() { try { window.webkit.messageHandlers.height.postMessage(document.body.scrollHeight); } catch (e) {} }
                  function run() {
                    if (window.MathJax && MathJax.typesetPromise) { MathJax.typesetPromise([el]).then(report).catch(report); }
                    else { report(); }
                  }
                  run();
                  setTimeout(report, 400);
                  setTimeout(report, 1200);
                  window.addEventListener('resize', report);
                })();
                </script>
                </body></html>
                """
        }

        static func jsonString(_ value: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
            guard let data, var string = String(data: data, encoding: .utf8) else { return "\"\"" }
            string.removeFirst()
            string.removeLast()
            return string
        }
    }
}

/// Text that renders markdown with LaTeX math when present, otherwise falls
/// back to the lightweight native renderer.
struct MathOrMarkdown: View {
    let markdown: String
    @State private var height: CGFloat = 18

    var body: some View {
        if MathTextSupport.containsMath(markdown) {
            MathTextView(markdown: markdown, height: $height)
                .frame(height: max(height, 1))
        } else {
            MarkdownText(text: markdown)
        }
    }
}

/// Text that renders LaTeX math when present, otherwise plain (optionally
/// centred) text at a chosen size.
struct MathOrText: View {
    let markdown: String
    var fontSize: CGFloat = 14
    var alignment: TextAlignment = .leading
    @State private var height: CGFloat = 18

    var body: some View {
        if MathTextSupport.containsMath(markdown) {
            MathTextView(markdown: markdown, fontSize: fontSize, height: $height)
                .frame(height: max(height, 1))
        } else {
            Text(markdown)
                .font(.system(size: fontSize))
                .multilineTextAlignment(alignment)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        }
    }
}

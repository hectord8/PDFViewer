import SwiftUI
import WebKit

struct LectureTranscriptInfo {
    let lessonID: String?
    let mediaID: String?
    let panelText: String?
    let pageTitle: String?
    let audioURLs: [String]
}

/// Owns the WKWebView so the portal can drive navigation, read cookies, and
/// query the page for transcript/media information.
@MainActor
final class LectureWebController: ObservableObject {
    weak var webView: WKWebView?

    var currentURL: URL? { webView?.url }

    func load(_ url: URL) {
        guard let webView, webView.url?.absoluteString != url.absoluteString else { return }
        webView.load(URLRequest(url: url))
    }

    func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    func openTranscriptPanel() async {
        guard let webView else { return }
        _ = try? await webView.evaluateJavaScript(Self.openTranscriptScript)
    }

    func transcriptInfo() async -> LectureTranscriptInfo? {
        guard let webView else { return nil }
        do {
            guard let raw = try await webView.evaluateJavaScript(Self.transcriptInfoScript) as? String,
                let data = raw.data(using: .utf8),
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            return LectureTranscriptInfo(
                lessonID: object["lesson"] as? String,
                mediaID: object["media"] as? String,
                panelText: object["panel"] as? String,
                pageTitle: object["title"] as? String,
                audioURLs: object["audio"] as? [String] ?? []
            )
        } catch {
            return nil
        }
    }

    func pageTitle() async -> String? {
        guard let webView else { return nil }
        return try? await webView.evaluateJavaScript("document.title") as? String
    }

    func seek(to seconds: TimeInterval) {
        let script = """
            (() => {
              const video = document.querySelector('video');
              if (video) {
                video.currentTime = \(String(format: "%.2f", seconds));
                video.play();
                return true;
              }
              return false;
            })()
            """
        webView?.evaluateJavaScript(script)
    }

    private static let openTranscriptScript = #"""
        (() => {
          const nodes = [...document.querySelectorAll('button, a, [role="button"]')];
          const button = nodes.find(node =>
            /transcript/i.test((node.innerText || '') + ' ' + (node.getAttribute('aria-label') || '')));
          if (button) {
            button.click();
            return true;
          }
          return false;
        })()
        """#

    private static let transcriptInfoScript = #"""
        (() => {
          const resources = performance.getEntriesByType('resource').map(entry => entry.name);
          let lesson = null;
          let media = null;
          for (const url of resources) {
            const match = url.match(/lessons\/([^/]+)\/medias\/([^/]+)/);
            if (match) {
              lesson = match[1];
              media = match[2];
              break;
            }
          }
          if (!lesson) {
            const match = location.pathname.match(/lessons?\/([^/]+)/);
            if (match) lesson = match[1];
          }
          const panel = document.querySelector('[class*="transcript" i], [id*="transcript" i]');
          const audio = resources.filter(url => /\.(m3u8|mp4|m4a|mp3)(\?|$)/.test(url));
          return JSON.stringify({
            lesson,
            media,
            panel: panel ? panel.innerText : null,
            title: document.title,
            audio
          });
        })()
        """#
}

struct LectureWebView: NSViewRepresentable {
    let url: URL
    let controller: LectureWebController

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        controller.webView = webView
        context.coordinator.lastRequestedURL = url.absoluteString
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        controller.webView = webView
        // Only reload when the selected lesson changes. Echo360 redirects to SSO
        // and the player URL changes during normal use; comparing webView.url
        // would reload the lesson on every SwiftUI update and break sign-in.
        guard context.coordinator.lastRequestedURL != url.absoluteString else { return }
        context.coordinator.lastRequestedURL = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastRequestedURL: String?
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

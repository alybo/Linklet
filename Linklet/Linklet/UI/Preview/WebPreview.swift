import SwiftUI
import WebKit

struct WebPreview: NSViewRepresentable {
    @ObservedObject var session: PreviewSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = session.websiteDataStore
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Let WebKit own scrolling, including macOS preferences and site CSS.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.startObserving(webView)
        session.attach(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // WKWebView is the source of truth. KVO and navigation delegate callbacks
        // below synchronize real changes; writing ObservableObject state from this
        // render callback would create a SwiftUI update loop.
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private weak var session: PreviewSession?
        private var observations: [NSKeyValueObservation] = []

        init(session: PreviewSession) {
            self.session = session
        }

        func startObserving(_ webView: WKWebView) {
            observations = [
                webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                    self?.synchronize(webView)
                },
                webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                    self?.synchronize(webView)
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                    self?.synchronize(webView)
                },
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                    self?.synchronize(webView)
                },
                webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                    self?.synchronize(webView)
                },
                webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                    self?.synchronize(webView)
                }
            ]
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            Task { @MainActor [weak self] in
                self?.session?.synchronize(from: webView)
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
            Task { @MainActor [weak self] in
                self?.session?.navigationDidCommit(in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            synchronize(webView)
            session?.welcomeDidFinish()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: Error
        ) {
            report(error, webView: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            report(error, webView: webView)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard session?.webView === webView else { return nil }
            if navigationAction.targetFrame == nil,
               URLPolicy.canPreview(navigationAction.request.url ?? URL(fileURLWithPath: "/")) {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard session?.webView === webView else {
                decisionHandler(.cancel)
                return
            }
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if session?.isWelcome == true {
                if url.absoluteString == "linklet-welcome://settings",
                   session?.canOpenWelcomeSettings(from: webView, isMainFrame: navigationAction.sourceFrame.isMainFrame) == true,
                   navigationAction.navigationType == .linkActivated {
                    session?.onOpenSettings?()
                }
                decisionHandler(url.absoluteString == "about:blank" ? .allow : .cancel)
                return
            }
            // Never forward the internal welcome command to another app or website.
            if url.scheme == "linklet-welcome" {
                decisionHandler(.cancel)
                return
            }

            if URLPolicy.canPreview(url) || url.scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)
            }
        }

        func synchronize(_ webView: WKWebView) {
            Task { @MainActor [weak self] in
                self?.session?.synchronize(from: webView)
            }
        }

        private func report(_ error: Error, webView: WKWebView) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            Task { @MainActor [weak self] in
                guard self?.session?.webView === webView else { return }
                self?.session?.navigationDidFail(in: webView)
                self?.session?.errorMessage = error.localizedDescription
            }
        }
    }
}

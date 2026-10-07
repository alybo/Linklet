import SwiftUI
import WebKit

struct WebPreview: NSViewRepresentable {
    @ObservedObject var session: PreviewSession

    static func configuration(websiteDataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.preferences.isElementFullscreenEnabled = true
        // OAuth SDKs often open a blank child and navigate it after async work.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Preserve WebKit's native Macintosh/engine tokens and add Safari's
        // browser identity. Generic WKWebView UA lacks these tokens, so sites
        // such as Google may fall back to an unsupported-browser/basic page.
        let safariVersion = Bundle(url: URL(fileURLWithPath: "/Applications/Safari.app"))?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "17.0"
        configuration.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        return configuration
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = Self.configuration(websiteDataStore: session.websiteDataStore)
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

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.closePopupWindows()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private weak var session: PreviewSession?
        private var observations: [NSKeyValueObservation] = []
        private(set) var popupWindows: [UUID: WebPopupWindowController] = [:]
        var onWebViewClose: (() -> Void)?

        init(session: PreviewSession) {
            self.session = session
        }

        func startObserving(_ webView: WKWebView) {
            session?.onCloseAuxiliaryWindows = { [weak self] in self?.closePopupWindows() }
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
            session?.pageDidFinish(in: webView)
            if let session, session.webView === webView, !session.isWelcome, session.siteData.isEnabled {
                Task { @MainActor in await session.siteData.refresh() }
            }
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
            guard let session, session.webView === webView, !session.isWelcome,
                  navigationAction.targetFrame == nil,
                  Self.canCreatePopup(for: navigationAction.request.url) else { return nil }
            // Normal target=_blank links belong to the existing preview, with its toolbar,
            // back/forward history and original browser handoff. Script/POST windows keep
            // their supplied WebKit configuration and opener for sign-in workflows.
            if Self.opensInCurrentPreview(navigationType: navigationAction.navigationType,
                                          request: navigationAction.request, features: windowFeatures) {
                webView.load(navigationAction.request)
                return nil
            }
            guard popupWindows.count < 8 else { return nil }
            return createPopup(configuration: configuration, parent: session, features: windowFeatures).webView
        }

        static func opensInCurrentPreview(navigationType: WKNavigationType, request: URLRequest,
                                          features: WKWindowFeatures) -> Bool {
            navigationType == .linkActivated && request.url.map(URLPolicy.canPreview) == true &&
                (request.httpMethod ?? "GET").uppercased() == "GET" &&
                features.width == nil && features.height == nil && features.x == nil && features.y == nil
        }

        static func canCreatePopup(for url: URL?) -> Bool {
            guard let url else { return true } // window.open() starts with about:blank.
            return URLPolicy.canPreview(url) || url.absoluteString == "about:blank"
        }

        @discardableResult
        private func createPopup(configuration: WKWebViewConfiguration, parent: PreviewSession, features: WKWindowFeatures) -> WebPopupWindowController {
            let id = UUID()
            let popup = WebPopupWindowController(configuration: configuration, parent: parent, features: features)
            popup.onClose = { [weak self] in self?.popupWindows.removeValue(forKey: id) }
            popupWindows[id] = popup
            popup.present()
            return popup
        }

        func closePopupWindows() {
            let windows = Array(popupWindows.values)
            popupWindows.removeAll()
            windows.forEach { $0.close() }
        }

        func webViewDidClose(_ webView: WKWebView) {
            guard session?.webView === webView else { return }
            onWebViewClose?()
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            presentDialog(webView, message: message, frame: frame, confirm: false) { _ in completionHandler() }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            presentDialog(webView, message: message, frame: frame, confirm: true, completion: completionHandler)
        }

        private func presentDialog(_ webView: WKWebView, message: String, frame: WKFrameInfo,
                                   confirm: Bool, completion: @escaping (Bool) -> Void) {
            guard session?.webView === webView, let window = webView.window else { completion(false); return }
            let alert = NSAlert()
            alert.messageText = frame.securityOrigin.host
            alert.informativeText = message
            alert.addButton(withTitle: L("OK"))
            if confirm { alert.addButton(withTitle: L("Cancel")) }
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
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

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard session?.webView === webView else { decisionHandler(.cancel); return }
            if navigationResponse.isForMainFrame,
               let response = navigationResponse.response as? HTTPURLResponse, response.statusCode == 403 {
                session?.errorMessage = L("This website refused access. If sign-in is blocked, continue in your chosen browser from the original site link.")
            }
            decisionHandler(.allow)
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

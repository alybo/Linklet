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
        coordinator.cancelFileUpload()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private weak var session: PreviewSession?
        private var observations: [NSKeyValueObservation] = []
        var popupWindows: [UUID: WebPopupWindowController] {
            guard let session else { return [:] }
            return session.windowRegistry.webWindows(openedBy: session.windowID)
        }
        var onWebViewClose: (() -> Void)?
        // Test seams keep real WebKit file selection and policy callbacks while
        // choosing temporary files without sending them to an external service.
        var makeFileUploadPanel: () -> NSOpenPanel = { NSOpenPanel() }
        var openExternalURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
        private var fileUpload: FileUploadRequest?

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
            cancelFileUpload()
            Task { @MainActor [weak self] in
                if self?.session?.webView === webView { self?.session?.pageFind.navigationStarted() }
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
            // A new browsing context is an independent window, just as a browser
            // creates a tab. WebKit loads the supplied request exactly once.
            guard popupWindows.count < 8 else { return nil }
            return createPopup(configuration: configuration, parent: session, features: windowFeatures).webView
        }

        static func canCreatePopup(for url: URL?) -> Bool {
            guard let url else { return true } // window.open() starts with about:blank.
            return URLPolicy.canPreview(url) || url.absoluteString == "about:blank"
        }

        @discardableResult
        private func createPopup(configuration: WKWebViewConfiguration, parent: PreviewSession, features: WKWindowFeatures) -> WebPopupWindowController {
            let popup = parent.makePopup?(configuration, parent, features)
                ?? WebPopupWindowController(configuration: configuration, parent: parent, features: features)
            parent.windowRegistry.retain(popup)
            popup.present()
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            guard session?.webView === webView else { return }
            cancelFileUpload()
            onWebViewClose?()
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            cancelFileUpload()
            guard let session, session.webView === webView, session.isActive, !session.isWelcome,
                  let window = webView.window, window.attachedSheet == nil else {
                completionHandler(nil)
                return
            }
            let panel = makeFileUploadPanel()
            panel.title = parameters.allowsDirectories ? L("Upload folder") : L("Upload files")
            panel.prompt = L("Choose")
            panel.message = L("Choose files to share with %@.", Self.uploadOrigin(frame.securityOrigin))
            panel.canChooseFiles = !parameters.allowsDirectories
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canCreateDirectories = false
            let request = FileUploadRequest(panel: panel, completion: completionHandler)
            fileUpload = request
            request.closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in self?.cancelFileUpload() }
            panel.beginSheetModal(for: window) { [weak self, weak session, weak webView, request] response in
                let valid = self?.fileUpload === request && session?.webView === webView
                    && session?.isActive == true && session?.isWelcome == false
                if self?.fileUpload === request { self?.fileUpload = nil }
                let urls = request.panel.urls
                request.resolve(response == .OK && valid && !urls.isEmpty && urls.allSatisfy(\.isFileURL) ? urls : nil)
            }
        }

        private static func uploadOrigin(_ origin: WKSecurityOrigin) -> String {
            var components = URLComponents()
            components.scheme = origin.protocol
            components.host = origin.host
            if origin.port != 0 { components.port = origin.port }
            return components.string ?? origin.host
        }

        func cancelFileUpload() {
            guard let request = fileUpload else { return }
            fileUpload = nil
            // Resolve first: ending the sheet can deliver its completion later.
            request.resolve(nil)
            if let parent = request.panel.sheetParent {
                parent.endSheet(request.panel, returnCode: .cancel)
                request.panel.orderOut(nil)
            } else { request.panel.cancel(nil) }
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

            if navigationAction.shouldPerformDownload,
               URLPolicy.canPreview(url) || ["blob", "data"].contains(url.scheme?.lowercased() ?? "") {
                decisionHandler(.download)
            } else if URLPolicy.canPreview(url) || url.scheme == "about" {
                decisionHandler(.allow)
            } else if url.isFileURL {
                // A drop outside a file input/drop zone must not open a local
                // file in another application or replace the website with it.
                decisionHandler(.cancel)
            } else {
                decisionHandler(.cancel)
                openExternalURL(url)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard session?.webView === webView else { decisionHandler(.cancel); return }
            let attachment = (navigationResponse.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")?
                .split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment"
            if attachment || !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
                return
            }
            if navigationResponse.isForMainFrame,
               let response = navigationResponse.response as? HTTPURLResponse, response.statusCode == 403 {
                session?.errorMessage = L("This website refused access. If sign-in is blocked, continue in your chosen browser from the original site link.")
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            adopt(download, in: webView)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            adopt(download, in: webView)
        }

        // macOS WebKit uses this separate ObjC delegate hook for native menu
        // downloads (images, links and media), not the navigation callbacks above.
        // It is WebKit SPI; see DOWNLOADS-LOCAL-TEST.md for the compatibility note.
        @objc(_webView:contextMenuDidCreateDownload:)
        func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
            adopt(download, in: webView, updatesNavigation: false)
        }

        private func adopt(_ download: WKDownload, in view: WKWebView, updatesNavigation: Bool = true) {
            guard let session, session.webView === view, !session.isWelcome else { download.cancel(nil); return }
            session.windowRegistry.downloads.adopt(download, from: session)
            if updatesNavigation { session.navigationBecameDownload(in: view) }
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

@MainActor
private final class FileUploadRequest {
    let panel: NSOpenPanel
    var closeObserver: NSObjectProtocol?
    private var completion: (([URL]?) -> Void)?

    init(panel: NSOpenPanel, completion: @escaping ([URL]?) -> Void) {
        self.panel = panel
        self.completion = completion
    }

    func resolve(_ urls: [URL]?) {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        let handler = completion
        completion = nil
        handler?(urls)
    }
}

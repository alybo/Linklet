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
        PageFindHighlighter.shared.install(in: configuration.userContentController)
        PreviewPageStateBridge.shared.install(in: configuration.userContentController)
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
        coordinator.stopCursorHandling()
        coordinator.cancelFileUpload()
        coordinator.cancelMediaPermissions(webView)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private weak var session: PreviewSession?
        private var observations: [NSKeyValueObservation] = []
        private var activeNavigation: WKNavigation?
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
        private var cursorMonitor: Any?
        private weak var cursorOwner: NSWindow?

        /// Native hosting/field-editor cursor rectangles can cover WKWebView.
        /// WebKit refuses CSS cursor updates while AppKit owns such a rectangle.
        /// Yield rectangles only while the pointer hits this live web content;
        /// native address/find fields and resize edges retain normal behavior.
        private func updateCursorOwnership(in view: WKWebView, at location: NSPoint) {
            guard let window = view.window, session?.webView === view, session?.isActive == true,
                  let content = window.contentView, let hit = content.hitTest(content.convert(location, from: nil)),
                  hit === view || hit.isDescendant(of: view) else { restoreCursorRects(); return }
            if cursorOwner !== window {
                restoreCursorRects()
                if window.areCursorRectsEnabled {
                    window.disableCursorRects()
                    cursorOwner = window
                }
            }
            window.acceptsMouseMovedEvents = true
        }

        private func restoreCursorRects() {
            cursorOwner?.enableCursorRects()
            cursorOwner = nil
        }

        func stopCursorHandling() {
            if let cursorMonitor { NSEvent.removeMonitor(cursorMonitor) }
            cursorMonitor = nil
            restoreCursorRects()
        }

        init(session: PreviewSession) {
            self.session = session
        }

        deinit {
            if let cursorMonitor { NSEvent.removeMonitor(cursorMonitor) }
            cursorOwner?.enableCursorRects()
        }

        func cancelMediaPermissions(_ view: WKWebView) { session?.siteData.mediaPermissions.detach(view) }

        // WebKit's macOS menu-customization delegate is SPI. Preserve every
        // native link/image/download command and append only our site action.
        @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
        func webView(_ view: WKWebView, getContextMenuFromProposedMenu menu: NSMenu,
                     forElement element: AnyObject, userInfo: AnyObject?, completionHandler: @escaping (NSMenu) -> Void) {
            appendAdGuardItem(to: menu, in: view)
            completionHandler(menu)
        }

        func appendAdGuardItem(to menu: NSMenu, in view: WKWebView) {
            guard let session, session.isActive, !session.isWelcome, session.webView === view,
                  let url = view.url, URLPolicy.canPreview(url) else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: L(session.adBlockService.isEnabled(for: url) ? "Turn Off AdGuard" : "Turn On AdGuard"),
                                  action: #selector(toggleAdGuard(_:)), keyEquivalent: "")
            item.target = self
            // Never let an old open menu toggle a different document/site.
            item.representedObject = url
            menu.addItem(item)
        }

        @objc private func toggleAdGuard(_ item: NSMenuItem) {
            guard let session, let url = item.representedObject as? URL, session.webView?.url == url else { return }
            session.toggleAdGuard()
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            guard let session, session.isActive, !session.isWelcome, session.webView === webView else {
                decisionHandler(.deny); return
            }
            session.siteData.mediaPermissions.request(in: webView, origin: origin, frame: frame,
                                                     type: type, reply: decisionHandler)
        }

        @available(macOS 27.0, *)
        func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            guard let session, session.isActive, !session.isWelcome, session.webView === webView else {
                decisionHandler(.deny); return
            }
            guard NativeLocationProvider.install(in: webView.configuration.processPool) else {
                session.errorMessage = L("This WebKit version cannot provide location to websites.")
                decisionHandler(.deny); return
            }
            session.siteData.mediaPermissions.requestLocation(in: webView, origin: origin, frame: frame, reply: decisionHandler)
        }

        func startObserving(_ webView: WKWebView) {
            if #available(macOS 27.0, *) { _ = NativeLocationProvider.install(in: webView.configuration.processPool) }
            stopCursorHandling()
            cursorMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .mouseEntered, .mouseExited]) { [weak self, weak webView] event in
                guard let self, let webView else { return event }
                if event.window === webView.window {
                    self.updateCursorOwnership(in: webView, at: event.locationInWindow)
                } else { self.restoreCursorRects() }
                return event
            }
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
            activeNavigation = navigation
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(navigation) else { return }
                self.session?.navigationDidStart(in: webView)
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(navigation) else { return }
                self.session?.navigationDidCommit(in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard isCurrent(navigation) else { return }
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
            report(error, webView: webView, navigation: navigation)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            report(error, webView: webView, navigation: navigation)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            cancelFileUpload()
            session?.webContentProcessDidTerminate(in: webView)
        }

        private func isCurrent(_ navigation: WKNavigation?) -> Bool {
            guard let navigation, let activeNavigation else { return true }
            return navigation === activeNavigation
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
            guard let url else { return true }
            // WebKit represents window.open("", "_blank") as an empty URL.
            // Payment flows keep that blank window's handle, then navigate it
            // once their asynchronous checkout request returns.
            return url.absoluteString.isEmpty || url.absoluteString == "about:blank" || URLPolicy.canPreview(url)
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
                if navigationAction.targetFrame?.isMainFrame == true {
                    session?.prepareNavigation(navigationAction.request, in: webView)
                }
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
            // HTTP error documents belong to the website; render their content.
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

        private func report(_ error: Error, webView: WKWebView, navigation: WKNavigation?) {
            let nsError = error as NSError
            guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled),
                  !(nsError.domain == "WebKitErrorDomain" && nsError.code == 102) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(navigation), self.session?.webView === webView else { return }
                self.session?.navigationDidFail(in: webView, error: nsError)
            }
        }
    }
}

/// Main-frame scroll state lives in an isolated world, without changing page
/// history/selection or copying forms, cookies or DOM content into our history.
@MainActor
final class PreviewPageStateBridge: NSObject, WKScriptMessageHandler {
    static let shared = PreviewPageStateBridge()
    static let world = WKContentWorld.world(name: "Linklet.PagePosition")
    private let installed = NSHashTable<WKUserContentController>.weakObjects()
    private let owners = NSMapTable<WKWebView, PreviewSession>.weakToWeakObjects()

    func install(in controller: WKUserContentController) {
        guard !installed.contains(controller) else { return }
        installed.add(controller)
        controller.add(self, contentWorld: Self.world, name: "linkletPagePosition")
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: Self.world))
    }

    func attach(_ view: WKWebView, session: PreviewSession) {
        install(in: view.configuration.userContentController)
        owners.setObject(session, forKey: view)
    }
    func detach(_ view: WKWebView) { owners.removeObject(forKey: view) }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let view = message.webView,
              let session = owners.object(forKey: view), let data = message.body as? [String: Any],
              let address = data["url"] as? String, let url = URL(string: address),
              let x = data["x"] as? Double, let y = data["y"] as? Double else { return }
        session.receivePosition(PagePosition(x: x, y: y), for: url, in: view,
                                restoring: data["restoring"] as? Bool == true)
    }

    func capture(in view: WKWebView) {
        view.callAsyncJavaScript("return globalThis.__linkletPagePosition?.send()", arguments: [:], in: nil, in: Self.world) { _ in }
    }

    func restore(_ position: PagePosition, in view: WKWebView) {
        guard position.isValid else { return }
        view.callAsyncJavaScript("globalThis.__linkletPagePosition?.restore(x,y)",
                                 arguments: ["x": position.x, "y": position.y], in: nil, in: Self.world) { _ in }
    }

    private static let script = #"""
    (() => {
      if (globalThis.__linkletPagePosition) return;
      let frame=0, restoring=false, timer=0, observer=null;
      function send() {
        frame=0;
        webkit.messageHandlers.linkletPagePosition.postMessage({url:location.href,x:scrollX,y:scrollY,restoring});
      }
      function cancelRestore() {
        if (!restoring) return;
        restoring=false; clearInterval(timer); observer?.disconnect(); observer=null; send();
      }
      function restore(x,y) {
        cancelRestore(); restoring=true; send();
        const deadline=performance.now()+5000;
        function attempt() {
          scrollTo({left:x,top:y,behavior:'instant'});
          if ((Math.abs(scrollX-x)<2 && Math.abs(scrollY-y)<2) || performance.now()>deadline) cancelRestore();
        }
        observer=new ResizeObserver(attempt); observer.observe(document.documentElement);
        if(document.body) observer.observe(document.body);
        timer=setInterval(attempt,100); requestAnimationFrame(attempt);
      }
      addEventListener('scroll',()=>{if(!frame) frame=requestAnimationFrame(send)}, {passive:true});
      for(const event of ['wheel','pointerdown','touchstart','keydown']) addEventListener(event,cancelRestore,{passive:true,capture:true});
      addEventListener('pageshow',send); addEventListener('pagehide',()=>{cancelRestore();send()});
      globalThis.__linkletPagePosition={send,restore};
    })();
    """#
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

import AppKit
import Combine
import WebKit
import SwiftUI

/// WebKit must create the child with its supplied configuration to preserve opener,
/// cookies, POST requests and window.close(). Never load the request a second time.
@MainActor
final class WebPopupWindowController: NSWindowController, NSWindowDelegate {
    let session: PreviewSession
    let webView: WKWebView
    let coordinator: WebPreview.Coordinator
    var onClose: (() -> Void)?
    private var observations = Set<AnyCancellable>()
    private let parentID: UUID

    init(configuration: WKWebViewConfiguration, parent: PreviewSession, features: WKWindowFeatures, model: AppModel? = nil) {
        parentID = parent.windowID
        session = PreviewSession(adBlockService: parent.adBlockService, siteData: parent.siteData,
                                 windowRegistry: parent.windowRegistry)
        session.onContinueInBrowser = parent.onContinueInBrowser
        session.makePopup = parent.makePopup
        session.onSiteLoaded = parent.onSiteLoaded
        webView = WKWebView(frame: .zero, configuration: configuration)
        coordinator = WebPreview.Coordinator(session: session)
        let width = min(max(features.width?.doubleValue ?? PreviewWindowAppearance.initialContentSize.width,
                            PreviewWindowAppearance.minimumSize.width), 1000)
        let height = min(max(features.height?.doubleValue ?? PreviewWindowAppearance.initialContentSize.height,
                             PreviewWindowAppearance.minimumSize.height), 900)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        PreviewWindowAppearance.apply(to: panel)
        panel.level = parent.webView?.window?.level ?? .normal
        panel.hidesOnDeactivate = parent.webView?.window?.hidesOnDeactivate ?? false
        super.init(window: panel)
        panel.delegate = self
        coordinator.onWebViewClose = { [weak self] in self?.close() }
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        session.adoptPopup(webView, originalURL: parent.originalURL)
        coordinator.startObserving(webView)

        if let model {
            let host = NSHostingController(rootView: PreviewRootView(model: model, session: session, existingWebView: webView))
            host.sizingOptions = []
            panel.contentViewController = host
        } else {
            let host = NSHostingController(rootView: PreviewPageView(session: session, existingWebView: webView))
            host.sizingOptions = []
            panel.contentViewController = host
        }
        panel.contentViewController?.view.setAccessibilityIdentifier("Linklet.PreviewChrome")
        Publishers.CombineLatest(session.$pageTitle, session.$currentURL)
            .map { title, url in title.isEmpty ? (url?.host ?? L("Website window")) : title }
            .removeDuplicates()
            .sink { [weak panel] title in panel?.title = title }.store(in: &observations)
        parent.webView?.window?.addChildWindow(panel, ordered: .above)
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(webView)
        if let window { session.windowRegistry.register(window, session: session, parentID: parentID) }
    }

    func windowWillClose(_ notification: Notification) {
        if let window { window.parent?.removeChildWindow(window) }
        coordinator.closePopupWindows()
        session.endSession()
        onClose?()
        onClose = nil
    }
}

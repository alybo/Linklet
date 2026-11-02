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
    private var observations = Set<AnyCancellable>()
    private var geometry: WebsiteWindowGeometry!
    let openerID: UUID

    init(configuration: WKWebViewConfiguration, parent: PreviewSession, features: WKWindowFeatures, model: AppModel? = nil) {
        openerID = parent.windowID
        session = PreviewSession(adBlockService: parent.adBlockService, siteData: parent.siteData,
                                 windowRegistry: parent.windowRegistry)
        if let model {
            session.onContinueInBrowser = { [weak model, weak session] in
                guard let model, let session, let target = model.preferredTarget else { return }
                model.openOriginalURL(in: target, session: session)
            }
        } else {
            session.onContinueInBrowser = parent.onContinueInBrowser
        }
        session.makePopup = parent.makePopup
        session.onSiteLoaded = parent.onSiteLoaded
        session.history = parent.history
        webView = WKWebView(frame: .zero, configuration: configuration)
        coordinator = WebPreview.Coordinator(session: session)
        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: PreviewWindowAppearance.initialContentSize),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        PreviewWindowAppearance.apply(to: panel)
        panel.level = parent.webView?.window?.level ?? .normal
        panel.hidesOnDeactivate = parent.webView?.window?.hidesOnDeactivate ?? false
        super.init(window: panel)
        panel.delegate = self
        geometry = WebsiteWindowGeometry(window: panel, service: model?.windowGeometry ?? WindowGeometryService())
        session.onWindowURLCommitted = { [weak self] url in self?.geometry.committed(url) }
        coordinator.onWebViewClose = { [weak self] in self?.close() }
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        session.adoptPopup(webView, from: parent)
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
        // Assigning the hosting controller can shrink an initially empty WebView.
        // AppKit owns the size, just as in PreviewWindowController.prepare().
        panel.setContentSize(PreviewWindowAppearance.initialContentSize)
        // An AppKit child window moves and orders with its parent. OAuth needs
        // only WebKit's opener/configuration, not a native window attachment.
        if let frame = parent.webView?.window?.frame,
           let screen = parent.webView?.window?.screen ?? NSScreen.main {
            let proposed = NSRect(x: frame.minX + 28, y: frame.minY - 28,
                                  width: panel.frame.width, height: panel.frame.height)
            panel.setFrame(WindowGeometryService.clamped(proposed, to: screen.visibleFrame), display: false)
        } else {
            panel.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(webView)
        if let window { session.windowRegistry.register(window, session: session, parentID: openerID) }
    }

    func windowDidMove(_ notification: Notification) { geometry.save() }
    func windowDidResize(_ notification: Notification) { geometry.save() }

    func windowWillClose(_ notification: Notification) {
        geometry.save()
        coordinator.stopCursorHandling()
        session.endSession()
    }
}

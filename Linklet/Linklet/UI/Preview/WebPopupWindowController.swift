import AppKit
import Combine
import WebKit

/// WebKit must create the child with its supplied configuration to preserve opener,
/// cookies, POST requests and window.close(). Never load the request a second time.
@MainActor
final class WebPopupWindowController: NSWindowController, NSWindowDelegate {
    let session: PreviewSession
    let webView: WKWebView
    let coordinator: WebPreview.Coordinator
    var onClose: (() -> Void)?
    private var observations = Set<AnyCancellable>()

    init(configuration: WKWebViewConfiguration, parent: PreviewSession, features: WKWindowFeatures) {
        session = PreviewSession(adBlockService: parent.adBlockService, siteData: parent.siteData)
        session.onContinueInBrowser = parent.onContinueInBrowser
        webView = WKWebView(frame: .zero, configuration: configuration)
        coordinator = WebPreview.Coordinator(session: session)
        let width = min(max(features.width?.doubleValue ?? 600, 360), 1000)
        let height = min(max(features.height?.doubleValue ?? 700, 400), 900)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.tabbingMode = .disallowed
        panel.minSize = NSSize(width: 360, height: 400)
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

        let address = NSTextField(labelWithString: "")
        address.lineBreakMode = .byTruncatingMiddle
        address.maximumNumberOfLines = 1
        address.cell?.usesSingleLineMode = true
        // OAuth URLs can contain kilobytes of state. The address must compress
        // before AppKit grows the window to the field's intrinsic text width.
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        address.isSelectable = true
        address.font = .systemFont(ofSize: 12)
        let browserButton = NSButton(title: L("Continue in browser"), target: self, action: #selector(continueInBrowser))
        browserButton.toolTip = L("Open the original site link in your chosen browser. Sign-in starts again there.")
        browserButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        browserButton.isEnabled = session.onContinueInBrowser != nil
        let toolbar = NSStackView(views: [address, browserButton])
        toolbar.orientation = .horizontal
        toolbar.distribution = .fill
        toolbar.spacing = 10
        let content = NSView()
        panel.contentView = content
        for view in [toolbar, webView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        session.$currentURL.sink { url in address.stringValue = url?.absoluteString ?? "" }.store(in: &observations)
        session.$pageTitle.sink { title in panel.title = title.isEmpty ? L("Website window") : title }.store(in: &observations)
        session.$errorMessage.compactMap { $0 }.sink { [weak self] message in
            guard let self, let window = self.window, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = L("Couldn't open the page")
            alert.informativeText = message
            alert.addButton(withTitle: L("OK"))
            if self.session.onContinueInBrowser != nil { alert.addButton(withTitle: L("Continue in browser")) }
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.session.errorMessage = nil
                if response == .alertSecondButtonReturn { self?.session.onContinueInBrowser?() }
            }
        }.store(in: &observations)
        parent.webView?.window?.addChildWindow(panel, ordered: .above)
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(webView)
    }

    @objc private func continueInBrowser() { session.onContinueInBrowser?() }

    func windowWillClose(_ notification: Notification) {
        if let window { window.parent?.removeChildWindow(window) }
        coordinator.closePopupWindows()
        session.endSession()
        onClose?()
        onClose = nil
    }
}

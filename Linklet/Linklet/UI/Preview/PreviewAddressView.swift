import AppKit
import SwiftUI

/// Uses the existing title typography. Only the address expands; the window
/// controls and the live WKWebView keep their identity and state.
struct PreviewLocationView: View {
    @ObservedObject var session: PreviewSession
    let title: String
    @State private var showsFullAddress = false

    var body: some View {
        HStack(spacing: 8) {
            if !showsFullAddress {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(session.currentURL?.absoluteString ?? title)
                Spacer(minLength: 12)
            }
            if !session.isWelcome, let url = session.currentURL {
                PreviewAddressDisclosure(url: url, isExpanded: $showsFullAddress) { [weak session] in
                    guard let view = session?.webView else { return }
                    view.window?.makeFirstResponder(view)
                }
                .frame(width: showsFullAddress ? nil : PreviewAddressControlView.compactWidth(for: url), height: 24)
                .frame(maxWidth: showsFullAddress ? .infinity : nil)
                .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: session.navigationID) { _ in showsFullAddress = false }
        .onChange(of: session.currentURL) { url in
            if url == nil { showsFullAddress = false }
        }
    }
}

private struct PreviewAddressDisclosure: NSViewRepresentable {
    let url: URL
    @Binding var isExpanded: Bool
    let returnFocusToPage: () -> Void

    func makeNSView(context: Context) -> PreviewAddressControlView {
        let view = PreviewAddressControlView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PreviewAddressControlView, context: Context) {
        view.onExpansionChanged = { isExpanded = $0 }
        view.returnFocusToPage = returnFocusToPage
        view.update(url: url, expanded: isExpanded)
    }

    static func dismantleNSView(_ view: PreviewAddressControlView, coordinator: ()) {
        view.stopObserving()
    }
}

@MainActor
final class PreviewAddressControlView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    private(set) var isExpanded = false
    let addressButton = NSButton(title: "", target: nil, action: nil)
    let addressField = NSTextField(labelWithString: "")
    var onExpansionChanged: ((Bool) -> Void)?
    var returnFocusToPage: (() -> Void)?

    private var fullAddress = ""
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var hoverArea: NSTrackingArea?
    private var isHovered = false

    static func compactAddress(for url: URL) -> String {
        guard var host = url.host, !host.isEmpty else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        if let port = url.port { host += ":\(port)" }
        return url.scheme?.lowercased() == "http" ? "http://" + host : host
    }

    static func compactWidth(for url: URL) -> CGFloat {
        let text = compactAddress(for: url) as NSString
        return min(180, max(44, ceil(text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width) + 16))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("preview-address")
        addressButton.target = self
        addressButton.action = #selector(expandAddress)
        addressButton.isBordered = false
        addressButton.font = .systemFont(ofSize: 11)
        addressButton.contentTintColor = .secondaryLabelColor
        addressButton.cell?.lineBreakMode = .byTruncatingMiddle
        addressButton.setAccessibilityIdentifier("preview-address-disclosure")
        addressField.isEditable = false
        addressField.isSelectable = true
        addressField.font = .systemFont(ofSize: 12)
        addressField.textColor = .labelColor
        addressField.focusRingType = .none
        addressField.lineBreakMode = .byClipping
        addressField.maximumNumberOfLines = 1
        addressField.cell?.usesSingleLineMode = true
        addressField.setAccessibilityIdentifier("preview-full-address")
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressField.isHidden = true
        addSubview(addressButton)
        addSubview(addressField)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(url: URL, expanded: Bool) {
        let nextAddress = url.absoluteString
        let addressChanged = nextAddress != fullAddress
        fullAddress = nextAddress
        addressButton.title = Self.compactAddress(for: url)
        addressButton.toolTip = fullAddress
        addressButton.setAccessibilityLabel(L("Show full address"))
        addressButton.setAccessibilityValue(addressButton.title)
        addressField.setAccessibilityLabel(L("Full address"))
        if addressChanged { addressField.stringValue = fullAddress }
        setExpanded(expanded, notify: false)
        if addressChanged && expanded { selectAddressSoon() }
    }

    override func layout() {
        super.layout()
        addressButton.frame = bounds
        addressField.frame = bounds.insetBy(dx: 8, dy: 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(isHovered ? 0.09 : 0.055).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.collapse(returningFocus: false) }
        }
    }

    func stopObserving() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        eventMonitor = nil
        resignObserver = nil
    }

    @objc private func expandAddress() {
        guard !fullAddress.isEmpty else { return }
        setExpanded(true, notify: true)
        selectAddressSoon()
    }

    private func setExpanded(_ expanded: Bool, notify: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        addressButton.isHidden = expanded
        addressField.isHidden = !expanded
        needsLayout = true
        needsDisplay = true
        if notify { onExpansionChanged?(expanded) }
    }

    private func collapse(returningFocus: Bool) {
        guard isExpanded else { return }
        if addressField.currentEditor() != nil { window?.makeFirstResponder(nil) }
        setExpanded(false, notify: true)
        if returningFocus { returnFocusToPage?() }
    }

    private func selectAddressSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, isExpanded, window?.isKeyWindow == true else { return }
            addressField.selectText(nil)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown {
            guard event.window === window else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 37, modifiers == .command { // Physical L, including Russian keyboards.
                expandAddress()
                return nil
            }
            if isExpanded, modifiers.isEmpty, [53, 36, 76].contains(event.keyCode) {
                collapse(returningFocus: true)
                return nil
            }
        } else if isExpanded {
            if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) {
                collapse(returningFocus: false)
            }
        }
        return event
    }
}

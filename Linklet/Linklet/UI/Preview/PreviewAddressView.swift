import AppKit
import QuartzCore
import SwiftUI

/// Uses the existing title typography. Only the address expands; the window
/// controls and the live WKWebView keep their identity and state.
struct PreviewLocationView: View {
    @ObservedObject var session: PreviewSession
    let title: String
    let submitAddress: (String) -> Bool
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
                PreviewAddressDisclosure(url: url, isExpanded: $showsFullAddress, submitAddress: submitAddress) { [weak session] in
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
    let submitAddress: (String) -> Bool
    let returnFocusToPage: () -> Void

    func makeNSView(context: Context) -> PreviewAddressControlView {
        let view = PreviewAddressControlView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PreviewAddressControlView, context: Context) {
        view.onExpansionChanged = { isExpanded = $0 }
        view.returnFocusToPage = returnFocusToPage
        view.onSubmit = submitAddress
        view.update(url: url, expanded: isExpanded)
    }

    static func dismantleNSView(_ view: PreviewAddressControlView, coordinator: ()) {
        view.stopObserving()
    }
}

@MainActor
final class PreviewAddressControlView: NSView, NSTextFieldDelegate {
    override var mouseDownCanMoveWindow: Bool { false }
    private(set) var isExpanded = false
    let copyButton = NSButton(title: "", target: nil, action: nil)
    let addressButton = NSButton(title: "", target: nil, action: nil)
    let addressField = NSTextField(labelWithString: "")
    private(set) var isShowingCopyFeedback = false
    private var copyFeedbackTask: Task<Void, Never>?
    var onExpansionChanged: ((Bool) -> Void)?
    var returnFocusToPage: (() -> Void)?
    var onSubmit: ((String) -> Bool)?

    private var fullAddress = ""
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var hoverArea: NSTrackingArea?
    private var isHovered = false
    private static let horizontalInset: CGFloat = 12
    private static let copyButtonWidth: CGFloat = 14
    private static let iconTextSpacing: CGFloat = 8

    static func compactAddress(for url: URL) -> String {
        guard var host = url.host, !host.isEmpty else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        if let port = url.port { host += ":\(port)" }
        return url.scheme?.lowercased() == "http" ? "http://" + host : host
    }

    static func compactWidth(for url: URL) -> CGFloat {
        let text = compactAddress(for: url) as NSString
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
        return min(180, max(60, ceil(text.size(withAttributes: font).width)
                            + 2 * horizontalInset + copyButtonWidth + iconTextSpacing))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("preview-address")
        copyButton.target = self
        copyButton.action = #selector(copyCurrentAddress)
        copyButton.isBordered = false
        copyButton.imagePosition = .imageOnly
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        copyButton.wantsLayer = true
        copyButton.setAccessibilityIdentifier("preview-copy-address")
        copyButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        addressButton.target = self
        addressButton.action = #selector(expandAddress)
        addressButton.isBordered = false
        addressButton.font = .systemFont(ofSize: 11)
        addressButton.contentTintColor = .secondaryLabelColor
        addressButton.cell?.lineBreakMode = .byTruncatingMiddle
        addressButton.setAccessibilityIdentifier("preview-address-disclosure")
        addressButton.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: L("Copy current URL"), target: self, selector: #selector(copyCurrentAddress))
        ])
        addressField.isEditable = true
        addressField.isSelectable = true
        addressField.delegate = self
        addressField.contentType = .URL
        addressField.isAutomaticTextCompletionEnabled = false
        addressField.font = .systemFont(ofSize: 12)
        addressField.textColor = .labelColor
        addressField.focusRingType = .none
        addressField.lineBreakMode = .byClipping
        addressField.maximumNumberOfLines = 1
        addressField.cell?.usesSingleLineMode = true
        addressField.cell?.isScrollable = true
        addressField.setAccessibilityIdentifier("preview-full-address")
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressField.isHidden = true
        addSubview(copyButton)
        addSubview(addressButton)
        addSubview(addressField)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(url: URL, expanded: Bool) {
        let nextAddress = url.absoluteString
        let addressChanged = nextAddress != fullAddress
        if addressChanged { dismissCopyFeedback(animated: false) }
        fullAddress = nextAddress
        addressButton.title = Self.compactAddress(for: url)
        addressButton.toolTip = fullAddress
        addressButton.setAccessibilityLabel(L("Show full address"))
        addressButton.setAccessibilityValue(addressButton.title)
        addressField.setAccessibilityLabel(L("Full address"))
        copyButton.setAccessibilityLabel(L("Copy current URL"))
        copyButton.toolTip = L(isShowingCopyFeedback ? "Copied!" : "Copy current URL")
        // The field is a draft while expanded. Redirects, SPA changes and KVO
        // progress updates must not replace text or selection under the user.
        if addressChanged && !isExpanded { addressField.stringValue = fullAddress }
        setExpanded(expanded, notify: false)
    }

    override func layout() {
        super.layout()
        copyButton.frame = NSRect(x: Self.horizontalInset, y: 0, width: Self.copyButtonWidth, height: bounds.height)
        let textX = copyButton.frame.maxX + Self.iconTextSpacing
        addressButton.frame = NSRect(x: textX, y: 0,
                                     width: max(0, bounds.width - textX - Self.horizontalInset), height: bounds.height)
        // A borderless native field places its editor at the top of its frame.
        // Center the field's natural single-line height, so both glyphs and the
        // live insertion cursor share the center of the surrounding pill.
        let fieldHeight = min(bounds.height, ceil(addressField.intrinsicContentSize.height))
        addressField.frame = NSRect(x: 8, y: (bounds.height - fieldHeight) / 2,
                                   width: max(0, bounds.width - 16), height: fieldHeight)
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

    override func mouseDown(with event: NSEvent) {
        guard !isExpanded else { super.mouseDown(with: event); return }
        if isCopyPoint(convert(event.locationInWindow, from: nil)) { _ = copyCurrentAddress() }
        else { expandAddress() }
    }

    private func isCopyPoint(_ point: NSPoint) -> Bool {
        // Keep the outer padding clickable while the visible symbol is compact.
        point.x < Self.horizontalInset + Self.copyButtonWidth + Self.iconTextSpacing / 2
    }

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
        dismissCopyFeedback(animated: false)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        eventMonitor = nil
        resignObserver = nil
    }

    @objc private func expandAddress() {
        guard !fullAddress.isEmpty else { return }
        dismissCopyFeedback(animated: false)
        setExpanded(true, notify: true)
        selectAddressSoon()
    }

    private func setExpanded(_ expanded: Bool, notify: Bool) {
        guard isExpanded != expanded else { return }
        if !isExpanded || !expanded { addressField.stringValue = fullAddress }
        isExpanded = expanded
        if expanded { dismissCopyFeedback(animated: false) }
        addressButton.isHidden = expanded
        copyButton.isHidden = expanded
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let draft = textView.string
            guard onSubmit?(draft) == true else { return true }
            collapse(returningFocus: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            collapse(returningFocus: true)
            return true
        }
        return false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if !isExpanded, event.window === window,
           bounds.contains(convert(event.locationInWindow, from: nil)),
           event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            let point = convert(event.locationInWindow, from: nil)
            if isCopyPoint(point) { _ = copyCurrentAddress() }
            else { expandAddress() }
            return nil
        }
        if event.type == .keyDown {
            guard event.window === window else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 37, modifiers == .command { // Physical L, including Russian keyboards.
                expandAddress()
                return nil
            }
            if isExpanded, modifiers.isEmpty, event.keyCode == 53 {
                if let editor = addressField.currentEditor() as? NSTextView, editor.hasMarkedText() { return event }
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

    @objc private func copyCurrentAddress() -> Bool {
        guard !fullAddress.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(fullAddress, forType: .string) else { return false }
        copyFeedbackTask?.cancel()
        isShowingCopyFeedback = true
        setCopyFeedbackVisible(true, animated: true)
        NSAccessibility.post(element: copyButton, notification: .announcementRequested, userInfo: [
            .announcement: L("Copied!"), .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
        copyFeedbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.dismissCopyFeedback(animated: true)
        }
        return true
    }

    private func dismissCopyFeedback(animated: Bool) {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        isShowingCopyFeedback = false
        setCopyFeedbackVisible(false, animated: animated)
    }

    private func setCopyFeedbackVisible(_ visible: Bool, animated: Bool) {
        copyButton.layer?.removeAnimation(forKey: "copySymbol")
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.16
            copyButton.layer?.add(transition, forKey: "copySymbol")
        }
        copyButton.image = NSImage(systemSymbolName: visible ? "checkmark" : "link", accessibilityDescription: nil)
        copyButton.toolTip = L(visible ? "Copied!" : "Copy current URL")
        copyButton.setAccessibilityValue(visible ? L("Copied!") : nil)
    }
}

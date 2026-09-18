import AppKit
import SwiftUI

private final class SearchPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SearchWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let settings: SearchSettings
    private let openURL: (URL) -> Void
    let input = NSTextField()
    let selection = SearchEngineSelection()
    private var engineControl: NSView!
    var isVisible: Bool { window?.isVisible == true }

    init(settings: SearchSettings, openURL: @escaping (URL) -> Void) {
        self.settings = settings
        self.openURL = openURL
        let size = NSSize(width: 680, height: 76)
        let panel = SearchPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        super.init(window: panel)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.bounds)
            glass.style = .regular
            glass.cornerRadius = 26
            glass.contentView = content
            panel.contentView = glass
        } else {
            let material = NSVisualEffectView(frame: content.bounds)
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 22
            material.layer?.masksToBounds = true
            content.autoresizingMask = [.width, .height]
            material.addSubview(content)
            panel.contentView = material
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 23, weight: .regular)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .systemFont(ofSize: 24, weight: .regular)
        input.textColor = .labelColor
        input.cell?.usesSingleLineMode = true
        input.cell?.isScrollable = true
        input.delegate = self
        input.target = self
        input.action = #selector(submit)
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        engineControl = NSHostingView(rootView: SearchEngineControl(
            selection: selection,
            submit: { [weak self] in self?.submit() },
            didChoose: { [weak self] in self?.focusInput() },
            didDismiss: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.isVisible else { return }
                    if self.window?.isKeyWindow != true { self.close() }
                }
            }
        ))
        for view in [icon, input, engineControl!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 28),
            input.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            input.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            input.trailingAnchor.constraint(equalTo: engineControl.leadingAnchor, constant: -16),
            engineControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            engineControl.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            engineControl.widthAnchor.constraint(equalToConstant: 174),
            engineControl.heightAnchor.constraint(equalToConstant: 38)
        ])
        panel.initialFirstResponder = input
        input.nextKeyView = engineControl
        engineControl.nextKeyView = input
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toggle() {
        if window?.isVisible == true { close() } else { present() }
    }

    func present() {
        guard let window else { return }
        reset()
        window.title = L("Quick Search")
        input.placeholderString = L("Search or enter address")
        input.setAccessibilityLabel(L("Search or enter address"))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                          y: frame.minY + frame.height * 0.7 - window.frame.height / 2))
        }
        // A nonactivating panel borrows keyboard focus and returns it to the
        // previous app when dismissed, including in full-screen Spaces.
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
    }

    override func close() {
        selection.isPresented = false
        window?.orderOut(nil)
        reset()
    }

    private func reset() {
        input.stringValue = ""
        selection.engine = settings.engine
    }

    private func focusInput() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(input)
        (input.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: input.stringValue.utf16.count, length: 0))
    }

    @objc func submit() {
        guard let url = SearchInput.destination(for: input.stringValue, engine: selection.engine) else { return }
        close()
        openURL(url)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() {
            close()
            return true
        }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        if !selection.isPresented { close() }
    }
}

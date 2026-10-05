import AppKit
import Combine
import Carbon
import SwiftUI

private final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SidebarWindowController: NSWindowController {
    private let library: LinkLibrary
    private var timer: Timer?
    private let hotKey = SearchHotKey(identifier: 2)
    private var enabledObservation: AnyCancellable?
    private var edgeScreenID: ObjectIdentifier?
    private var edgeEnteredAt: Date?
    private var leftPanelAt: Date?
    private var isManuallyPresented = false
    private var suppressedUntil: Date = .distantPast

    init(model: AppModel) {
        library = model.linkLibrary
        let panel = SidebarPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        super.init(window: panel)
        let hosting = NSHostingController(rootView: SidebarView(model: model, dismiss: { [weak self] in self?.hide() }))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        hotKey.action = { [weak self] in self?.toggle() }
        enabledObservation = library.$isEnabled.sink { [weak self] enabled in
            self?.setMonitoring(enabled)
        }
    }

    deinit { timer?.invalidate() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toggle() {
        guard library.isEnabled else { return }
        if window?.isVisible == true { hide() }
        else if let screen = screenAtMouse() ?? NSScreen.main { present(on: screen, manual: true) }
    }

    func hide() {
        // A click opening a preview must not immediately reopen the edge panel.
        suppressedUntil = Date().addingTimeInterval(0.8)
        window?.orderOut(nil)
        isManuallyPresented = false
        edgeEnteredAt = nil
        leftPanelAt = nil
    }

    private func setMonitoring(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        let shortcut = SearchShortcut(keyCode: 11, modifiers: UInt32(controlKey | optionKey), keyLabel: "B")
        library.shortcutError = hotKey.register(enabled ? shortcut : nil) ? nil : L("The sidebar shortcut ⌃⌥B is unavailable. Use the Linklet menu or the screen edge.")
        if enabled {
            // Reading mouse location needs no global event tap or Accessibility permission.
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollMouse() }
            }
        } else { hide() }
    }

    private func screenAtMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    static func isAtLeftEdge(_ point: NSPoint, screenFrame: NSRect, visibleFrame: NSRect) -> Bool {
        point.x >= screenFrame.minX && point.x <= screenFrame.minX + 2 &&
            point.y >= visibleFrame.minY && point.y <= visibleFrame.maxY
    }

    private func pollMouse() {
        guard let window, Date() >= suppressedUntil else { return }
        let point = NSEvent.mouseLocation
        if window.isVisible {
            if window.frame.insetBy(dx: -8, dy: -8).contains(point) || window.attachedSheet != nil {
                leftPanelAt = nil
            } else if !isManuallyPresented {
                if let leftPanelAt, Date().timeIntervalSince(leftPanelAt) >= 0.5 { hide() }
                else if leftPanelAt == nil { leftPanelAt = Date() }
            }
            return
        }
        guard let screen = screenAtMouse(),
              Self.isAtLeftEdge(point, screenFrame: screen.frame, visibleFrame: screen.visibleFrame) else {
            edgeEnteredAt = nil
            edgeScreenID = nil
            return
        }
        let id = ObjectIdentifier(screen)
        if edgeScreenID != id { edgeScreenID = id; edgeEnteredAt = Date() }
        if let edgeEnteredAt, Date().timeIntervalSince(edgeEnteredAt) >= 0.25 { present(on: screen, manual: false) }
    }

    private func present(on screen: NSScreen, manual: Bool) {
        guard let window else { return }
        isManuallyPresented = manual
        leftPanelAt = nil
        let visible = screen.visibleFrame
        let frame = NSRect(x: screen.frame.minX, y: visible.minY + 8,
                           width: min(300, visible.width), height: max(100, visible.height - 16))
        window.setFrame(frame, display: true)
        // Hover never activates Linklet or closes a private preview in Hide mode.
        if manual { window.makeKeyAndOrderFront(nil) }
        else { window.orderFrontRegardless() }
    }
}

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
    private var indicatorWindow: NSPanel?
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
        indicatorWindow?.orderOut(nil)
        indicatorWindow = nil
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
        if let indicator = indicatorWindow {
            if indicator.frame.contains(point), let screen = screenAtMouse() {
                present(on: screen, manual: false)
                return
            }
        }
        guard let screen = screenAtMouse(),
              Self.isAtLeftEdge(point, screenFrame: screen.frame, visibleFrame: screen.visibleFrame) else {
            indicatorWindow?.orderOut(nil)
            indicatorWindow = nil
            edgeEnteredAt = nil
            edgeScreenID = nil
            return
        }
        let id = ObjectIdentifier(screen)
        if edgeScreenID != id { edgeScreenID = id; edgeEnteredAt = Date() }
        if let edgeEnteredAt, Date().timeIntervalSince(edgeEnteredAt) >= 0.25 { showIndicator(on: screen) }
    }

    static func panelFrame(screenFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        let margin = min(screenFrame.width * 0.1, max(0, (screenFrame.height - 300) / 2))
        let bottom = max(visibleFrame.minY, screenFrame.minY + margin)
        let top = min(visibleFrame.maxY, screenFrame.maxY - margin)
        return NSRect(x: screenFrame.minX, y: bottom, width: min(300, visibleFrame.width), height: max(1, top - bottom))
    }

    private func showIndicator(on screen: NSScreen) {
        guard indicatorWindow == nil else { return }
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.midY - 51.25, width: 30, height: 102.5)
        let indicator = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        indicator.backgroundColor = .clear
        indicator.isOpaque = false
        indicator.hasShadow = false
        indicator.level = .floating
        indicator.hidesOnDeactivate = false
        indicator.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSHostingController(rootView:
            Button { [weak self] in self?.present(on: screen, manual: true) } label: {
                Image("SidebarReveal").resizable().scaleEffect(x: -1, y: 1).frame(width: 30, height: 102.5)
            }.buttonStyle(.plain).help(L("Show sidebar"))
        )
        content.sizingOptions = []
        indicator.contentViewController = content
        indicatorWindow = indicator
        indicator.orderFrontRegardless()
    }

    private func present(on screen: NSScreen, manual: Bool) {
        guard let window else { return }
        isManuallyPresented = manual
        leftPanelAt = nil
        indicatorWindow?.orderOut(nil)
        indicatorWindow = nil
        let frame = Self.panelFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(reduceMotion ? frame : frame.offsetBy(dx: -frame.width, dy: 0), display: true)
        // Hover never activates Linklet or closes a private preview in Hide mode.
        if manual { window.makeKeyAndOrderFront(nil) }
        else { window.orderFrontRegardless() }
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                window.animator().setFrame(frame, display: true)
            }
        }
    }
}

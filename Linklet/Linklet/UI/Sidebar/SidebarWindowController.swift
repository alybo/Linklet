import AppKit
import Combine
import Carbon
import SwiftUI

private final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        // Set the edge cursor after the hosting view's tracking/cursor processing.
        guard !ignoresMouseEvents,
              event.type == .mouseMoved || event.type == .cursorUpdate || event.type == .leftMouseDragged,
              let contentView,
              contentView.hitTest(contentView.convert(event.locationInWindow, from: nil)) is SidebarResizeView else { return }
        NSCursor.resizeLeftRight.set()
    }
}

@MainActor
final class SidebarWindowController: NSWindowController, NSWindowDelegate {
    private(set) var indicatorWindow: NSPanel?
    let editor = SidebarEditorState()
    let reveal = SidebarRevealState()
    private var editorObservation: AnyCancellable?
    private let library: LinkLibrary
    private var timer: Timer?
    private let hotKey = SearchHotKey(identifier: 2)
    private var enabledObservation: AnyCancellable?
    private var focusObservation: AnyCancellable?
    private var edgeScreenID: ObjectIdentifier?
    private var edgeEnteredAt: Date?
    private var leftPanelAt: Date?
    private var exitDelay: TimeInterval = 0.5
    private(set) var isResizing = false
    private var suppressedUntil: Date = .distantPast
    private(set) var isPresented = false
    private var animationTimer: Timer?
    private var presentedFrame: NSRect?
    private var animationRefreshRate = 60
    private let reduceMotion: () -> Bool
    static let revealDuration: TimeInterval = 0.26
    static let concealDuration: TimeInterval = 0.18
    static let revealShoulderDuration: TimeInterval = 0.20
    static let concealShoulderDuration: TimeInterval = 0.14

    init(model: AppModel, reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        library = model.linkLibrary
        self.reduceMotion = reduceMotion
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
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        // Our contour provides the complete transition; AppKit must not add an ordering fade.
        panel.animationBehavior = .none
        super.init(window: panel)
        let hosting = NSHostingController(rootView: SidebarRevealSurface(reveal: reveal) {
            SidebarView(model: model, dismiss: { [weak self] in self?.hide() }, editor: editor)
        })
        hosting.sizingOptions = []
        let resizeHandle = SidebarResizeView()
        resizeHandle.start = { [weak self] in self?.isResizing = true }
        resizeHandle.resize = { [weak self] width in self?.resize(to: width) }
        resizeHandle.finish = { [weak self] in self?.finishResizing() }
        let contentController = NSViewController()
        contentController.addChild(hosting)
        contentController.view = SidebarContentView(content: hosting.view, resizeHandle: resizeHandle)
        panel.contentViewController = contentController
        panel.delegate = self
        focusObservation = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main).sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.dismissForFocusChange()
            }
        editorObservation = editor.$presentation.sink { [weak self] presentation in
            guard presentation != nil, let self else { return }
            self.library.cancelHistoryClear()
            // A form opened during the reveal must remain anchored while the user types.
            self.stopAnimation()
            self.reveal.progress = 1
            self.reveal.shoulderProgress = 1
            self.window?.makeKeyAndOrderFront(nil)
        }
        hotKey.action = { [weak self] in self?.toggle() }
        enabledObservation = library.$isEnabled.sink { [weak self] enabled in
            self?.setMonitoring(enabled)
        }
    }

    deinit { timer?.invalidate(); animationTimer?.invalidate() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toggle() {
        guard library.isEnabled else { return }
        if isPresented { hide() }
        else if let screen = screenAtMouse() ?? NSScreen.main { present(on: screen, manual: true) }
    }

    func hide(animated: Bool = true) {
        // Resigning key while ordering out must not restart an in-flight dismissal.
        guard isPresented || !animated else { return }
        isPresented = false
        // A click opening a preview must not immediately reopen the edge panel.
        suppressedUntil = Date().addingTimeInterval(0.8)
        editor.cancel()
        library.cancelHistoryClear()
        window?.ignoresMouseEvents = true
        indicatorWindow?.orderOut(nil)
        indicatorWindow = nil
        isResizing = false
        exitDelay = 0.5
        edgeEnteredAt = nil
        edgeScreenID = nil
        leftPanelAt = nil
        if animated, window?.isVisible == true, !reduceMotion() {
            animate(to: 0, opening: false)
        } else {
            stopAnimation()
            reveal.progress = 0
            reveal.shoulderProgress = 0
            window?.orderOut(nil)
        }
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
        } else { hide(animated: false) }
    }

    private func screenAtMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    static func isAtLeftEdge(_ point: NSPoint, screenFrame: NSRect, visibleFrame: NSRect) -> Bool {
        point.x >= screenFrame.minX && point.x <= screenFrame.minX + 2 &&
            point.y >= visibleFrame.minY && point.y <= visibleFrame.maxY
    }

    private func pollMouse() { pollMouse(at: NSEvent.mouseLocation, now: Date()) }

    func pollMouse(at point: NSPoint, now: Date) {
        guard let window, now >= suppressedUntil else { return }
        if isPresented {
            if isResizing || editor.isEditing { leftPanelAt = nil; return }
            let holdsOpeningEdge = !library.showsRevealIndicator && window.screen.map {
                Self.isAtLeftEdge(point, screenFrame: $0.frame, visibleFrame: $0.visibleFrame)
            } == true
            if window.frame.insetBy(dx: -8, dy: -8).contains(point) || holdsOpeningEdge || window.attachedSheet != nil {
                leftPanelAt = nil
                exitDelay = 0.5
            } else {
                if let leftPanelAt, now.timeIntervalSince(leftPanelAt) >= exitDelay { hide() }
                else if leftPanelAt == nil { leftPanelAt = now }
            }
            return
        }
        // Don't trigger a second reveal while the window is still sliding away.
        guard !window.isVisible else { return }
        if !library.showsRevealIndicator {
            indicatorWindow?.orderOut(nil)
            indicatorWindow = nil
        }
        if let indicator = indicatorWindow {
            if indicator.frame.contains(point), let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                present(on: screen, manual: false)
                return
            }
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              Self.isAtLeftEdge(point, screenFrame: screen.frame, visibleFrame: screen.visibleFrame) else {
            indicatorWindow?.orderOut(nil)
            indicatorWindow = nil
            edgeEnteredAt = nil
            edgeScreenID = nil
            return
        }
        let id = ObjectIdentifier(screen)
        if edgeScreenID != id { edgeScreenID = id; edgeEnteredAt = now }
        if let edgeEnteredAt {
            if library.showsRevealIndicator {
                if now.timeIntervalSince(edgeEnteredAt) >= 0.25 { showIndicator(on: screen) }
            } else if now.timeIntervalSince(edgeEnteredAt) >= library.edgeOpenDelay {
                present(on: screen, manual: false)
            }
        }
    }

    static func clampedWidth(_ preferred: CGFloat, screenFrame: NSRect, visibleFrame: NSRect) -> CGFloat {
        let maximum = max(1, min(screenFrame.width / 4, visibleFrame.width))
        return min(maximum, max(min(200, maximum), preferred.isFinite ? preferred : 300))
    }

    func resize(to preferred: CGFloat) {
        guard let window, let screen = window.screen else { return }
        stopAnimation()
        reveal.progress = 1
        reveal.shoulderProgress = 1
        var frame = window.frame
        frame.origin.x = screen.frame.minX
        frame.size.width = Self.clampedWidth(preferred, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        window.setFrame(frame, display: true)
        presentedFrame = frame
    }

    private func finishResizing() {
        isResizing = false
        leftPanelAt = nil
        if let width = window?.frame.width { library.setSidebarWidth(width) }
    }

    static func panelFrame(screenFrame: NSRect, visibleFrame: NSRect, preferredWidth: CGFloat = 300) -> NSRect {
        let margin = min(screenFrame.width * 0.1, max(0, (screenFrame.height - 300) / 2))
        let bottom = max(visibleFrame.minY, screenFrame.minY + margin)
        let top = min(visibleFrame.maxY, screenFrame.maxY - margin)
        return NSRect(x: screenFrame.minX, y: bottom, width: clampedWidth(preferredWidth, screenFrame: screenFrame, visibleFrame: visibleFrame), height: max(1, top - bottom))
    }

    static func indicatorFrame(screenFrame: NSRect) -> NSRect {
        let height = min(102.5, screenFrame.height)
        return NSRect(x: screenFrame.minX, y: screenFrame.midY - height / 2,
                      width: min(30, screenFrame.width), height: height)
    }

    func showIndicator(on screen: NSScreen) {
        guard indicatorWindow == nil else { return }
        let frame = Self.indicatorFrame(screenFrame: screen.frame)
        let indicator = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        indicator.backgroundColor = .clear
        indicator.isOpaque = false
        indicator.hasShadow = false
        indicator.level = .floating
        indicator.hidesOnDeactivate = false
        indicator.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // A native view has no SwiftUI preferred-size negotiation that could move the panel.
        let content = SidebarRevealView(frame: NSRect(origin: .zero, size: frame.size))
        content.autoresizingMask = [.width, .height]
        content.onPress = { [weak self] in self?.present(on: screen, manual: true) }
        indicator.contentView = content
        indicatorWindow = indicator
        indicator.orderFrontRegardless()
        indicator.setFrame(frame, display: true)
    }

    func windowDidResignKey(_ notification: Notification) { dismissForFocusChange() }

    private func dismissForFocusChange() {
        guard isPresented, !isResizing, !editor.isEditing, window?.attachedSheet == nil else { return }
        hide()
    }

    private func present(on screen: NSScreen, manual: Bool) {
        guard let window else { return }
        exitDelay = manual ? 1 : 0.5
        library.resetRecentDisplayLimit()
        library.cancelHistoryClear()
        leftPanelAt = nil
        indicatorWindow?.orderOut(nil)
        indicatorWindow = nil
        let frame = Self.panelFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, preferredWidth: library.sidebarWidth)
        let continuing = window.isVisible && presentedFrame == frame
        stopAnimation()
        presentedFrame = frame
        isPresented = true
        animationRefreshRate = max(60, screen.maximumFramesPerSecond)
        window.ignoresMouseEvents = false
        if !continuing {
            window.setFrame(frame, display: true)
            reveal.progress = reduceMotion() ? 1 : 0
            reveal.shoulderProgress = reveal.progress
        }
        // Hover never activates Linklet or closes a private preview in Hide mode.
        if manual { window.makeKeyAndOrderFront(nil) }
        else { window.orderFrontRegardless() }
        if reduceMotion() { reveal.progress = 1; reveal.shoulderProgress = 1 }
        else { animate(to: 1, opening: true) }
    }

    // A critically damped reveal settles quickly without bouncing past the screen edge.
    // Closing accelerates out of view; neither direction stretches or scales the content.
    static func motionProgress(_ fraction: Double, opening: Bool) -> Double {
        let t = min(1, max(0, fraction))
        if !opening { return t * t }
        let damping = 8.0
        return (1 - (1 + damping * t) * exp(-damping * t)) / (1 - (1 + damping) * exp(-damping))
    }

    static func shoulderMotionProgress(_ fraction: Double, opening: Bool) -> Double {
        let bodyDuration = opening ? revealDuration : concealDuration
        let shoulderDuration = opening ? revealShoulderDuration : concealShoulderDuration
        return motionProgress(fraction * bodyDuration / shoulderDuration, opening: opening)
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    var isAnimating: Bool { animationTimer != nil }

    private func animate(to destination: CGFloat, opening: Bool) {
        guard window != nil else { return }
        stopAnimation()
        let origin = reveal.progress
        let shoulderOrigin = reveal.shoulderProgress
        // The native window stays anchored; only its visible contour and content move.
        let distance = min(1, abs(destination - origin))
        let duration = (opening ? Self.revealDuration : Self.concealDuration) * sqrt(distance)
        guard duration > 0.001 else {
            reveal.progress = destination
            reveal.shoulderProgress = destination
            if !isPresented { window?.orderOut(nil) }
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let tick = Timer(timeInterval: 1 / Double(animationRefreshRate), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                let fraction = min(1, (ProcessInfo.processInfo.systemUptime - started) / duration)
                let progress = Self.motionProgress(fraction, opening: opening)
                self.reveal.progress = origin + (destination - origin) * progress
                let shoulderProgress = Self.shoulderMotionProgress(fraction, opening: opening)
                self.reveal.shoulderProgress = shoulderOrigin + (destination - shoulderOrigin) * shoulderProgress
                if fraction >= 1 {
                    self.stopAnimation()
                    if !self.isPresented { window.orderOut(nil) }
                }
            }
        }
        animationTimer = tick
        // Keep motion running during menu tracking and mouse gestures, not just the default loop.
        RunLoop.main.add(tick, forMode: .common)
    }
}

private final class SidebarRevealView: NSView {
    var onPress: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("Show sidebar"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = NSImage(named: "SidebarReveal") else { return }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.width, yBy: 0)
        transform.scaleX(by: -1, yBy: 1)
        transform.concat()
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseUp(with event: NSEvent) { onPress?() }
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
}

/// Keeps the hit target outside SwiftUI's offset and clip hierarchy at the physical right edge.
private final class SidebarContentView: NSView {
    private let content: NSView
    private let resizeHandle: SidebarResizeView

    init(content: NSView, resizeHandle: SidebarResizeView) {
        self.content = content
        self.resizeHandle = resizeHandle
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        addSubview(content)
        addSubview(resizeHandle, positioned: .above, relativeTo: content)
        content.autoresizingMask = [.width, .height]
        content.frame = bounds
        positionResizeHandle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        content.frame = bounds
        positionResizeHandle()
    }

    private func positionResizeHandle() {
        resizeHandle.frame = NSRect(x: max(0, bounds.width - 10), y: 48,
                                   width: min(10, bounds.width), height: max(0, bounds.height - 96))
        window?.invalidateCursorRects(for: resizeHandle)
    }
}

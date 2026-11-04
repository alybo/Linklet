import AppKit
import Combine
import Carbon
import ObjectiveC
import SwiftUI

private final class SidebarPanel: NSPanel {
    var keepsGlassAppearanceActive = false
    var handleSearchKeyDown: ((NSEvent) -> Bool)?

    private typealias ActiveAppearanceGetter = @convention(c) (AnyObject, Selector) -> Bool
    private static let activeAppearanceSelector = NSSelectorFromString("_hasActiveAppearance")
    private static let nativeActiveAppearance: ActiveAppearanceGetter? = {
        guard let method = class_getInstanceMethod(NSPanel.self, activeAppearanceSelector) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: ActiveAppearanceGetter.self)
    }()

    // Experimental glass only: Glass ignores SwiftUI's materialActiveAppearance.
    // AppKit consults this undocumented appearance getter for its lensing pass.
    // Keep actual key/main window status intact so typing and focus still work.
    // The black appearance delegates to AppKit's original implementation.
    @objc(_hasActiveAppearance) private func glassActiveAppearance() -> Bool {
        if keepsGlassAppearanceActive { return true }
        return Self.nativeActiveAppearance?(self, Self.activeAppearanceSelector) ?? isKeyWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleSearchKeyDown?(event) == true { return }
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
    private(set) var sectionIndicators: [SidebarSection: NSPanel] = [:]
    private var modeObservation: AnyCancellable?
    private var hoveredSection: SidebarSection?
    private var sectionEnteredAt: Date?
    let editor = SidebarEditorState()
    let reveal = SidebarRevealState()
    private var editorObservation: AnyCancellable?
    private let library: LinkLibrary
    private let windows: BrowserWindowRegistry
    private var isClosingPreview = false
    private var timer: Timer?
    private let hotKey = SearchHotKey(identifier: 2)
    private var enabledObservation: AnyCancellable?
    private var appearanceObservation: AnyCancellable?
    private var focusObservation: AnyCancellable?
    private var fullScreenPreferenceObservation: AnyCancellable?
    private var presentationObservation: NSKeyValueObservation?
    private var spaceObservation: AnyCancellable?
    private let presentationOptions: () -> NSApplication.PresentationOptions
    private var edgeScreenID: ObjectIdentifier?
    private var edgeEnteredAt: Date?
    private var leftPanelAt: Date?
    private var waitsForPointerEntry = false
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

    init(model: AppModel, reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         presentationOptions: @escaping () -> NSApplication.PresentationOptions = { NSApp.currentSystemPresentationOptions }) {
        library = model.linkLibrary
        windows = model.windowRegistry
        self.reduceMotion = reduceMotion
        self.presentationOptions = presentationOptions
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
        panel.handleSearchKeyDown = { [weak self] in self?.handleSearchKeyDown($0) ?? false }
        appearanceObservation = library.$sidebarAppearance.sink { [weak panel] appearance in
            panel?.keepsGlassAppearanceActive = appearance == .glass && SidebarAppearance.supportsGlass
        }
        let hosting = NSHostingController(rootView: SidebarPanelSurface(model: model, library: library,
            reveal: reveal, editor: editor, dismiss: { [weak self] in self?.hide() },
            closeWindow: { [weak self] id in self?.closePreview(id) }))
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
            guard !self.isBlockedByFullScreen else {
                DispatchQueue.main.async { self.hide(animated: false) }
                return
            }
            self.library.cancelHistoryClear()
            self.windows.downloads.cancelHistoryClear()
            // A form opened during the reveal must remain anchored while the user types.
            self.stopAnimation()
            self.reveal.progress = 1
            self.reveal.shoulderProgress = 1
            // An inline editor explicitly orders the panel front. Keep logical
            // visibility in sync even if edge/focus dismissal just ran.
            self.isPresented = true
            self.window?.makeKeyAndOrderFront(nil)
        }
        modeObservation = library.$separatesSections.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.hide(animated: false)
                self?.editor.activeSection = nil
                self?.editor.endSearch()
            }
        }
        hotKey.action = { [weak self] in self?.toggle() }
        enabledObservation = library.$isEnabled.sink { [weak self] enabled in
            self?.setMonitoring(enabled)
        }
        fullScreenPreferenceObservation = library.$hidesInFullScreen.dropFirst().sink { [weak self] _ in
            // Published sends before the new preference is assigned.
            DispatchQueue.main.async { self?.refreshFullScreenAvailability() }
        }
        presentationObservation = NSApp.observe(\.currentSystemPresentationOptions) { [weak self] _, _ in
            Task { @MainActor in self?.refreshFullScreenAvailability() }
        }
        spaceObservation = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshFullScreenAvailability() }
    }

    deinit { timer?.invalidate(); animationTimer?.invalidate() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toggle() {
        guard library.isEnabled, !isBlockedByFullScreen else { return }
        if isPresented { hide() }
        else if let screen = screenAtMouse() ?? NSScreen.main { present(on: screen, manual: true) }
    }

    func show() {
        guard library.isEnabled, !isBlockedByFullScreen,
              let screen = screenAtMouse() ?? NSScreen.main else { return }
        present(on: screen, manual: true)
    }

    func showDownloads() {
        guard !isBlockedByFullScreen else { return }
        editor.cancel()
        if !library.expandedSections.contains(.downloads) { library.toggleSection(.downloads) }
        if let screen = screenAtMouse() ?? NSScreen.main { present(on: screen, manual: true, section: .downloads) }
        editor.downloadsRequest += 1
    }

    func hide(animated: Bool = true) {
        // Resigning key while ordering out must not restart an in-flight dismissal.
        guard isPresented || !animated else { return }
        isPresented = false
        editor.endSearch()
        // A click opening a preview must not immediately reopen the edge panel.
        suppressedUntil = Date().addingTimeInterval(0.8)
        editor.cancel()
        library.cancelHistoryClear()
        windows.downloads.cancelHistoryClear()
        window?.ignoresMouseEvents = true
        clearIndicators()
        isResizing = false
        waitsForPointerEntry = false
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

    /// Receives only events already addressed to our own nonactivating panel.
    /// The original event is replayed through native text input after the field appears,
    /// preserving the first character, dead keys, keyboard layouts and IME composition.
    func handleSearchKeyDown(_ event: NSEvent) -> Bool {
        guard isPresented, event.type == .keyDown, !editor.isEditing,
              window?.attachedSheet == nil else { return false }
        let textInput = window?.firstResponder as? NSTextView
        if textInput?.hasMarkedText() == true { return false }
        if event.keyCode == 53 {
            if editor.isSearchVisible { editor.endSearch() }
            else { hide() }
            return true
        }
        guard library.showsSidebarSearch, textInput?.isFieldEditor != true,
              !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
              let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
        else { return false }
        editor.beginSearch(with: event)
        return true
    }

    private var hasSearchFocus: Bool {
        library.showsSidebarSearch && window?.isKeyWindow == true
            && (window?.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    private func pollMouse() { pollMouse(at: NSEvent.mouseLocation, now: Date()) }

    func pollMouse(at point: NSPoint, now: Date) {
        if isBlockedByFullScreen { refreshFullScreenAvailability(); return }
        guard let window, now >= suppressedUntil else { return }
        if library.separatesSections { pollSeparatedPanels(at: point, now: now); return }
        if isPresented {
            let containsPointer = window.frame.insetBy(dx: -8, dy: -8).contains(point)
            if containsPointer { waitsForPointerEntry = false }
            // Menu and shortcut actions open the panel away from the pointer.
            // Start pointer-exit dismissal only after the user reaches it.
            if waitsForPointerEntry || isResizing || editor.isEditing || hasSearchFocus { leftPanelAt = nil; return }
            let holdsOpeningEdge = !library.showsRevealIndicator && window.screen.map {
                Self.isAtLeftEdge(point, screenFrame: $0.frame, visibleFrame: $0.visibleFrame)
            } == true
            if containsPointer || holdsOpeningEdge || window.attachedSheet != nil {
                leftPanelAt = nil
            } else {
                if let leftPanelAt, now.timeIntervalSince(leftPanelAt) >= 0.5 { hide() }
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

    static func clampedWidth(_ preferred: CGFloat, screenFrame: NSRect, visibleFrame: NSRect, separated: Bool = false) -> CGFloat {
        let maximum = max(1, min(screenFrame.width / 4, visibleFrame.width))
        return min(maximum, max(min(separated ? 180 : 200, maximum), preferred.isFinite ? preferred : 300))
    }

    func resize(to preferred: CGFloat) {
        guard let window, let screen = window.screen else { return }
        stopAnimation()
        reveal.progress = 1
        reveal.shoulderProgress = 1
        var frame = window.frame
        frame.origin.x = screen.frame.minX
        frame.size.width = Self.clampedWidth(preferred, screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                            separated: editor.activeSection != nil)
        window.setFrame(frame, display: true)
        presentedFrame = frame
    }

    private func finishResizing() {
        isResizing = false
        leftPanelAt = nil
        if let width = window?.frame.width { library.setWidth(width, for: editor.activeSection) }
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
        guard indicatorWindow == nil, !isBlockedByFullScreen else { return }
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

    private func clearIndicators() {
        indicatorWindow?.orderOut(nil)
        indicatorWindow = nil
        sectionIndicators.values.forEach { $0.orderOut(nil) }
        sectionIndicators.removeAll()
        hoveredSection = nil
        sectionEnteredAt = nil
    }

    /// Fixed quarter-screen anchors build muscle memory; the pane grows around its own tab.
    static func sectionIndicatorFrame(index: Int, visibleFrame: NSRect) -> NSRect {
        let slot = visibleFrame.height / 4
        let height = min(70, slot - 4)
        let center = visibleFrame.maxY - slot * (CGFloat(index) + 0.5)
        return NSRect(x: visibleFrame.minX, y: center - height / 2, width: 30, height: max(1, height))
    }

    static func sectionPanelFrame(index: Int, screenFrame: NSRect, visibleFrame: NSRect, preferredWidth: CGFloat) -> NSRect {
        let anchor = sectionIndicatorFrame(index: index, visibleFrame: visibleFrame)
        let height = min(460, max(280, visibleFrame.height * 0.5), visibleFrame.height)
        let y = min(max(anchor.midY - height / 2, visibleFrame.minY), visibleFrame.maxY - height)
        return NSRect(x: screenFrame.minX, y: y,
                      width: clampedWidth(preferredWidth, screenFrame: screenFrame, visibleFrame: visibleFrame, separated: true),
                      height: height)
    }

    private func showSectionIndicators(on screen: NSScreen) {
        for (index, section) in library.sectionOrder.enumerated() {
            var frame = Self.sectionIndicatorFrame(index: index, visibleFrame: screen.visibleFrame)
            frame.origin.x = screen.frame.minX
            let indicator: NSPanel
            if let existing = sectionIndicators[section] { indicator = existing }
            else {
                indicator = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                indicator.backgroundColor = .clear
                indicator.isOpaque = false
                indicator.hasShadow = false
                indicator.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
                indicator.hidesOnDeactivate = false
                indicator.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = SidebarRevealView(frame: NSRect(origin: .zero, size: frame.size))
                view.section = section
                view.toolTip = section.title
                view.setAccessibilityLabel(section.title)
                view.onPress = { [weak self] in self?.present(on: screen, manual: true, section: section) }
                indicator.contentView = view
                sectionIndicators[section] = indicator
            }
            (indicator.contentView as? SidebarRevealView)?.isSelected = isPresented && editor.activeSection == section
            indicator.setFrame(frame, display: true)
            indicator.orderFrontRegardless()
        }
    }

    private func pollSeparatedPanels(at point: NSPoint, now: Date) {
        guard let window, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            if isPresented { hide() } else { clearIndicators() }
            return
        }
        let nearEdge = point.x >= screen.frame.minX && point.x <= screen.frame.minX + 36
            && point.y >= screen.visibleFrame.minY && point.y <= screen.visibleFrame.maxY
        let screenID = ObjectIdentifier(screen)
        if nearEdge {
            if edgeScreenID != screenID { edgeEnteredAt = now; edgeScreenID = screenID }
            if let edgeEnteredAt, now.timeIntervalSince(edgeEnteredAt) >= 0.25 { showSectionIndicators(on: screen) }
        }
        if let hit = library.sectionOrder.first(where: { sectionIndicators[$0]?.frame.contains(point) == true }) {
            leftPanelAt = nil
            if hoveredSection != hit { hoveredSection = hit; sectionEnteredAt = now }
            if !isResizing, !editor.isEditing, !isPresented || editor.activeSection != hit,
               let entered = sectionEnteredAt, now.timeIntervalSince(entered) >= 0.12 {
                present(on: screen, manual: false, section: hit)
            }
            return
        }
        hoveredSection = nil
        sectionEnteredAt = nil
        if isPresented {
            let containsPointer = window.frame.insetBy(dx: -8, dy: -8).contains(point)
            if containsPointer { waitsForPointerEntry = false }
            if containsPointer || nearEdge || waitsForPointerEntry || isResizing || editor.isEditing || hasSearchFocus || window.attachedSheet != nil {
                leftPanelAt = nil
            } else if let leftPanelAt, now.timeIntervalSince(leftPanelAt) >= 0.5 { hide() }
            else if leftPanelAt == nil { leftPanelAt = now }
        } else if !nearEdge {
            clearIndicators()
            edgeScreenID = nil
            edgeEnteredAt = nil
        }
    }

    func closePreview(_ id: UUID) {
        let wasPresented = isPresented
        isClosingPreview = wasPresented
        windows.closeFromSidebar(id)
        guard wasPresented else { return }
        leftPanelAt = nil
        // Closing a page can change the app's Dock/key-window state. Keep the
        // sidebar focused through those callbacks, without reopening a dismissed panel.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isPresented { self.window?.makeKeyAndOrderFront(nil) }
            DispatchQueue.main.async { [weak self] in self?.isClosingPreview = false }
        }
    }

    func windowDidResignKey(_ notification: Notification) { dismissForFocusChange() }

    private func dismissForFocusChange() {
        guard isPresented, !isClosingPreview, !isResizing, !editor.isEditing, window?.attachedSheet == nil else { return }
        hide()
    }

    private func present(on screen: NSScreen, manual: Bool, section: SidebarSection? = nil) {
        guard let window, !isBlockedByFullScreen else { return }
        let selected = library.separatesSections ? (section ?? editor.activeSection ?? library.sectionOrder.first) : nil
        if editor.activeSection != selected { editor.endSearch(); editor.cancel() }
        editor.activeSection = selected
        waitsForPointerEntry = manual
        library.resetRecentDisplayLimit()
        windows.downloads.resetHistoryDisplayLimit()
        library.cancelHistoryClear()
        windows.downloads.cancelHistoryClear()
        leftPanelAt = nil
        if selected != nil { showSectionIndicators(on: screen) }
        else { clearIndicators() }
        let frame: NSRect
        if let selected, let index = library.sectionOrder.firstIndex(of: selected) {
            frame = Self.sectionPanelFrame(index: index, screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                           preferredWidth: library.width(for: selected))
        } else {
            frame = Self.panelFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, preferredWidth: library.sidebarWidth)
        }
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
        // A nonactivating NSPanel can own keyboard focus while the user's app stays
        // active. Search off preserves the previous passive hover behavior.
        if manual { window.makeKeyAndOrderFront(nil) }
        else {
            window.orderFrontRegardless()
            if library.showsSidebarSearch { window.makeKey() }
        }
        if library.showsSidebarSearch && !editor.isSearchVisible && !editor.isEditing { window.makeFirstResponder(nil) }
        if selected != nil { showSectionIndicators(on: screen) }
        if reduceMotion() { reveal.progress = 1; reveal.shoulderProgress = 1 }
        else { animate(to: 1, opening: true) }
    }

    private var isBlockedByFullScreen: Bool {
        library.hidesInFullScreen && presentationOptions().contains(.fullScreen)
    }

    func refreshFullScreenAvailability() {
        guard isBlockedByFullScreen else { return }
        hide(animated: false)
        edgeEnteredAt = nil
        edgeScreenID = nil
        leftPanelAt = nil
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
    var section: SidebarSection?
    var isSelected = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("Show sidebar"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if let section {
            let path = NSBezierPath(cgPath: SidebarContour().path(in: bounds).cgPath)
            NSColor.black.setFill()
            path.fill()
            if isSelected {
                NSColor.white.withAlphaComponent(0.12).setFill()
                path.fill()
            }
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let icon = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)?.withSymbolConfiguration(config) {
                let rect = NSRect(x: 7, y: bounds.midY - 8, width: 16, height: 16)
                icon.draw(in: rect)
            }
            return
        }
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

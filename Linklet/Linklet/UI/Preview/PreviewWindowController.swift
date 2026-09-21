import AppKit
import Combine
import SwiftUI

private final class PreviewWindow: NSWindow {
    var onEscape: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown,
              !event.isARepeat
        else {
            super.sendEvent(event)
            return
        }

        let commandModifiers = event.modifierFlags.intersection([
            .command,
            .control,
            .option,
            .shift
        ])

        if event.keyCode == 53, commandModifiers.isEmpty {
            if let onEscape { onEscape() } else { performClose(nil) }
            return
        }

        // Space belongs to the page, including WebKit text fields and media controls.
        super.sendEvent(event)
    }
}

@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    private static let initialContentSize = NSSize(width: 900, height: 650)
    private unowned let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private var hasAppliedInitialSize = false
    private var initialPositionReferenceFrame: NSRect?

    var isVisible: Bool { window?.isVisible == true }

    init(model: AppModel) {
        self.model = model

        let panel = PreviewWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Linklet"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.tabbingMode = .disallowed
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.minSize = NSSize(width: 640, height: 440)
        panel.level = model.keepsPreviewVisibleWhenInactive && model.keepsPreviewAboveOtherWindows
            ? .floating
            : .normal
        panel.hidesOnDeactivate = !model.keepsPreviewVisibleWhenInactive
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: panel)
        panel.delegate = self
        Publishers.CombineLatest(model.previewSession.$pageTitle, model.previewSession.$currentURL)
            .map { pageTitle, url in
                let title = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { return title }
                if let host = url?.host, !host.isEmpty { return host }
                return L("Preview")
            }
            .removeDuplicates()
            .sink { [weak panel] title in panel?.title = title }
            .store(in: &cancellables)
        panel.onEscape = { [weak model, weak panel] in
            if model?.isChoosingDataMode == true { model?.completeDataChoice(save: false) }
            else { panel?.performClose(nil) }
        }
        let hostingController = NSHostingController(rootView: PreviewRootView(model: model))
        // AppKit owns the window size; the initially empty WebView must not shrink it.
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController

        Publishers.CombineLatest(
            model.$keepsPreviewVisibleWhenInactive,
            model.$keepsPreviewAboveOtherWindows
        )
            .removeDuplicates { previous, current in
                previous.0 == current.0 && previous.1 == current.1
            }
            .sink { [weak panel] settings in
                let (keepsVisible, staysAbove) = settings
                panel?.hidesOnDeactivate = !keepsVisible
                panel?.level = keepsVisible && staysAbove ? .floating : .normal
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func prepare() {
        guard let window else { return }
        _ = window.contentViewController?.view
        window.contentView?.layoutSubtreeIfNeeded()
        if !hasAppliedInitialSize {
            window.setContentSize(Self.initialContentSize)
            window.contentView?.layoutSubtreeIfNeeded()
            hasAppliedInitialSize = true
        }
    }

    func positionInitially(after frame: NSRect) {
        initialPositionReferenceFrame = frame
    }

    func show(url: URL) {
        present(initialURL: url) { model.previewSession.load(url) }
    }

    func showDataChoice(for url: URL) { present(initialURL: url) {} }

    func showWelcome() {
        present { model.previewSession.showWelcome(isDefault: model.isDefaultBrowser) }
    }

    private func present(initialURL: URL? = nil, load: () -> Void) {
        guard let window else { return }
        prepare()
        // Become a regular app before activation so macOS records this open as
        // the latest Command-Tab activity rather than appending us to the end.
        model.makeAppVisibleInDock()
        let animatesAppearance = !window.isVisible
        if animatesAppearance {
            if let initialURL, let savedFrame = model.savedWindowFrame(for: initialURL) {
                restore(savedFrame, in: window)
            } else {
                placeInitially(window)
            }
            window.alphaValue = 0
        }

        load()
        window.contentView?.layoutSubtreeIfNeeded()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        model.updateDockVisibilitySoon()

        if animatesAppearance {
            DispatchQueue.main.async { [weak window] in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    window?.animator().alphaValue = 1
                }
            }
        }
    }

    private func placeInitially(_ window: NSWindow) {
        guard let referenceFrame = initialPositionReferenceFrame else {
            window.center()
            return
        }
        initialPositionReferenceFrame = nil
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(referenceFrame) }
            ?? NSScreen.main
        guard let screen else {
            window.center()
            return
        }
        let visibleFrame = screen.visibleFrame
        let size = window.frame.size
        let proposed = NSPoint(x: referenceFrame.origin.x + 24, y: referenceFrame.origin.y - 24)
        let origin = NSPoint(
            x: min(max(proposed.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(proposed.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
        window.setFrameOrigin(origin)
    }

    private func restore(_ frame: NSRect, in window: NSWindow) {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        guard let screen else {
            window.center()
            return
        }
        window.setFrame(WindowGeometryService.clamped(frame, to: screen.visibleFrame), display: false)
    }

    func windowDidMove(_ notification: Notification) {
        if let window { model.saveWindowFrame(window.frame) }
    }

    func windowDidResize(_ notification: Notification) {
        if let window { model.saveWindowFrame(window.frame) }
    }

    func windowWillClose(_ notification: Notification) {
        model.previewDidEnd()
    }
}

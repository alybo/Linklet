import AppKit
import Combine
import SwiftUI

@MainActor
enum PreviewWindowAppearance {
    static let initialContentSize = NSSize(width: 900, height: 650)
    static let minimumSize = NSSize(width: 640, height: 440)

    static var screenAtPointer: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    }

    static func place(_ window: NSWindow, on screen: NSScreen?, after reference: NSRect? = nil) {
        guard let visible = screen?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        let origin = reference.map { NSPoint(x: $0.minX + 24, y: $0.maxY - size.height - 24) }
            ?? NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window.setFrame(WindowGeometryService.clamped(NSRect(origin: origin, size: size), to: visible), display: false)
    }

    static func apply(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        // WebKit refreshes hover and CSS cursors on mouse moves, including after
        // editing and dragging. NSWindow does not deliver these by default.
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .none
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.minSize = minimumSize
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
    }
}

final class PreviewWindow: NSWindow {
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
            // Local address handling consumes Escape outside IME composition.
            // Let native text input handle a remaining marked-text cancellation.
            if let editor = firstResponder as? NSTextView, editor.isFieldEditor {
                super.sendEvent(event)
                return
            }
            performClose(nil)
            return
        }

        // Space belongs to the page, including WebKit text fields and media controls.
        super.sendEvent(event)
    }
}

@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    private static let initialContentSize = PreviewWindowAppearance.initialContentSize
    private unowned let model: AppModel
    private var cancellables = Set<AnyCancellable>()
    private var geometry: WebsiteWindowGeometry!
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
        PreviewWindowAppearance.apply(to: panel)
        panel.level = model.keepsPreviewVisibleWhenInactive && model.keepsPreviewAboveOtherWindows
            ? .floating
            : .normal
        panel.hidesOnDeactivate = !model.keepsPreviewVisibleWhenInactive
        super.init(window: panel)
        panel.delegate = self
        geometry = WebsiteWindowGeometry(window: panel, service: model.windowGeometry)
        model.previewSession.onWindowURLCommitted = { [weak self] url in self?.geometry.committed(url) }
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
        let hostingController = NSHostingController(rootView: PreviewRootView(model: model))
        // AppKit owns the window size; the initially empty WebView must not shrink it.
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController
        hostingController.view.setAccessibilityIdentifier("Linklet.PreviewChrome")

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

    func show(url: URL, restoring position: PagePosition? = nil) {
        present(initialURL: url) {
            model.previewSession.load(url, restoring: position)
        }
    }

    func showWelcome() {
        present { model.previewSession.showWelcome(isDefault: model.isDefaultBrowser) }
    }

    private func present(initialURL: URL? = nil, load: () -> Void) {
        guard let window else { return }
        prepare()
        // Become a regular app before activation so macOS records this open as
        // the latest Command-Tab activity rather than appending us to the end.
        model.makeAppVisibleInDock()
        if !window.isVisible {
            window.setContentSize(Self.initialContentSize)
            let reference = initialPositionReferenceFrame
            initialPositionReferenceFrame = nil
            let screen = reference.flatMap { frame in
                NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
            } ?? PreviewWindowAppearance.screenAtPointer
            if !geometry.begin(at: initialURL, fallbackScreen: screen) {
                PreviewWindowAppearance.place(window, on: screen, after: reference)
            }
        } else { _ = geometry.begin(at: initialURL) }
        load()
        window.contentView?.layoutSubtreeIfNeeded()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let page = model.previewSession.webView, page.window === window {
            window.makeFirstResponder(page)
        }
        model.windowRegistry.register(window, session: model.previewSession)
        model.updateDockVisibilitySoon()
    }

    func windowDidMove(_ notification: Notification) {
        geometry.save()
    }

    func windowDidResize(_ notification: Notification) {
        geometry.save()
    }

    func windowWillClose(_ notification: Notification) {
        geometry.save()
        model.previewDidEnd()
    }
}

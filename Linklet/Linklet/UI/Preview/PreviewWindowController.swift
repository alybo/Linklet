import AppKit
import Combine
import SwiftUI

private final class PreviewPanel: NSPanel {
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
            performClose(nil)
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

    init(model: AppModel) {
        self.model = model

        let panel = PreviewPanel(
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

    func show(url: URL) {
        present { model.previewSession.load(url) }
    }

    func showWelcome() {
        present { model.previewSession.showWelcome(isDefault: model.isDefaultBrowser) }
    }

    private func present(load: () -> Void) {
        guard let window else { return }
        prepare()
        let animatesAppearance = !window.isVisible
        if animatesAppearance {
            window.center()
            window.alphaValue = 0
        }

        load()
        window.contentView?.layoutSubtreeIfNeeded()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)

        if animatesAppearance {
            DispatchQueue.main.async { [weak window] in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    window?.animator().alphaValue = 1
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.previewSession.stopLoading()
    }
}

import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let contentSize = NSSize(width: 900, height: 720)
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.title = model.settingsPage.title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let splitController = SettingsSplitViewController(model: model)
        splitController.view.setFrameSize(Self.contentSize)
        window.contentViewController = splitController
        // Installing the controller adopts its view's initial size.
        window.contentMinSize = NSSize(width: 800, height: 600)
        window.setContentSize(Self.contentSize)
        window.center()
        window.setFrameAutosaveName("Linklet.Settings")
        splitController.configureWindow(window)
        super.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        model?.settingsDidClose(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Native sidebar behavior keeps the titlebar split aligned with the content,
/// including on macOS versions where a hosted NavigationSplitView moves its title.
@MainActor
final class SettingsSplitViewController: NSSplitViewController, NSToolbarDelegate {
    private var subscriptions = Set<AnyCancellable>()
    private var currentPage: SettingsPage
    private static let separatorID = NSToolbarItem.Identifier("Linklet.Settings.Divider")

    init(model: AppModel) {
        currentPage = model.settingsPage
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let sidebar = NSHostingController(rootView: SettingsSidebarView(model: model))
        sidebar.sizingOptions = []
        let detail = NSHostingController(rootView: SettingsDetailView(model: model))
        detail.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = SettingsDesignMetrics.sidebarWidth
        sidebarItem.maximumThickness = SettingsDesignMetrics.sidebarWidth
        sidebarItem.preferredThicknessFraction = SettingsDesignMetrics.sidebarWidth / 900
        sidebarItem.canCollapse = false
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.titlebarSeparatorStyle = .none
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 500
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        model.$settingsPage.removeDuplicates().sink { [weak self] page in
            guard let self else { return }
            self.currentPage = page
            self.updateWindowTitle()
        }.store(in: &subscriptions)
        AppLanguage.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateWindowTitle() }
        }.store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let window = view.window { configureWindow(window) }
    }

    func configureWindow(_ window: NSWindow) {
        guard window.toolbar?.delegate as? SettingsSplitViewController !== self else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        let toolbar = NSToolbar(identifier: "Linklet.Settings.Toolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        updateWindowTitle()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.separatorID, .flexibleSpace]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.separatorID else { return nil }
        return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 0)
    }

    private func updateWindowTitle() {
        view.window?.title = currentPage.title
    }
}

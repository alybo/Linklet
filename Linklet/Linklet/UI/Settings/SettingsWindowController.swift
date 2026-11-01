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
        // Installing a content controller adopts its view's size. Apply the window
        // bounds afterwards, so an initially empty Form cannot collapse the window.
        window.contentMinSize = NSSize(width: 800, height: 600)
        window.setContentSize(Self.contentSize)
        window.center()
        window.setFrameAutosaveName("Linklet.Settings")
        splitController.configureWindow(window)
        super.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        model?.updateDockVisibilitySoon()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Native sidebar behavior keeps the titlebar split aligned with the content,
/// including on macOS versions where a hosted NavigationSplitView moves its title.
@MainActor
final class SettingsSplitViewController: NSSplitViewController, NSToolbarDelegate {
    private let model: AppModel
    private var subscriptions = Set<AnyCancellable>()
    private var currentPage: SettingsPage
    private var backPages: [SettingsPage] = []
    private var forwardPages: [SettingsPage] = []
    private var isNavigatingHistory = false
    private let navigation = NSSegmentedControl(images: [
        NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)!,
        NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!
    ], trackingMode: .momentary, target: nil, action: nil)
    private let heading = NSTextField(labelWithString: "")
    private static let separatorID = NSToolbarItem.Identifier("Linklet.Settings.Divider")
    private static let navigationID = NSToolbarItem.Identifier("Linklet.Settings.Navigation")
    private static let headingID = NSToolbarItem.Identifier("Linklet.Settings.Heading")

    init(model: AppModel) {
        self.model = model
        currentPage = model.settingsPage
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let sidebar = NSHostingController(rootView: SettingsSidebarView(model: model))
        sidebar.sizingOptions = []
        let detail = NSHostingController(rootView: SettingsDetailView(model: model))
        detail.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 250
        sidebarItem.maximumThickness = 280
        sidebarItem.preferredThicknessFraction = 0.29
        sidebarItem.canCollapse = false
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.titlebarSeparatorStyle = .none
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 500
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        navigation.target = self
        navigation.action = #selector(navigate(_:))
        navigation.setWidth(32, forSegment: 0)
        navigation.setWidth(32, forSegment: 1)
        navigation.setAccessibilityIdentifier("Linklet.Settings.Navigation")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.setContentCompressionResistancePriority(.required, for: .horizontal)
        model.$settingsPage.removeDuplicates().sink { [weak self] page in
            guard let self else { return }
            if page != self.currentPage {
                if !self.isNavigatingHistory {
                    self.backPages.append(self.currentPage)
                    self.forwardPages.removeAll()
                }
                self.currentPage = page
            }
            self.updateToolbar()
        }.store(in: &subscriptions)
        AppLanguage.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateToolbar() }
        }.store(in: &subscriptions)
        updateToolbar()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let window = view.window { configureWindow(window) }
        model.refreshTargets()
    }

    func configureWindow(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        if window.toolbar?.delegate as? SettingsSplitViewController !== self {
            let toolbar = NSToolbar(identifier: "Linklet.Settings.Toolbar")
            toolbar.delegate = self
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
        }
        updateToolbar()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.separatorID, Self.navigationID, Self.headingID, .flexibleSpace]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.separatorID {
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 0)
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == Self.navigationID { item.view = navigation; item.label = L("Navigation") }
        else if identifier == Self.headingID { item.view = heading; item.label = currentPage.title }
        else { return nil }
        return item
    }

    private func updateToolbar() {
        heading.stringValue = currentPage.title
        heading.sizeToFit()
        view.window?.title = currentPage.title
        navigation.setEnabled(!backPages.isEmpty, forSegment: 0)
        navigation.setEnabled(!forwardPages.isEmpty, forSegment: 1)
        navigation.setToolTip(L("Back"), forSegment: 0)
        navigation.setToolTip(L("Forward"), forSegment: 1)
    }

    @objc private func navigate(_ sender: NSSegmentedControl) {
        navigate(back: sender.selectedSegment == 0)
    }

    func navigate(back: Bool) {
        let page: SettingsPage
        if back {
            guard let previous = backPages.popLast() else { return }
            forwardPages.append(currentPage)
            page = previous
        } else {
            guard let next = forwardPages.popLast() else { return }
            backPages.append(currentPage)
            page = next
        }
        isNavigatingHistory = true
        model.settingsPage = page
        isNavigatingHistory = false
    }
}

struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .large
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("Linklet.Settings.Search")
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.owner = self
        field.placeholderString = L("Search settings")
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var owner: SettingsSearchField
        init(_ owner: SettingsSearchField) { self.owner = owner }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { owner.text = field.stringValue }
        }
    }
}

import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let contentSize = NSSize(width: 860, height: 660)
    private weak var model: AppModel?
    private var subscriptions = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = model.settingsPage.title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let hostingController = NSHostingController(rootView: SettingsView(model: model))
        hostingController.sizingOptions = []
        hostingController.view.setFrameSize(Self.contentSize)
        window.contentViewController = hostingController
        // Installing a content controller adopts its view's size. Apply the window
        // bounds afterwards, so an initially empty Form cannot collapse the window.
        window.contentMinSize = Self.contentSize
        window.contentMaxSize = Self.contentSize
        window.setContentSize(Self.contentSize)
        window.center()
        super.init(window: window)
        window.delegate = self
        model.$settingsPage.sink { [weak window] page in window?.title = page.title }.store(in: &subscriptions)
    }

    func windowWillClose(_ notification: Notification) { model?.settingsDidClose() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

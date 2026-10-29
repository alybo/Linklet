import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var isStoppingDownloads = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startSearchShortcut()
        model.startSidebar()
        model.refreshTargets()
        model.showWelcomeIfNeeded()
        model.appUpdates.start()
        model.startSiteDataMaintenance()
        model.updateDockVisibilitySoon()
    }

    func applicationDidResignActive(_ notification: Notification) {
        model.previewApplicationDidHide()
    }

    func applicationDidHide(_ notification: Notification) {
        model.previewApplicationDidHide()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.downloads.cancelAll()
        model.previewDidEnd()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isStoppingDownloads else { return .terminateLater }
        guard model.downloads.hasPendingWork else { return .terminateNow }
        if model.downloads.hasActiveDownloads {
            let alert = NSAlert()
            alert.messageText = L("Downloads in progress")
            alert.informativeText = L("Quitting Linklet will stop unfinished downloads.")
            alert.addButton(withTitle: L("Keep downloading"))
            alert.addButton(withTitle: L("Quit and stop downloads"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        isStoppingDownloads = true
        Task { @MainActor in
            await model.downloads.stopForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshDefaultBrowserStatus()
        model.adBlockService.checkForUpdates()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.handleIncoming(urls: urls)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let closeAll = NSMenuItem(
            title: L("Close All Windows"), action: #selector(closeAllWindowsFromDock(_:)), keyEquivalent: ""
        )
        closeAll.target = self
        closeAll.isEnabled = model.hasOpenWindows
        menu.addItem(closeAll)

        return menu
    }

    @objc private func closeAllWindowsFromDock(_ sender: Any?) { model.closeAllWindows() }

}

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.refreshTargets()
        model.showWelcomeIfNeeded()
        model.appUpdates.start()
    }

    func applicationDidResignActive(_ notification: Notification) {
        model.previewApplicationDidHide()
    }

    func applicationDidHide(_ notification: Notification) {
        model.previewApplicationDidHide()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.previewDidEnd()
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
}

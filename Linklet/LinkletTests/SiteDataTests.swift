import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Linklet

@MainActor
final class SiteDataTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var store: WKWebsiteDataStore!
    private var data: SiteDataService!

    override func setUp() {
        super.setUp()
        suite = "Linklet.SiteDataTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        store = .nonPersistent()
        data = SiteDataService(defaults: defaults, persistentStore: store)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        data = nil
        store = nil
        defaults = nil
        super.tearDown()
    }

    private func cookie(_ domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: "/", .name: "session", .value: "fixture", .expires: Date().addingTimeInterval(86400 * 365)])!
    }

    func testTemporarySessionEndsOnCloseAndUsesNewStore() async throws {
        XCTAssertFalse(data.isEnabled)
        XCTAssertFalse(data.hasChosenMode)
        let session = PreviewSession(adBlockService: AdBlockService(defaults: defaults), siteData: data)
        let original = session.websiteDataStore
        await original.httpCookieStore.setCookie(cookie("example.org"))
        session.load(URL(string: "https://example.org")!)
        session.endSession()
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.currentURL)
        XCTAssertFalse(original === session.websiteDataStore)
        let cookies = await session.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.isEmpty)
        XCTAssertNil(defaults.object(forKey: SiteDataService.visitsKey))
    }

    func testSavingSurvivesSessionEndAndDisablingDeletesCookiesAndDates() async throws {
        await data.setEnabled(true)
        XCTAssertTrue(data.hasChosenMode)
        await store.httpCookieStore.setCookie(cookie("example.org"))
        data.recordVisit(URL(string: "https://example.org")!)
        let session = PreviewSession(adBlockService: AdBlockService(defaults: defaults), siteData: data)
        session.endSession()
        XCTAssertTrue(session.websiteDataStore === store)
        let savedCookies = await store.httpCookieStore.allCookies()
        XCTAssertEqual(savedCookies.count, 1)
        let restored = SiteDataService(defaults: defaults, persistentStore: store)
        XCTAssertTrue(restored.isEnabled)
        XCTAssertNotNil(restored.lastVisit(for: "example.org"))
        await data.setEnabled(false)
        let clearedCookies = await store.httpCookieStore.allCookies()
        XCTAssertTrue(clearedCookies.isEmpty)
        XCTAssertFalse(data.isEnabled)
        XCTAssertNil(data.lastVisit(for: "example.org"))
    }

    func testRelatedPrivateWindowsKeepCookiesUntilTheLastWindowCloses() async throws {
        let blocker = AdBlockService(defaults: defaults, automaticUpdates: false)
        let parent = PreviewSession(adBlockService: blocker, siteData: data)
        parent.load(URL(string: "https://example.org/source")!)
        let sharedStore = parent.websiteDataStore
        await sharedStore.httpCookieStore.setCookie(cookie("example.org"))
        let configuration = WebPreview.configuration(websiteDataStore: sharedStore)
        let first = PreviewSession(adBlockService: blocker, siteData: data, windowRegistry: parent.windowRegistry)
        let second = PreviewSession(adBlockService: blocker, siteData: data, windowRegistry: parent.windowRegistry)
        let firstView = WKWebView(frame: .zero, configuration: configuration)
        let secondView = WKWebView(frame: .zero, configuration: configuration)
        first.adoptPopup(firstView, from: parent)
        second.adoptPopup(secondView, from: first)
        XCTAssertTrue(first.websiteDataStore === sharedStore)
        XCTAssertTrue(second.websiteDataStore === sharedStore)
        parent.endSession()
        XCTAssertFalse(parent.websiteDataStore === sharedStore)
        first.endSession()
        let remainingCookies = await second.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(remainingCookies.contains { $0.name == "session" })
        second.endSession()
        for _ in 0..<50 {
            if await sharedStore.httpCookieStore.allCookies().isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let clearedCookies = await sharedStore.httpCookieStore.allCookies()
        XCTAssertTrue(clearedCookies.isEmpty, "Private cookies clear after the last related page closes")
    }

    func testInactivityUsesTopLevelVisitsAndDoesNotMatchSimilarDomains() async throws {
        let now = Date()
        await data.setEnabled(true)
        data.setInactiveDays(30)
        for domain in ["old.example", "recent.example", "embedded.example"] {
            await store.httpCookieStore.setCookie(cookie(domain))
        }
        data.recordVisit(URL(string: "https://account.old.example")!, now: now.addingTimeInterval(-31 * 86400))
        data.recordVisit(URL(string: "https://recent.example")!, now: now.addingTimeInterval(-2 * 86400))
        // Merely reading the stored records must not refresh last visits.
        await data.refresh()
        await data.performIdleMaintenance(now: now)
        var domains = Set(await store.httpCookieStore.allCookies().map(\.domain))
        XCTAssertFalse(domains.contains("old.example"))
        XCTAssertTrue(domains.contains("recent.example"))
        XCTAssertTrue(domains.contains("embedded.example"))
        await data.performIdleMaintenance(now: now.addingTimeInterval(31 * 86400))
        domains = Set(await store.httpCookieStore.allCookies().map(\.domain))
        XCTAssertTrue(domains.isEmpty)
        XCTAssertTrue(SiteDataService.host("accounts.example.co.uk", belongsTo: "example.co.uk"))
        XCTAssertFalse(SiteDataService.host("notexample.co.uk", belongsTo: "example.co.uk"))
        XCTAssertFalse(SiteDataService.host("example.co.uk.evil.org", belongsTo: "example.co.uk"))
    }

    func testIdleMaintenanceDefersExpiryWhileAPreviewIsActive() async throws {
        let now = Date()
        await data.setEnabled(true)
        data.setInactiveDays(7)
        await store.httpCookieStore.setCookie(cookie("old.example"))
        data.recordVisit(URL(string: "https://old.example")!, now: now.addingTimeInterval(-8 * 86400))

        let session = PreviewSession(adBlockService: AdBlockService(defaults: defaults), siteData: data)
        session.load(URL(string: "https://new.example")!)
        await data.performIdleMaintenance(now: now)
        var cookies = await store.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.domain == "old.example" })

        session.endSession()
        await data.performIdleMaintenance(now: now)
        cookies = await store.httpCookieStore.allCookies()
        XCTAssertFalse(cookies.contains { $0.domain == "old.example" })
    }

    func testDeletingOneWebsitePreservesOtherCookies() async throws {
        await data.setEnabled(true)
        await store.httpCookieStore.setCookie(cookie("one.example"))
        await store.httpCookieStore.setCookie(cookie("two.example"))
        await data.refresh()
        let record = try XCTUnwrap(data.records.first { $0.displayName == "one.example" })
        await data.delete(record)
        let cookies = await store.httpCookieStore.allCookies()
        XCTAssertEqual(cookies.map(\.domain), ["two.example"])
    }

    func testInactivityBoundaryAndDisabledCleanup() {
        let now = Date()
        XCTAssertFalse(SiteDataService.isExpired(lastActivity: now.addingTimeInterval(-29 * 86400), days: 30, now: now))
        XCTAssertTrue(SiteDataService.isExpired(lastActivity: now.addingTimeInterval(-30 * 86400), days: 30, now: now))
        XCTAssertFalse(SiteDataService.isExpired(lastActivity: .distantPast, days: 0, now: now))
        XCTAssertFalse(SiteDataService.isExpired(lastActivity: now.addingTimeInterval(3600), days: 30, now: now))
    }

    func testManualBrowserOrderSurvivesAutoSortAndDiscovery() {
        let browsers = ["A", "B", "C"].map { BrowserTarget.browser(name: $0, applicationURL: URL(fileURLWithPath: "/Applications/\($0).app")) }
        let model = AppModel(defaults: defaults, siteData: data, discoverTargets: { browsers })
        model.refreshTargets()
        model.setSortTargetsByUsage(false)
        model.moveTarget(browsers[2].id, before: browsers[0].id)
        XCTAssertEqual(model.visibleTargets.map(\.displayName), ["C", "A", "B"])
        model.setSortTargetsByUsage(true)
        model.moveTarget(browsers[0].id, before: browsers[2].id)
        model.setSortTargetsByUsage(false)
        model.refreshTargets()
        XCTAssertEqual(model.visibleTargets.map(\.displayName), ["C", "A", "B"])
        model.setTargetVisible(browsers[2], isVisible: false)
        XCTAssertEqual(model.preferredTarget?.displayName, "A")
        model.resetTargetUsage()
        model.setTargetVisible(browsers[2], isVisible: true)
        let restored = AppModel(defaults: defaults, siteData: data, discoverTargets: { browsers.reversed() })
        restored.refreshTargets()
        XCTAssertEqual(restored.visibleTargets.map(\.displayName), ["C", "A", "B"])
    }

    func testFirstLinkOpensImmediatelyWithTemporaryData() {
        let model = AppModel(defaults: defaults, siteData: data, discoverTargets: { [] })
        let url = URL(string: "http://127.0.0.1:9/original")!
        model.showPreview(url: url)
        defer { model.closeAllWindows() }
        XCTAssertFalse(data.isEnabled)
        XCTAssertTrue(data.hasChosenMode)
        XCTAssertTrue(model.previewSession.isActive)
        XCTAssertEqual(model.previewSession.originalURL, url)
        XCTAssertFalse(model.isWelcomeVisible)
        model.showWelcomeIfNeeded()
        XCTAssertFalse(model.isWelcomeVisible, "An incoming link takes priority over first-run instructions")
    }

    func testReopeningWelcomePreservesPageAndIncomingLinkClosesWelcome() {
        let model = AppModel(defaults: defaults, siteData: data, discoverTargets: { [] })
        let original = URL(string: "http://127.0.0.1:9/original")!
        model.setPreviewWindowBehavior(.keepOpen)
        model.showPreview(url: original)
        defer { model.closeAllWindows() }
        model.showWelcome()
        XCTAssertTrue(model.isWelcomeVisible)
        XCTAssertTrue(model.previewSession.isActive)
        XCTAssertEqual(model.previewSession.originalURL, original)
        XCTAssertEqual(model.windowRegistry.activeSessions.count, 1, "Welcome must not enter the live-page registry")
        let next = URL(string: "http://127.0.0.1:9/next")!
        model.showPreview(url: next)
        XCTAssertFalse(model.isWelcomeVisible)
        XCTAssertEqual(model.previewSession.originalURL, next)
        XCTAssertFalse(data.isEnabled, "Opening a link must not enable permanent storage")
    }

    func testFirstLinkPreservesAnExistingStoragePreference() {
        defaults.set(true, forKey: SiteDataService.enabledKey)
        let savedData = SiteDataService(defaults: defaults, persistentStore: store)
        let model = AppModel(defaults: defaults, siteData: savedData, discoverTargets: { [] })
        XCTAssertFalse(savedData.hasChosenMode)
        model.showPreview(url: URL(string: "http://127.0.0.1:9/saved")!)
        defer { model.closeAllWindows() }
        XCTAssertTrue(savedData.isEnabled, "Removing the chooser must preserve an existing storage preference")
        XCTAssertTrue(savedData.hasChosenMode)
    }

    func testSettingsNavigationMigratesOldSections() {
        defaults.set("sidebar", forKey: "settingsPage")
        XCTAssertEqual(AppModel(defaults: defaults, siteData: data).settingsPage, .windows)
        defaults.set("browsers", forKey: "settingsPage")
        XCTAssertEqual(AppModel(defaults: defaults, siteData: data).settingsPage, .search)
        defaults.set("sites", forKey: "settingsPage")
        XCTAssertEqual(AppModel(defaults: defaults, siteData: data).settingsPage, .sites)
    }

    func testExplicitBrowserChoiceSurvivesSortingHidingAndRestart() {
        let browsers = ["A", "B", "C"].map { BrowserTarget.browser(name: $0, applicationURL: URL(fileURLWithPath: "/Applications/\($0).app")) }
        let model = AppModel(defaults: defaults, siteData: data, discoverTargets: { browsers })
        model.refreshTargets()
        XCTAssertEqual(model.preferredTargetID, browsers.first?.id)
        model.setPreferredTarget(browsers[2].id)
        model.setSortTargetsByUsage(false)
        XCTAssertEqual(model.preferredTarget?.id, browsers[2].id)
        XCTAssertEqual(model.previewOpenTargets.first?.id, browsers[2].id)
        model.setSortTargetsByUsage(true)
        XCTAssertEqual(model.preferredTarget?.id, browsers[2].id)
        model.setTargetVisible(browsers[2], isVisible: false)
        XCTAssertNotEqual(model.preferredTarget?.id, browsers[2].id)
        model.setTargetVisible(browsers[2], isVisible: true)
        let restored = AppModel(defaults: defaults, siteData: data, discoverTargets: { browsers.reversed() })
        restored.refreshTargets()
        XCTAssertEqual(restored.preferredTarget?.id, browsers[2].id)
    }

    func testHidingPreviewEndsTemporarySession() async throws {
        let model = AppModel(defaults: defaults, siteData: data, discoverTargets: { [] })
        model.showPreview(url: URL(string: "http://127.0.0.1:9/original")!)
        let oldStore = model.previewSession.websiteDataStore
        await oldStore.httpCookieStore.setCookie(cookie("example.org"))
        model.previewApplicationDidHide()
        XCTAssertFalse(model.previewSession.isActive)
        XCTAssertFalse(oldStore === model.previewSession.websiteDataStore)
        let cookies = await model.previewSession.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.isEmpty)
    }

    func testSettingsControllerPreservesUsableSizeAcrossPagesAndReopening() async throws {
        let model = AppModel(defaults: defaults, siteData: data, discoverTargets: { [] })
        let controller = SettingsWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        XCTAssertTrue(window.styleMask.contains(.resizable))
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(150))
        window.setContentSize(NSSize(width: 920, height: 720))
        let chosenSize = window.contentLayoutRect.size
        func assertSize(file: StaticString = #filePath, line: UInt = #line) {
            let size = window.contentLayoutRect.size
            XCTAssertEqual(size.width, chosenSize.width, accuracy: 1, file: file, line: line)
            XCTAssertEqual(size.height, chosenSize.height, accuracy: 1, file: file, line: line)
        }
        assertSize()
        for page in SettingsPage.allCases {
            model.settingsPage = page
            controller.showWindow(nil)
            try await Task.sleep(for: .milliseconds(150))
            assertSize()
            XCTAssertGreaterThanOrEqual(window.contentView?.bounds.height ?? 0, chosenSize.height)
        }
        window.close()
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(150))
        assertSize()
        try snapshot(window, name: "settings-real-window")
    }

    func testNativeSettingsToolbarTracksSidebarAndNavigationHistory() async throws {
        let model = AppModel(defaults: defaults, siteData: data, discoverTargets: { [] })
        let controller = SettingsWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(200))
        let split = try XCTUnwrap(window.contentViewController as? SettingsSplitViewController)
        XCTAssertFalse(split.splitViewItems[0].canCollapse)
        let sidebarView = split.splitViewItems[0].viewController.view
        XCTAssertGreaterThanOrEqual(sidebarView.frame.width, 250)
        let toolbar = try XCTUnwrap(window.toolbar)
        let divider = try XCTUnwrap(toolbar.items.compactMap { $0 as? NSTrackingSeparatorToolbarItem }.first)
        XCTAssertTrue(divider.splitView === split.splitView)
        XCTAssertFalse(toolbar.items.contains { $0.itemIdentifier == .toggleSidebar })
        let heading = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "Linklet.Settings.Heading" }?.view as? NSTextField)
        XCTAssertGreaterThan(heading.convert(.zero, to: nil).x, sidebarView.convert(sidebarView.bounds, to: nil).maxX)
        model.settingsPage = .search
        model.settingsPage = .windows
        split.navigate(back: true)
        XCTAssertEqual(model.settingsPage, .search)
        split.navigate(back: false)
        XCTAssertEqual(model.settingsPage, .windows)
        model.settingsPage = .sites
        split.navigate(back: true)
        XCTAssertEqual(model.settingsPage, .windows)
        XCTAssertEqual(heading.stringValue, model.settingsPage.title)
    }

    func testMenuRefreshesClipboardOnlyOnOpenAndKeepsHelpGrouped() throws {
        let model = AppModel(defaults: defaults, siteData: data, discoverTargets: { [] })
        model.linkLibrary.setEnabled(true)
        defer { model.hideSidebar(); model.linkLibrary.setEnabled(false) }
        var clipboard = "https://example.org/checkout"
        var reads = 0
        let controller = LinkletMenuBarController(model: model, attachesToStatusBar: false) {
            reads += 1
            return clipboard
        }
        XCTAssertEqual(reads, 0)
        controller.refreshMenu()
        XCTAssertEqual(reads, 1)
        func item(_ name: String) throws -> NSMenuItem {
            try XCTUnwrap(controller.menu.items.first { $0.identifier?.rawValue == "Linklet.Menu." + name })
        }
        XCTAssertTrue(try item("clipboard").isEnabled)
        XCTAssertEqual(try item("clipboard").representedObject as? URL, URL(string: clipboard))
        XCTAssertFalse(try item("windows").isEnabled)
        XCTAssertEqual(try item("search").keyEquivalent, " ")
        let help = try XCTUnwrap(try item("help").submenu)
        XCTAssertEqual(help.items.map { $0.identifier?.rawValue }, ["Linklet.Menu.welcome", "Linklet.Menu.about", "Linklet.Menu.updates"])
        clipboard = "javascript:alert(1)"
        controller.refreshMenu()
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(try item("clipboard").isEnabled)
        XCTAssertNil(try item("clipboard").representedObject)
        for value in ["file:///tmp/private", "text to search", "https:", "linklet://search?q=test"] {
            XCTAssertNil(LinkletMenuBarController.clipboardURL(value))
        }
    }

    func testSettingsSearchFindsParametersInBothLanguages() {
        let previous = AppLanguage.shared.selection
        defer { AppLanguage.shared.set(previous) }
        AppLanguage.shared.set("ru")
        XCTAssertEqual(SettingsPage.allCases.filter { $0.matches("язык") }, [.general])
        XCTAssertEqual(SettingsPage.allCases.filter { $0.matches("микрофон") }, [.sites])
        AppLanguage.shared.set("en")
        XCTAssertEqual(SettingsPage.allCases.filter { $0.matches("search engine") }, [.search])
        XCTAssertTrue(SettingsPage.allCases.allSatisfy { $0.matches("  ") })
    }

    func testMenuActivatesExistingWindowWithoutChangingItsOriginalLink() throws {
        let model = AppModel(defaults: defaults, siteData: data, discoverTargets: { [] })
        let session = model.previewSession
        let original = URL(string: "https://example.org/original")!
        session.load(original)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); session.endSession() }
        model.windowRegistry.register(window, session: session)
        let controller = LinkletMenuBarController(model: model, attachesToStatusBar: false, readClipboard: { nil })
        controller.refreshMenu()
        let root = try XCTUnwrap(controller.menu.items.first { $0.identifier?.rawValue == "Linklet.Menu.windows" })
        XCTAssertTrue(root.isEnabled)
        let submenu = try XCTUnwrap(root.submenu)
        XCTAssertEqual(submenu.items.count, 1)
        XCTAssertEqual(submenu.items[0].representedObject as? UUID, session.windowID)
        submenu.performActionForItem(at: 0)
        XCTAssertEqual(model.windowRegistry.lastActiveWindowID, session.windowID)
        XCTAssertEqual(session.originalURL, original)
        XCTAssertNil(session.webView, "Activating a menu item must not create or reload a WebKit page")
        controller.refreshMenu()
        XCTAssertEqual(controller.menu.items.first { $0.identifier?.rawValue == "Linklet.Menu.windows" }?.submenu?.items.first?.state, .on)
        window.close()
        controller.refreshMenu()
        XCTAssertFalse(try XCTUnwrap(controller.menu.items.first { $0.identifier?.rawValue == "Linklet.Menu.windows" }).isEnabled)
    }

    func testSettingsAndOnboardingSnapshots() async throws {
        let previousLanguage = AppLanguage.shared.selection
        defer { AppLanguage.shared.set(previousLanguage) }
        AppLanguage.shared.set("ru")
        let model = AppModel(defaults: defaults, siteData: data)
        model.refreshTargets()
        await data.setEnabled(true)
        await store.httpCookieStore.setCookie(cookie("example.org"))
        data.recordVisit(URL(string: "https://example.org")!)
        await data.refresh()
        let settingsController = SettingsWindowController(model: model)
        let settingsWindow = try XCTUnwrap(settingsController.window)
        defer { settingsWindow.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            settingsWindow.appearance = NSAppearance(named: appearance)
            for page in SettingsPage.allCases {
                model.settingsPage = page
                settingsWindow.setContentSize(NSSize(width: 900, height: 720))
                settingsController.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                settingsWindow.makeKeyAndOrderFront(nil)
                settingsWindow.makeFirstResponder(nil)
                try await Task.sleep(for: .milliseconds(250))
                try snapshot(settingsWindow, name: "settings-\(page.rawValue)-\(appearance.rawValue)")
            }
        }
        settingsWindow.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        for code in ["ru", "en"] {
            AppLanguage.shared.set(code)
            for step in WelcomeStep.allCases {
                let welcomeHost = NSHostingView(rootView: WelcomeView(model: model, initialStep: step))
                welcomeHost.sizingOptions = []
                window.contentView = welcomeHost
                window.setContentSize(NSSize(width: 760, height: 650))
                try await Task.sleep(for: .milliseconds(150))
                try snapshot(window, name: "welcome-\(step.rawValue)-\(code)")
            }
        }
        let supportHost = NSHostingView(rootView: SupportDevelopmentView()
            .frame(width: 480, height: 410)
            .background(Color(nsColor: .windowBackgroundColor)))
        supportHost.sizingOptions = []
        window.contentView = supportHost
        window.setContentSize(NSSize(width: 480, height: 410))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        try snapshot(window, name: "support")
    }

    private func snapshot(_ window: NSWindow, name: String) throws {
        let view = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/linklet-\(name).png"))
    }
}

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
        await data.prepareForPreview(now: now)
        var domains = Set(await store.httpCookieStore.allCookies().map(\.domain))
        XCTAssertFalse(domains.contains("old.example"))
        XCTAssertTrue(domains.contains("recent.example"))
        XCTAssertTrue(domains.contains("embedded.example"))
        await data.prepareForPreview(now: now.addingTimeInterval(31 * 86400))
        domains = Set(await store.httpCookieStore.allCookies().map(\.domain))
        XCTAssertTrue(domains.isEmpty)
        XCTAssertTrue(SiteDataService.host("accounts.example.co.uk", belongsTo: "example.co.uk"))
        XCTAssertFalse(SiteDataService.host("notexample.co.uk", belongsTo: "example.co.uk"))
        XCTAssertFalse(SiteDataService.host("example.co.uk.evil.org", belongsTo: "example.co.uk"))
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

    func testFirstLinkWaitsForChoiceAndSettingsDoesNotApplyDraft() {
        let model = AppModel(defaults: defaults, siteData: data, discoverTargets: { [] })
        model.showPreview(url: URL(string: "https://example.org")!)
        XCTAssertTrue(model.isChoosingDataMode)
        XCTAssertNil(model.previewSession.currentURL)
        model.openDataSettingsFromChoice()
        XCTAssertEqual(model.settingsPage, .sites)
        XCTAssertFalse(data.isEnabled)
        XCTAssertFalse(data.hasChosenMode)
        // Closing the chooser without completing must leave it eligible for the next link.
        model.previewDidEnd()
        XCTAssertFalse(data.hasChosenMode)
    }

    func testSettingsReturnResumesOriginalLinkWithoutSecondChoice() async throws {
        let model = AppModel(defaults: defaults, siteData: data, discoverTargets: { [] })
        let url = URL(string: "http://127.0.0.1:9/original")!
        model.showPreview(url: url)
        model.openDataSettingsFromChoice()
        await model.setSavesSiteData(true)
        model.settingsDidClose()
        for _ in 0..<100 {
            if !model.isPreparingPreview { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(data.isEnabled)
        XCTAssertTrue(data.hasChosenMode)
        XCTAssertFalse(model.isChoosingDataMode)
        XCTAssertEqual(model.previewSession.originalURL, url)
        model.previewDidEnd()
    }

    func testClosingDuringPreparationDoesNotReopenPreview() async throws {
        let model = AppModel(defaults: defaults, siteData: data, discoverTargets: { [] })
        model.showPreview(url: URL(string: "http://127.0.0.1:9/original")!)
        model.completeDataChoice(save: false)
        model.previewDidEnd()
        await data.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.previewSession.isActive)
        XCTAssertNil(model.previewSession.originalURL)
        XCTAssertFalse(model.isPreparingPreview)
        XCTAssertTrue(data.hasChosenMode)
    }

    func testHidingPreviewEndsTemporarySession() async throws {
        let model = AppModel(defaults: defaults, siteData: data, discoverTargets: { [] })
        model.showPreview(url: URL(string: "http://127.0.0.1:9/original")!)
        model.completeDataChoice(save: false)
        for _ in 0..<100 {
            if !model.isPreparingPreview { break }
            try await Task.sleep(for: .milliseconds(20))
        }
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
        func assertSize(file: StaticString = #filePath, line: UInt = #line) {
            let size = window.contentRect(forFrameRect: window.frame).size
            XCTAssertEqual(size.width, 860, accuracy: 1, file: file, line: line)
            XCTAssertEqual(size.height, 660, accuracy: 1, file: file, line: line)
        }
        assertSize()
        for page in SettingsPage.allCases {
            model.settingsPage = page
            controller.showWindow(nil)
            try await Task.sleep(for: .milliseconds(150))
            assertSize()
            XCTAssertEqual(window.contentView?.bounds.height ?? 0, 660, accuracy: 1)
        }
        window.close()
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(150))
        assertSize()
        try snapshot(window, name: "settings-real-window")
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 660), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for page in SettingsPage.allCases {
                model.settingsPage = page
                let host = NSHostingView(rootView: SettingsView(model: model))
                host.sizingOptions = []
                window.contentView = host
                window.setContentSize(NSSize(width: 860, height: 660))
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(250))
                try snapshot(window, name: "settings-\(page.rawValue)-\(appearance.rawValue)")
            }
        }
        window.appearance = NSAppearance(named: .aqua)
        model.isChoosingDataMode = true
        let previewHost = NSHostingView(rootView: PreviewRootView(model: model))
        previewHost.sizingOptions = []
        window.contentView = previewHost
        window.setContentSize(NSSize(width: 900, height: 650))
        try await Task.sleep(for: .milliseconds(250))
        try snapshot(window, name: "site-data-choice")
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
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/linklet-\(name).png"))
    }
}

import XCTest
import SwiftUI
import AppKit
import WebKit
import Sparkle
@testable import Linklet

final class URLPolicyTests: XCTestCase {
    func testAllowsHTTPAndHTTPS() {
        XCTAssertTrue(URLPolicy.canPreview(URL(string: "https://example.com")!))
        XCTAssertTrue(URLPolicy.canPreview(URL(string: "http://example.com")!))
    }

    func testRejectsDangerousAndLocalSchemes() {
        XCTAssertFalse(URLPolicy.canPreview(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(URLPolicy.canPreview(URL(fileURLWithPath: "/tmp/example.html")))
        XCTAssertFalse(URLPolicy.canPreview(URL(string: "data:text/html,hello")!))
    }

    func testAddsHTTPSToBareHostname() {
        XCTAssertEqual(
            URLPolicy.normalizedURL(from: "example.com")?.absoluteString,
            "https://example.com"
        )
    }
}

@MainActor
final class AppModelPreferencesTests: XCTestCase {
    func testWindowGeometryPersistsPerHostAndStaysWithinVisibleFrame() throws {
        let suiteName = "app.peekroute.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = WindowGeometryService(defaults: defaults)
        let frame = NSRect(x: 120, y: 160, width: 980, height: 710)

        service.save(frame, for: try XCTUnwrap(URL(string: "https://example.com/a")))

        XCTAssertEqual(service.frame(for: try XCTUnwrap(URL(string: "https://example.com/b"))), frame)
        XCTAssertNil(service.frame(for: try XCTUnwrap(URL(string: "https://other.example.com"))))
        XCTAssertEqual(
            WindowGeometryService.clamped(
                NSRect(x: -100, y: 900, width: 1_200, height: 900),
                to: NSRect(x: 0, y: 0, width: 800, height: 600)
            ),
            NSRect(x: 0, y: 0, width: 800, height: 600)
        )
    }

    func testWindowBehaviorRestoresLegacySettingsAndUpdatesTheOpenPanel() throws {
        let suiteName = "app.peekroute.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for visible in [false, true] {
            for above in [false, true] {
                defaults.set(visible, forKey: "keepsPreviewVisibleWhenInactive")
                defaults.set(above, forKey: "keepsPreviewAboveOtherWindows")
                let model = AppModel(defaults: defaults)
                XCTAssertEqual(model.previewWindowBehavior, !visible ? .hide : (above ? .stayOnTop : .keepOpen))
            }
        }

        let model = AppModel(defaults: defaults)
        let controller = PreviewWindowController(model: model)
        let panel = try XCTUnwrap(controller.window)
        defer { panel.close() }

        for behavior in [PreviewWindowBehavior.hide, .stayOnTop, .keepOpen, .hide] {
            model.setPreviewWindowBehavior(behavior)
            XCTAssertEqual(panel.hidesOnDeactivate, behavior == .hide)
            XCTAssertEqual(panel.level, behavior == .stayOnTop ? .floating : .normal)
            XCTAssertEqual(AppModel(defaults: defaults).previewWindowBehavior, behavior)
        }
    }

    func testPreviewStartsAtComfortableSizeAndPreservesManualResize() throws {
        let model = AppModel()
        let controller = PreviewWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.prepare()
        let initialSize = window.contentRect(forFrameRect: window.frame).size
        XCTAssertEqual(initialSize.width, 900, accuracy: 1)
        XCTAssertEqual(initialSize.height, 650, accuracy: 1)

        window.setContentSize(NSSize(width: 1000, height: 700))
        controller.prepare()
        let resizedSize = window.contentRect(forFrameRect: window.frame).size
        XCTAssertEqual(resizedSize.width, 1000, accuracy: 1)
        XCTAssertEqual(resizedSize.height, 700, accuracy: 1)
    }

    func testNewURLImmediatelyReplacesAddressAndCoversPreviousPage() throws {
        let session = PreviewSession()
        let url = try XCTUnwrap(URL(string: "https://example.com/new-page"))

        session.load(url)

        XCTAssertEqual(session.originalURL, url)
        XCTAssertEqual(session.currentURL, url)
        XCTAssertEqual(session.addressText, url.absoluteString)
        XCTAssertTrue(session.isPreparingNewPage)

        session.stopLoading()
        XCTAssertFalse(session.isPreparingNewPage)
    }

    func testPreviewPreferencesHaveExpectedDefaultsAndPersist() throws {
        let suiteName = "app.peekroute.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(defaults: defaults)
        XCTAssertFalse(model.showsFullURL)
        XCTAssertTrue(model.sortsTargetsByUsage)
        XCTAssertFalse(model.keepsPreviewVisibleWhenInactive)
        XCTAssertEqual(model.previewWindowBehavior, .hide)
        XCTAssertFalse(model.keepsPreviewAboveOtherWindows)
        XCTAssertFalse(model.opensLinksInNewWindows)

        let target = BrowserTarget.browser(
            name: "Test Browser",
            applicationURL: URL(fileURLWithPath: "/Applications/Test Browser.app")
        )
        XCTAssertTrue(model.isTargetVisible(target))

        model.setShowsFullURL(true)
        model.setSortTargetsByUsage(false)
        model.setKeepsPreviewVisibleWhenInactive(false)
        model.setKeepsPreviewAboveOtherWindows(true)
        model.setOpensLinksInNewWindows(true)
        model.setTargetVisible(target, isVisible: false)

        let restoredModel = AppModel(defaults: defaults)
        XCTAssertTrue(restoredModel.showsFullURL)
        XCTAssertFalse(restoredModel.sortsTargetsByUsage)
        XCTAssertFalse(restoredModel.keepsPreviewVisibleWhenInactive)
        XCTAssertTrue(restoredModel.keepsPreviewAboveOtherWindows)
        XCTAssertTrue(restoredModel.opensLinksInNewWindows)
        XCTAssertFalse(restoredModel.isTargetVisible(target))
    }
}

@MainActor
final class PreviewHistoryTests: XCTestCase {
    func testBackForwardBranchingAndNewExternalLinkHistory() async throws {
        let session = PreviewSession()
        let originalURL = URL(string: "https://example.com/shared-link")!
        var expectedOriginalURL = originalURL
        session.load(originalURL)
        session.stopLoading() // Preserve the incoming link while navigating offline fixtures.
        let fixture = HistoryPageFixture()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = session.websiteDataStore
        configuration.setURLSchemeHandler(fixture, forURLScheme: "history-test")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let observer = HistoryNavigationObserver(session: session)
        webView.navigationDelegate = observer
        session.attach(webView)

        func navigate(_ action: () -> Void) async {
            let finished = expectation(description: "History navigation finishes")
            observer.finished = finished
            action()
            await fulfillment(of: [finished], timeout: 10)
            XCTAssertEqual(session.originalURL, expectedOriginalURL)
        }

        await navigate { webView.load(URLRequest(url: URL(string: "history-test://pages/a")!)) }
        XCTAssertFalse(session.canGoBack)
        XCTAssertFalse(session.canGoForward)

        // Follow an actual page link, rather than inserting synthetic history entries.
        await navigate { webView.evaluateJavaScript("document.querySelector('a').click()") }
        XCTAssertEqual(session.currentURL?.path, "/b")
        XCTAssertTrue(session.canGoBack)
        XCTAssertFalse(session.canGoForward)

        await navigate { session.goBack() }
        XCTAssertEqual(session.currentURL?.path, "/a")
        XCTAssertFalse(session.canGoBack)
        XCTAssertTrue(session.canGoForward)

        await navigate { session.goForward() }
        XCTAssertEqual(session.currentURL?.path, "/b")
        XCTAssertTrue(session.canGoBack)
        XCTAssertFalse(session.canGoForward)

        await navigate { session.goBack() }
        await navigate { webView.load(URLRequest(url: URL(string: "history-test://pages/c")!)) }
        XCTAssertEqual(session.currentURL?.path, "/c")
        XCTAssertFalse(session.canGoForward, "A new branch must discard forward history")

        let previousNavigationID = session.navigationID
        let dataStore = session.websiteDataStore
        let externalURL = URL(string: "https://example.com/new-preview")!
        session.load(externalURL)
        expectedOriginalURL = externalURL
        XCTAssertEqual(session.originalURL, externalURL)
        XCTAssertNotEqual(session.navigationID, previousNavigationID)
        XCTAssertNil(session.webView)
        XCTAssertFalse(session.canGoBack)
        XCTAssertFalse(session.canGoForward)
        XCTAssertEqual(session.pageTitle, "")
        XCTAssertTrue(session.websiteDataStore === dataStore)

        // Late events from the discarded page must not restore old history or URLs.
        session.synchronize(from: webView)
        session.navigationDidCommit(in: webView)
        session.navigationDidFail(in: webView)
        XCTAssertEqual(session.currentURL, externalURL)
        XCTAssertTrue(session.isPreparingNewPage)
        XCTAssertFalse(session.canGoBack)

        session.stopLoading() // Cancel the external request; this test stays entirely offline.
        let newWebView = WKWebView(frame: .zero, configuration: configuration)
        newWebView.navigationDelegate = observer
        session.attach(newWebView)
        await navigate { newWebView.load(URLRequest(url: URL(string: "history-test://pages/new")!)) }
        XCTAssertFalse(session.canGoBack)
        XCTAssertFalse(session.canGoForward)
        XCTAssertTrue(newWebView.backForwardList.backList.isEmpty)
    }
}

private final class HistoryPageFixture: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        let html = "<html><head><title>\(url.path)</title></head><body><a href='history-test://pages/b'>Next</a></body></html>"
        let data = Data(html.utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor
private final class HistoryNavigationObserver: NSObject, WKNavigationDelegate {
    let session: PreviewSession
    var finished: XCTestExpectation?

    init(session: PreviewSession) { self.session = session }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        session.navigationDidCommit(in: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        session.synchronize(from: webView)
        finished?.fulfill()
        finished = nil
    }
}

@MainActor
final class WelcomePageTests: XCTestCase {
    func testWelcomeLoadsOfflineUpdatesStatusAndSeparatesExternalNavigation() async throws {
        let previousLanguage = AppLanguage.shared.selection
        AppLanguage.shared.set("ru")
        defer { AppLanguage.shared.set(previousLanguage) }
        let session = PreviewSession()
        session.showWelcome(isDefault: false)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = session.websiteDataStore
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 888, height: 608), configuration: configuration)
        let coordinator = WebPreview.Coordinator(session: session)
        webView.navigationDelegate = coordinator
        session.attach(webView)
        for _ in 0..<100 {
            if (try? await webView.evaluateJavaScript("typeof window.updateStatus")) as? String == "function" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        session.updateWelcomeStatus(isDefault: false)
        let pending = try await webView.evaluateJavaScript("document.getElementById('status').textContent") as? String
        XCTAssertEqual(pending, "Настройте открытие ссылок")
        session.updateWelcomeStatus(isDefault: true)
        let ready = try await webView.evaluateJavaScript("document.getElementById('status').textContent") as? String
        XCTAssertEqual(ready, "Всё готово к просмотру")
        XCTAssertNil(session.currentURL)
        XCTAssertTrue(session.canOpenWelcomeSettings(from: webView, isMainFrame: true))
        XCTAssertFalse(session.canOpenWelcomeSettings(from: webView, isMainFrame: false))
        let image = try await webView.takeSnapshot(configuration: nil)
        if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/linklet-welcome-qa.png"))
        }
        session.load(URL(string: "https://example.com")!)
        XCTAssertFalse(session.isWelcome)
        XCTAssertFalse(session.canOpenWelcomeSettings(from: webView, isMainFrame: true))
        session.synchronize(from: webView)
        XCTAssertEqual(session.currentURL?.absoluteString, "https://example.com")
        XCTAssertFalse(session.canGoBack)
    }
}

@MainActor
final class LocalizationTests: XCTestCase {
    func testLanguageChoiceAndFormattedLabels() {
        let previous = AppLanguage.shared.selection
        defer { AppLanguage.shared.set(previous) }
        XCTAssertEqual(AppLanguage.resolve("system", preferredLanguages: ["ru-RU"]), "ru")
        XCTAssertEqual(AppLanguage.resolve("system", preferredLanguages: ["de-DE"]), "en")
        AppLanguage.shared.set("ru")
        XCTAssertEqual(L("Open in %@", "Safari"), "Открыть в Safari")
        XCTAssertEqual(PreviewWindowBehavior.stayOnTop.title, "Поверх всех окон")
        XCTAssertEqual(L("Favorite websites"), "Избранные сайты")
        XCTAssertEqual(L("Show favorites in Quick Search"), "Показывать избранное в быстром поиске")
        XCTAssertEqual(L("Add favorite website"), "Добавить избранный сайт")
        XCTAssertEqual(L("Load favicon"), "Загрузить favicon")
        XCTAssertEqual(L("Enter a valid HTTP or HTTPS address."), "Введите корректный адрес HTTP или HTTPS.")
        XCTAssertEqual(L("Open links in new windows"), "Открывать ссылки в новых окнах")
        XCTAssertEqual(L("Close All Windows"), "Закрыть все окна")
        AppLanguage.shared.set("en")
        XCTAssertEqual(L("Open in %@", "Safari"), "Open in Safari")
        XCTAssertEqual(PreviewWindowBehavior.stayOnTop.title, "Keep on top")
        XCTAssertEqual(L("Favorite websites"), "Favorite websites")
        XCTAssertEqual(L("Open links in new windows"), "Open links in new windows")
        XCTAssertEqual(L("Close All Windows"), "Close All Windows")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "interfaceLanguage"), "en")
    }

    func testEnglishWelcomeLoadsAndUpdatesWithoutRussianText() async throws {
        let previous = AppLanguage.shared.selection
        AppLanguage.shared.set("en")
        defer { AppLanguage.shared.set(previous) }
        let session = PreviewSession()
        session.showWelcome(isDefault: false)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 628, height: 520))
        let coordinator = WebPreview.Coordinator(session: session)
        view.navigationDelegate = coordinator
        session.attach(view)
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("typeof window.updateStatus")) as? String == "function" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        session.updateWelcomeStatus(isDefault: false)
        let pending = try await view.evaluateJavaScript("document.getElementById('status').textContent") as? String
        XCTAssertEqual(pending, "Set up link previews")
        session.updateWelcomeStatus(isDefault: true)
        let body = try await view.evaluateJavaScript("document.body.innerText") as? String ?? ""
        XCTAssertTrue(body.contains("Ready to preview"))
        XCTAssertNil(body.range(of: "[А-Яа-яЁё]", options: .regularExpression))
        let image = try await view.takeSnapshot(configuration: nil)
        if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/linklet-welcome-en.png"))
        }
    }
}

@MainActor
final class AdBlockTests: XCTestCase {
    func testDailyDeadlineIncludingClockRollback() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(AdBlockService.isUpdateDue(lastAttempt: nil, now: now))
        XCTAssertFalse(AdBlockService.isUpdateDue(lastAttempt: now.addingTimeInterval(-86_399), now: now))
        XCTAssertTrue(AdBlockService.isUpdateDue(lastAttempt: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(AdBlockService.isUpdateDue(lastAttempt: now.addingTimeInterval(60), now: now))
    }

    func testRejectsErrorPagesAndEmptyFilters() {
        XCTAssertThrowsError(try AdBlockService.validateFilter("<html>Service unavailable</html>"))
        XCTAssertThrowsError(try AdBlockService.validateFilter("! Title: AdGuard\n! Version: 1\n"))
    }

    func testBundledFiltersCompileAndFailedUpdatePreservesWorkingCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "LinkletAdBlockTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(true, forKey: AdBlockService.enabledKey)
        let blocker = AdBlockService(defaults: defaults, cacheDirectory: directory,
                                     automaticUpdates: false, fetchFilters: { throw URLError(.notConnectedToInternet) })
        await blocker.prepareIfEnabled()
        // The real bundled filters must produce a usable compiled list offline.
        let store = WKContentRuleListStore(url: directory)!
        let identifiers = await store.availableIdentifiers() ?? []
        XCTAssertEqual(identifiers.count, 1)
        let cachedJSON = try Data(contentsOf: directory.appendingPathComponent("rules-v1.json"))
        blocker.checkForUpdates()
        await blocker.waitForUpdate()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("rules-v1.json")), cachedJSON)
        let afterFailure = await store.availableIdentifiers() ?? []
        XCTAssertEqual(afterFailure, identifiers)
        XCTAssertNotNil(defaults.object(forKey: "adGuardLastUpdateAttempt"))
        blocker.setEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: AdBlockService.enabledKey))
        XCTAssertFalse(blocker.isEnabled)
    }
}

@MainActor
final class AdBlockWebKitTests: XCTestCase {
    func testUpdateBlocksElementAndToggleRestoresIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "LinkletAdBlockWebKitTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(true, forKey: AdBlockService.enabledKey)
        let fixture = "! Title: AdGuard test fixture\n! Version: 1\n##.linklet-test-ad\n" +
            (1...120).map { "||ad\($0).example.org^" }.joined(separator: "\n")
        let blocker = AdBlockService(defaults: defaults, cacheDirectory: directory,
                                     automaticUpdates: false, fetchFilters: { [fixture] in [fixture] })
        blocker.checkForUpdates()
        await blocker.waitForUpdate()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        blocker.attach(to: configuration.userContentController)
        let view = WKWebView(frame: .zero, configuration: configuration)
        let delegate = AdBlockPageDelegate()
        view.navigationDelegate = delegate
        let html = "<html><body><div class='linklet-test-ad'>Ad</div></body></html>"
        delegate.finished = expectation(description: "Blocked page loaded")
        view.loadHTMLString(html, baseURL: URL(string: "https://example.org"))
        await fulfillment(of: [delegate.finished!], timeout: 10)
        let blocked = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('.linklet-test-ad')).display") as? String
        XCTAssertEqual(blocked, "none")
        blocker.setEnabled(false)
        delegate.finished = expectation(description: "Unblocked page loaded")
        view.loadHTMLString(html, baseURL: URL(string: "https://example.org"))
        await fulfillment(of: [delegate.finished!], timeout: 10)
        let restored = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('.linklet-test-ad')).display") as? String
        XCTAssertEqual(restored, "block")
    }
}

@MainActor
private final class AdBlockPageDelegate: NSObject, WKNavigationDelegate {
    var finished: XCTestExpectation?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished?.fulfill()
    }
}


@MainActor
final class SettingsLanguageTests: XCTestCase {
    func testAutomaticChecksDefaultToEnabledButDownloadsRequireConfirmation() {
        // Existing users may have opted out of checks, so verify the install default
        // without overwriting their saved preference. Automatic downloads are forbidden.
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool, true)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool, false)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUAllowsAutomaticUpdates") as? Bool, false)
        XCTAssertFalse(AppUpdateService().automaticallyDownloadsUpdates)
    }

    func testUpdateFromPublished011KeepsIdentityAndUsesHigherBuild() throws {
        let bundle = Bundle.main
        let build = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        let version = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(SUStandardVersionComparator().compareVersion("2", toVersion: build), .orderedAscending)
        XCTAssertGreaterThanOrEqual(version.split(separator: ".").count, 2)
        XCTAssertEqual(bundle.bundleIdentifier, "Linklet")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
                       "se2KhBLlhCaMRw3PEox9XshU29f+wlHRQTXQsvgVAF8=")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                       "https://alybo.github.io/Linklet/appcast.xml")
    }

    func testWindowBehaviorSegmentsChangeLanguageWithoutReopeningSettings() async throws {
        let suite = "LinkletSettingsLanguageTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let previousLanguage = AppLanguage.shared.selection
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer {
            window.orderOut(nil)
            AppLanguage.shared.set(previousLanguage)
            defaults.removePersistentDomain(forName: suite)
        }
        AppLanguage.shared.set("ru")
        let model = AppModel(defaults: defaults)
        model.setPreviewWindowBehavior(.stayOnTop)
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.orderFront(nil)
        func segments(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.lazy.compactMap { segments(in: $0) }.first
        }
        func labels() -> [String] {
            guard let content = window.contentView, let control = segments(in: content) else { return [] }
            return (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
        }
        for _ in 0..<30 {
            if labels() == ["Скрывать", "Оставлять открытым", "Поверх всех окон"] { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(labels(), ["Скрывать", "Оставлять открытым", "Поверх всех окон"])
        AppLanguage.shared.set("en")
        for _ in 0..<30 {
            if labels() == ["Hide preview", "Keep open", "Keep on top"] { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(labels(), ["Hide preview", "Keep open", "Keep on top"])
        XCTAssertEqual(model.previewWindowBehavior, .stayOnTop)
    }
}

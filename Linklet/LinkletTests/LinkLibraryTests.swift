import XCTest
import WebKit
import SwiftUI
import Network
import Carbon
@testable import Linklet

@MainActor
final class LinkLibraryTests: XCTestCase {
    func testHistoryIsOptInBoundedAndKeepsOnlyIncomingLinks() throws {
        let suite = "LinkLibraryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LinkLibrary(defaults: defaults)
        let url = URL(string: "https://example.com/original")!
        XCTAssertFalse(library.isEnabled)
        XCTAssertFalse(library.savesHistory)
        library.recordOpening(url)
        XCTAssertTrue(library.recentLinks.isEmpty)
        library.setEnabled(true)
        library.recordOpening(url)
        library.updateTitle("Example", for: url)
        XCTAssertNil(defaults.data(forKey: "recentLinks"))
        XCTAssertTrue(LinkLibrary(defaults: defaults).recentLinks.isEmpty)
        library.recordOpening(URL(string: "file:///tmp/private")!)
        library.recordOpening(URL(string: "linklet://search?q=secret")!)
        XCTAssertEqual(library.recentLinks.count, 1)
        library.setSavesHistory(true)
        XCTAssertEqual(LinkLibrary(defaults: defaults).recentLinks.first?.title, "Example")
        library.recordOpening(url)
        XCTAssertEqual(library.recentLinks.count, 1)
        for index in 0..<210 { library.recordOpening(URL(string: "https://example.com/\(index)")!) }
        XCTAssertEqual(library.recentLinks.count, 200)
        XCTAssertEqual(LinkLibrary(defaults: defaults).recentLinks.count, 200)
        library.setSavesHistory(false)
        XCTAssertNil(defaults.data(forKey: "recentLinks"))
        XCTAssertEqual(library.recentLinks.count, 200)
        XCTAssertTrue(LinkLibrary(defaults: defaults).recentLinks.isEmpty)
        library.clearHistory()
        XCTAssertTrue(library.recentLinks.isEmpty)
    }

    func testFoldersReuseFavoritesAndRemovingFolderKeepsBookmarks() throws {
        let suite = "LinkFolderTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        let library = LinkLibrary(defaults: defaults)
        let site = try settings.addFavoriteSite(name: "Docs", address: "https://swift.org")
        XCTAssertNil(library.addFolder(name: "  "))
        let folder = try XCTUnwrap(library.addFolder(name: " Work "))
        library.moveBookmark(site, to: folder.id)
        library.renameFolder(folder, name: "Reference")
        let restored = LinkLibrary(defaults: defaults)
        XCTAssertEqual(restored.folders.first?.name, "Reference")
        XCTAssertEqual(restored.folderID(for: site), folder.id)
        XCTAssertEqual(SearchSettings(defaults: defaults).favoriteSites, [site])
        restored.removeFolder(folder)
        XCTAssertNil(restored.folderID(for: site))
        XCTAssertEqual(SearchSettings(defaults: defaults).favoriteSites, [site])
        XCTAssertTrue(LinkLibrary(defaults: defaults).folders.isEmpty)
    }

    func testEdgeTriggerUsesEachScreensPhysicalLeftEdgeAndExcludesMenuBar() {
        let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let visible = NSRect(x: -1440, y: 0, width: 1440, height: 875)
        XCTAssertTrue(SidebarWindowController.isAtLeftEdge(NSPoint(x: -1440, y: 400), screenFrame: screen, visibleFrame: visible))
        XCTAssertFalse(SidebarWindowController.isAtLeftEdge(NSPoint(x: -1430, y: 400), screenFrame: screen, visibleFrame: visible))
        XCTAssertFalse(SidebarWindowController.isAtLeftEdge(NSPoint(x: -1440, y: 890), screenFrame: screen, visibleFrame: visible))
    }

    func testSidebarUsesAnIndependentWindowAndShowsExistingBookmarks() async throws {
        let suite = "SidebarWindowTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.linkLibrary.setEnabled(true)
        let reference = try model.searchSettings.addFavoriteSite(name: "Swift Documentation", address: "swift.org/documentation")
        _ = try model.searchSettings.addFavoriteSite(name: "Apple Developer", address: "developer.apple.com")
        let folder = try XCTUnwrap(model.linkLibrary.addFolder(name: "Work"))
        model.linkLibrary.moveBookmark(reference, to: folder.id)
        model.linkLibrary.recordOpening(URL(string: "https://example.com/article")!)
        let controller = SidebarWindowController(model: model)
        defer { controller.hide(); model.linkLibrary.setEnabled(false) }
        controller.toggle()
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(model.previewSession.isActive)
        XCTAssertEqual(window.level, .floating)
        try await Task.sleep(for: .milliseconds(300))
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-1.5-sidebar.png"))
        }
        controller.toggle()
        XCTAssertFalse(window.isVisible)
    }

    func testIndependentHotKeysRouteOnlyTheirOwnEvents() throws {
        let first = SearchHotKey(identifier: 71)
        let second = SearchHotKey(identifier: 72)
        guard first.register(SearchShortcut(keyCode: 100, modifiers: UInt32(controlKey | optionKey | shiftKey), keyLabel: "F8")),
              second.register(SearchShortcut(keyCode: 101, modifiers: UInt32(controlKey | optionKey | shiftKey), keyLabel: "F9")) else {
            throw XCTSkip("Fixture hotkeys are unavailable on this Mac")
        }
        defer { first.unregister(); second.unregister() }
        var firstCount = 0
        var secondCount = 0
        first.action = { firstCount += 1 }
        second.action = { secondCount += 1 }
        for id: UInt32 in [71, 72] {
            var createdEvent: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                       GetCurrentEventTime(), EventAttributes(0), &createdEvent), noErr)
            let event = try XCTUnwrap(createdEvent)
            defer { ReleaseEvent(event) }
            var identifier = EventHotKeyID(signature: 0x4C4E4B53, id: id)
            XCTAssertEqual(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                            MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
            XCTAssertEqual(SendEventToEventTarget(event, GetApplicationEventTarget()), noErr)
        }
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 1)
    }

    func testChildPreviewModelsShareLibraryAndFavorites() throws {
        let suite = "SharedLinkLibraryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = AppModel(defaults: defaults, discoverTargets: { [] })
        let child = AppModel(defaults: defaults, siteData: root.siteData,
                             searchSettings: root.searchSettings, linkLibrary: root.linkLibrary, discoverTargets: { [] })
        XCTAssertTrue(root.linkLibrary === child.linkLibrary)
        XCTAssertTrue(root.searchSettings === child.searchSettings)
        _ = try child.searchSettings.addFavoriteSite(name: "Docs", address: "swift.org")
        XCTAssertEqual(root.searchSettings.favoriteSites.count, 1)
    }
}

@MainActor
final class WebPopupTests: XCTestCase {
    func testBlankLoginWindowsPreserveOpenerMessagingCookiesAndClose() async throws {
        let session = PreviewSession()
        let incoming = URL(string: "https://example.com/shared")!
        session.load(incoming)
        session.stopLoading()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                configuration: WebPreview.configuration(websiteDataStore: session.websiteDataStore))
        let coordinator = WebPreview.Coordinator(session: session)
        webView.uiDelegate = coordinator
        webView.navigationDelegate = coordinator
        coordinator.startObserving(webView)
        session.attach(webView)
        defer { coordinator.closePopupWindows(); session.endSession() }
        webView.loadHTMLString("<html><head><title>Original site</title></head><body><script>window.result='pending';addEventListener('message',e=>window.result=e.data);</script></body></html>", baseURL: nil)
        try await waitUntil { (try? await webView.evaluateJavaScript("window.result")) as? String == "pending" }
        let initialURL = webView.url
        // Two distinct provider names exercise the same generic path, including async blank windows.
        for provider in ["provider-one", "provider-two"] {
            _ = try await webView.evaluateJavaScript("window.child=window.open('about:blank','\(provider)');Boolean(window.child)")
            try await waitUntil { coordinator.popupWindows.count == 1 }
            let popup = try XCTUnwrap(coordinator.popupWindows.values.first)
            try await waitUntil { (try? await popup.webView.evaluateJavaScript("document.readyState")) as? String == "complete" }
            XCTAssertTrue(popup.webView.configuration.websiteDataStore === webView.configuration.websiteDataStore)
            let hasOpener = try await popup.webView.evaluateJavaScript("window.opener !== null") as? Bool
            XCTAssertEqual(hasOpener, true)
            let cookie = HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "fixture", .value: provider])!
            await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            let cookies = await popup.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            XCTAssertTrue(cookies.contains { $0.name == "fixture" && $0.value == provider })
            _ = try await popup.webView.evaluateJavaScript("window.opener.postMessage('\(provider)','*');window.close()")
            try await waitUntil { coordinator.popupWindows.isEmpty }
            try await waitUntil { (try? await webView.evaluateJavaScript("window.result")) as? String == provider }
            XCTAssertEqual(webView.url, initialURL)
            XCTAssertEqual(session.originalURL, incoming)
            let title = try await webView.evaluateJavaScript("document.title") as? String
            XCTAssertEqual(title, "Original site")
        }
        _ = try await webView.evaluateJavaScript("window.open('about:blank','cleanup');true")
        try await waitUntil { coordinator.popupWindows.count == 1 }
        session.load(URL(string: "https://example.org/new")!)
        XCTAssertTrue(coordinator.popupWindows.isEmpty)
        XCTAssertNil(session.webView)
    }

    func testPOSTLoginRedirectReturnsToOpenerWithoutReplacingTheSite() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let session = PreviewSession()
        let original = URL(string: "http://127.0.0.1:\(port)/site")!
        session.load(original)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                configuration: WebPreview.configuration(websiteDataStore: session.websiteDataStore))
        let coordinator = WebPreview.Coordinator(session: session)
        webView.uiDelegate = coordinator
        webView.navigationDelegate = coordinator
        coordinator.startObserving(webView)
        session.attach(webView)
        defer { coordinator.closePopupWindows(); session.endSession() }
        try await waitUntil { (try? await webView.evaluateJavaScript("window.result")) as? String == "pending" }
        _ = try await webView.evaluateJavaScript("document.querySelector('form').submit();true")
        try await waitUntil { (try? await webView.evaluateJavaScript("window.result")) as? String == "signed-in:login=fixture" }
        try await waitUntil { coordinator.popupWindows.isEmpty }
        XCTAssertEqual(server.postCount, 1, "The POST must be performed exactly once by WebKit")
        XCTAssertEqual(server.postBody, "state=fixture-state")
        XCTAssertEqual(webView.url, original)
        XCTAssertEqual(session.originalURL, original)
        XCTAssertFalse(webView.canGoBack)
    }

    func testLongOAuthURLKeepsViewportAndBrowserButtonInsideWindow() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let session = PreviewSession()
        session.load(URL(string: "http://127.0.0.1:\(port)/site")!)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                configuration: WebPreview.configuration(websiteDataStore: session.websiteDataStore))
        let coordinator = WebPreview.Coordinator(session: session)
        webView.uiDelegate = coordinator
        webView.navigationDelegate = coordinator
        coordinator.startObserving(webView)
        session.attach(webView)
        defer { coordinator.closePopupWindows(); session.endSession() }
        try await waitUntil { (try? await webView.evaluateJavaScript("window.result")) as? String == "pending" }
        let longURL = "http://localhost:\(port)/long-login?state=" + String(repeating: "fixture", count: 400)
        _ = try await webView.evaluateJavaScript("window.open('\(longURL)','long-login','width=600,height=700');true")
        try await waitUntil { coordinator.popupWindows.count == 1 }
        let popup = try XCTUnwrap(coordinator.popupWindows.values.first)
        try await waitUntil { popup.session.pageTitle == "Original site" }
        let window = try XCTUnwrap(popup.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(window.frame.width, 1000)
        XCTAssertGreaterThan(popup.webView.visibleRect.width, 300, "Viewport frame: \(popup.webView.frame), content: \(content.frame)")
        XCTAssertGreaterThan(popup.webView.visibleRect.height, 300, "Viewport frame: \(popup.webView.frame), content: \(content.frame)")
        let toolbar = try XCTUnwrap(content.subviews.first(where: { $0 is NSStackView }))
        let browserButton = try XCTUnwrap(toolbar.subviews.first(where: { $0 is NSButton }))
        XCTAssertTrue(toolbar.bounds.contains(browserButton.frame), "Browser action frame: \(browserButton.frame), toolbar: \(toolbar.bounds)")
        let viewport = try await popup.webView.evaluateJavaScript("[innerWidth, innerHeight]") as? [Int]
        XCTAssertGreaterThan(viewport?.first ?? 0, 300)
        XCTAssertGreaterThan(viewport?.last ?? 0, 300)
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-popup-layout.png"))
        }
        window.setContentSize(NSSize(width: 360, height: 500))
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(window.frame.width, 360)
        XCTAssertTrue(toolbar.bounds.contains(browserButton.frame))
        XCTAssertGreaterThan(popup.webView.visibleRect.height, 300)
    }

    func testWebKitReportsNativePasskeyAvailabilityWithoutCreatingCredentials() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let session = PreviewSession()
        session.load(URL(string: "http://localhost:\(port)/site")!)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                configuration: WebPreview.configuration(websiteDataStore: session.websiteDataStore))
        let coordinator = WebPreview.Coordinator(session: session)
        webView.uiDelegate = coordinator
        webView.navigationDelegate = coordinator
        session.attach(webView)
        defer { session.endSession() }
        try await waitUntil { (try? await webView.evaluateJavaScript("window.result")) as? String == "pending" }
        _ = try await webView.evaluateJavaScript("window.passkeyAvailable=null;PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable().then(value=>window.passkeyAvailable=value);true")
        try await waitUntil { (try? await webView.evaluateJavaScript("typeof window.passkeyAvailable")) as? String == "boolean" }
        let available = try await webView.evaluateJavaScript("window.passkeyAvailable") as? Bool
        // The required test build is unsigned and has neither a managed browser
        // entitlement nor associated domains. Safari UA tokens cannot grant access.
        XCTAssertEqual(available, false)
    }

    func testPopupPolicyAcceptsOnlyWebOrInitialBlankAndRejectsInternalCommands() {
        for value in ["https://example.com/login", "http://example.org/sso", "about:blank"] {
            XCTAssertTrue(WebPreview.Coordinator.canCreatePopup(for: URL(string: value)!))
        }
        XCTAssertTrue(WebPreview.Coordinator.canCreatePopup(for: nil))
        for value in ["file:///tmp/private", "javascript:alert(1)", "linklet-welcome://settings", "about:config"] {
            XCTAssertFalse(WebPreview.Coordinator.canCreatePopup(for: URL(string: value)!))
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("WebKit fixture did not complete within 10 seconds")
    }
}

/// Local HTTP fixture: different origins for the site (127.0.0.1) and provider (localhost).
/// Socket parsing and response work stay on a utility queue.
private final class PopupHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Linklet.PopupHTTPFixture", qos: .utility)
    private let lock = NSLock()
    private var receivedPosts = 0
    private var receivedBody = ""
    var postCount: Int { lock.lock(); defer { lock.unlock() }; return receivedPosts }
    var postBody: String { lock.lock(); defer { lock.unlock() }; return receivedBody }

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = self.listener.port?.rawValue else { return }
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: port)
                case .failed(let error):
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receive(connection, data: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var accumulated = data
            accumulated.append(chunk ?? Data())
            guard accumulated.count <= 65_536 else { connection.cancel(); return }
            guard let request = String(data: accumulated, encoding: .utf8),
                  let separator = request.range(of: "\r\n\r\n") else {
                if complete { connection.cancel() } else { self.receive(connection, data: accumulated) }
                return
            }
            let headers = String(request[..<separator.lowerBound])
            let length = headers.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") })
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = String(request[separator.upperBound...])
            guard body.utf8.count >= length else { self.receive(connection, data: accumulated); return }
            self.respond(connection, headers: headers, body: body)
        }
    }

    private func respond(_ connection: NWConnection, headers: String, body: String) {
        let port = listener.port!.rawValue
        let firstLine = headers.components(separatedBy: "\r\n")[0]
        let status: String
        var extraHeaders = ""
        let html: String
        if firstLine.hasPrefix("POST /authorize ") {
            lock.lock(); receivedPosts += 1; receivedBody = body; lock.unlock()
            status = "302 Found"
            extraHeaders = "Location: http://localhost:\(port)/callback\r\nSet-Cookie: login=fixture; Path=/; SameSite=Lax\r\n"
            html = ""
        } else if firstLine.hasPrefix("GET /callback ") {
            status = "200 OK"
            html = "<script>window.opener.postMessage('signed-in:'+document.cookie,'http://127.0.0.1:\(port)');window.close();</script>"
        } else {
            status = "200 OK"
            html = "<title>Original site</title><form method='POST' target='login' action='http://localhost:\(port)/authorize'><input name='state' value='fixture-state'></form><script>window.result='pending';addEventListener('message',e=>{if(e.origin==='http://localhost:\(port)')window.result=e.data;});</script>"
        }
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\(extraHeaders)\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

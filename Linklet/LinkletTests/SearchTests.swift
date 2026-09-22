import AppKit
import Carbon
import XCTest
import WebKit
@testable import Linklet

final class SearchInputTests: XCTestCase {
    func testQueriesRoundTripForEveryEngine() throws {
        let query = "C++ и Swift & #100% / café?"
        for engine in SearchEngine.allCases {
            let url = try XCTUnwrap(SearchInput.destination(for: " \(query)\n", engine: engine))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.first?.value, query)
            XCTAssertEqual(components.queryItems?.first?.name, engine == .yandex ? "text" : "q")
            XCTAssertTrue(url.absoluteString.contains("C%2B%2B"))
        }
    }

    func testAddressesBypassSearch() throws {
        for address in ["https://example.com/a?q=hello#part", "http://localhost:8080", "example.com/path",
                        "//example.com/a", "127.0.0.1:8000/path", "[::1]:8080", "пример.рф/путь"] {
            let url = try XCTUnwrap(SearchInput.destination(for: address, engine: .bing))
            XCTAssertNotEqual(url.host, "www.bing.com", address)
        }
    }

    func testPlainTextAndUnsafeSchemesAreQueries() throws {
        for query in ["hello", "hello world", "swift 6.2", "3.14", "user@example.com", "javascript:alert(1)",
                      "file:///tmp/test", "https://", "https://example.com hello"] {
            let url = try XCTUnwrap(SearchInput.destination(for: query, engine: .google))
            XCTAssertEqual(url.host, "www.google.com", query)
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, query)
        }
        XCTAssertNil(SearchInput.destination(for: " \n\t", engine: .google))
    }
}

@MainActor
final class SearchSettingsTests: XCTestCase {
    func testRegisteredHotKeyDispatchesItsAction() throws {
        let shortcut = SearchShortcut(keyCode: 19, modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey), keyLabel: "2")
        let hotKey = SearchHotKey()
        var invocations = 0
        hotKey.action = { invocations += 1 }
        XCTAssertTrue(hotKey.register(shortcut))
        defer { hotKey.unregister() }
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                   GetCurrentEventTime(), 0, &event), noErr)
        let keyEvent = try XCTUnwrap(event)
        defer { ReleaseEvent(keyEvent) }
        var identifier = EventHotKeyID(signature: 0x4C4E4B53, id: 1)
        XCTAssertEqual(SetEventParameter(keyEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
        XCTAssertEqual(SendEventToEventTarget(keyEvent, GetApplicationEventTarget()), noErr)
        XCTAssertEqual(invocations, 1, "Dispatch immediately on key-down")
        XCTAssertEqual(SendEventToEventTarget(keyEvent, GetApplicationEventTarget()), noErr)
        var release: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyReleased),
                                   GetCurrentEventTime(), 0, &release), noErr)
        let releaseEvent = try XCTUnwrap(release)
        defer { ReleaseEvent(releaseEvent) }
        XCTAssertEqual(SetEventParameter(releaseEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
        XCTAssertEqual(SendEventToEventTarget(releaseEvent, GetApplicationEventTarget()), noErr)
        XCTAssertEqual(invocations, 1)
        XCTAssertEqual(SendEventToEventTarget(releaseEvent, GetApplicationEventTarget()), noErr)
        XCTAssertEqual(invocations, 1, "Repeated press/release events must not toggle the UI again")
    }

    func testHotKeyRegistersDetectsConflictAndReleases() {
        let shortcut = SearchShortcut(keyCode: 18, modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey), keyLabel: "1")
        let first = SearchHotKey()
        let second = SearchHotKey()
        XCTAssertTrue(first.register(shortcut))
        XCTAssertFalse(second.register(shortcut))
        first.unregister()
        XCTAssertTrue(second.register(shortcut))
        second.unregister()
    }

    func testPreferencesPersistAndShortcutCanBeDisabled() {
        let suite = "LinkletSearchTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        XCTAssertEqual(settings.engine, .google)
        XCTAssertEqual(settings.shortcut, .initial)
        settings.setEngine(.duckDuckGo)
        let shortcut = SearchShortcut(keyCode: 40, modifiers: UInt32(cmdKey | optionKey), keyLabel: "K")
        XCTAssertTrue(settings.setShortcut(shortcut))
        let reloaded = SearchSettings(defaults: defaults)
        XCTAssertEqual(reloaded.engine, .duckDuckGo)
        XCTAssertEqual(reloaded.shortcut, shortcut)
        reloaded.setShortcut(nil)
        XCTAssertNil(SearchSettings(defaults: defaults).shortcut)
    }

    func testFavoriteSitesValidatePersistAndKeepTheirOrder() throws {
        let suite = "LinkletFavoriteSitesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)

        let swift = try settings.addFavoriteSite(name: "Swift", address: "swift.org")
        let example = try settings.addFavoriteSite(name: "", address: "https://example.com/docs")
        XCTAssertEqual(swift.address, "https://swift.org")
        XCTAssertEqual(example.name, "example.com")
        XCTAssertEqual(settings.favoriteSites.map(\.name), ["Swift", "example.com"])
        XCTAssertThrowsError(try settings.addFavoriteSite(name: "Again", address: "https://swift.org")) {
            XCTAssertEqual($0 as? FavoriteSiteError, .duplicateURL)
        }
        XCTAssertThrowsError(try settings.addFavoriteSite(name: "Local", address: "file:///tmp/site")) {
            XCTAssertEqual($0 as? FavoriteSiteError, .invalidURL)
        }

        settings.moveFavoriteSite(example.id, before: swift.id)
        try settings.updateFavoriteSite(swift, name: "Swift language", address: "https://swift.org/documentation")
        let reloaded = SearchSettings(defaults: defaults)
        XCTAssertEqual(reloaded.favoriteSites.map(\.name), ["example.com", "Swift language"])
        XCTAssertEqual(reloaded.favoriteSites.last?.address, "https://swift.org/documentation")
        reloaded.removeFavoriteSite(reloaded.favoriteSites[0])
        XCTAssertEqual(SearchSettings(defaults: defaults).favoriteSites.map(\.name), ["Swift language"])
        reloaded.setShowsFavoriteSites(false)
        XCTAssertFalse(SearchSettings(defaults: defaults).showsFavoriteSites)
    }

    func testPanelResetsQueryAndTemporaryEngineAndSubmitsOrdinaryURL() throws {
        let suite = "LinkletSearchPanelTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        settings.setEngine(.yandex)
        var opened: URL?
        let controller = SearchWindowController(settings: settings) { opened = $0 }
        controller.present()
        defer { controller.close() }
        XCTAssertEqual(controller.window!.frame.height, 140)
        XCTAssertEqual(controller.selection.engine, .yandex)
        XCTAssertNotNil(controller.input.currentEditor(), "Typing must go straight into the query")
        controller.input.stringValue = "test query"
        controller.selection.engine = .bing
        controller.submit()
        XCTAssertEqual(opened?.host, "www.bing.com")
        XCTAssertEqual(settings.engine, .yandex)
        XCTAssertFalse(controller.window!.isVisible)
        controller.present()
        XCTAssertEqual(controller.input.stringValue, "")
        XCTAssertEqual(controller.selection.engine, .yandex)
        controller.input.stringValue = "example.com/path"
        controller.submit()
        XCTAssertEqual(opened?.absoluteString, "https://example.com/path")
        controller.present()
        controller.input.stringValue = "discard me"
        controller.close()
        controller.present()
        XCTAssertEqual(controller.input.stringValue, "")
    }

    func testPanelShowsFavoritesAndOpensThemThroughItsURLHandler() throws {
        let suite = "LinkletFavoritePanelTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        let site = try settings.addFavoriteSite(name: "Example", address: "example.com")
        var opened: URL?
        let controller = SearchWindowController(settings: settings) { opened = $0 }
        controller.present()
        XCTAssertEqual(controller.window!.frame.height, 220)
        XCTAssertFalse(controller.window!.hasShadow)
        controller.close()
        settings.setShowsFavoriteSites(false)
        controller.present()
        XCTAssertEqual(controller.window!.frame.height, 140, "Saved favorites can be hidden without deleting them")
        controller.openFavorite(site)
        XCTAssertEqual(opened?.absoluteString, "https://example.com")
        XCTAssertFalse(controller.window!.isVisible)
    }

    func testOpeningSearchDoesNotShowAnAutofillWindow() async throws {
        let suite = "LinkletSearchPanelAutofillTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SearchWindowController(settings: SearchSettings(defaults: defaults)) { _ in }

        controller.present()
        defer { controller.close() }
        XCTAssertNotNil(controller.input.currentEditor())
        for _ in 0..<40 {
            XCTAssertFalse(NSApp.windows.contains { $0.parent === controller.window },
                           "Focusing the search field must not open an autofill window")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testFavoriteKeyboardNavigationAndCommandShortcutsOpenTheSelectedSite() throws {
        let suite = "LinkletFavoriteKeyboardTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        _ = try settings.addFavoriteSite(name: "First", address: "first.example")
        let second = try settings.addFavoriteSite(name: "Second", address: "second.example")
        var opened: URL?
        let controller = SearchWindowController(settings: settings) { opened = $0 }
        controller.present()

        XCTAssertTrue(controller.handlePanelKeyEvent(keyEvent(keyCode: 19, characters: "2", modifiers: .command)))
        XCTAssertEqual(opened?.host, "second.example")

        opened = nil
        controller.present()
        XCTAssertTrue(controller.control(controller.input, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(controller.handlePanelKeyEvent(keyEvent(keyCode: 124, characters: "", modifiers: [])))
        XCTAssertTrue(controller.handlePanelKeyEvent(keyEvent(keyCode: 36, characters: "\r", modifiers: [])))
        XCTAssertEqual(opened?.absoluteString, second.address)
    }

    private func keyEvent(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }
}

@MainActor
final class SearchWebPreviewTests: XCTestCase {
    func testWebPreviewAdvertisesDesktopSafariWithoutReplacingNativePlatform() async throws {
        let baseline = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        let original = try await baseline.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650),
                             configuration: WebPreview.configuration(websiteDataStore: .nonPersistent()))
        let configured = try await view.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        print("Default WKWebView UA: \(original)")
        print("Linklet desktop UA: \(configured)")
        XCTAssertTrue(original.contains("Macintosh"))
        XCTAssertTrue(configured.contains("Macintosh"))
        XCTAssertTrue(configured.contains("Version/"))
        XCTAssertTrue(configured.contains("Safari/"))
        XCTAssertFalse(configured.contains("Mobile"))
        XCTAssertEqual(view.customUserAgent, baseline.customUserAgent, "Keep WebKit's system platform and engine tokens")
    }
}

final class SearchRequestTests: XCTestCase {
    func testRaycastTextRoundTripsIntoEverySearchEngine() throws {
        let source = "linklet://search?text=C%2B%2B%20%2F%20caf%C3%A9%20%26%20%D0%9F%D1%80%D0%B8%D0%B2%D0%B5%D1%82%20%23100%25%3F%0Asecond"
        let query = try XCTUnwrap(SearchRequest.query(from: URL(string: source)!))
        XCTAssertEqual(query, "C++ / café & Привет #100%?\nsecond")
        for engine in SearchEngine.allCases {
            let items = URLComponents(url: engine.searchURL(for: query), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.first?.value, query)
        }
    }

    func testRejectsInvalidRequestsAndPreservesURLSelectionAsText() {
        for request in ["linklet://search", "linklet://search?text=%20", "linklet://other?text=hello",
                        "https://search?text=hello", "linklet://search/other?text=hello",
                        "linklet://search?text=one&text=two", "linklet://search?text=test&engine=bing",
                        "linklet://user@search?text=hello", "linklet://search?text=hello#extra"] {
            XCTAssertNil(SearchRequest.query(from: URL(string: request)!))
        }
        XCTAssertEqual(SearchRequest.query(from: URL(string: "linklet://search?text=https%3A%2F%2Fexample.com")!), "https://example.com")
    }
}

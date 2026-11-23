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

    func testPanelDesignDefaultsToFloatingAndPersistsExplicitChoices() {
        let suite = "LinkletSearchDesignTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        XCTAssertEqual(settings.panelDesign, .floating)

        settings.setPanelDesign(.notch)
        XCTAssertEqual(SearchSettings(defaults: defaults).panelDesign, .notch)
        settings.setPanelDesign(.floating)
        XCTAssertEqual(SearchSettings(defaults: defaults).panelDesign, .floating)

        defaults.set("unrecognized", forKey: "searchPanelDesign")
        XCTAssertEqual(SearchSettings(defaults: defaults).panelDesign, .floating)
    }

    func testHidingEngineIconPersistsAndFreesSpaceInBothDesigns() {
        let suite = "LinkletSearchEngineIconTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        XCTAssertTrue(settings.showsEngineIcon)
        settings.setEngine(.duckDuckGo)
        var opened: URL?
        let controller = SearchWindowController(settings: settings, reduceMotion: { true }) { opened = $0 }
        defer { controller.close() }

        for design in SearchPanelDesign.allCases {
            settings.setPanelDesign(design)
            settings.setShowsEngineIcon(true)
            controller.present()
            let openWindow = controller.window
            openWindow?.contentView?.layoutSubtreeIfNeeded()
            let widthWithIcon = controller.input.frame.width

            settings.setShowsEngineIcon(false)
            XCTAssertFalse(SearchSettings(defaults: defaults).showsEngineIcon)
            openWindow?.contentView?.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(controller.input.frame.width, widthWithIcon)
            XCTAssertTrue(controller.window === openWindow)
            XCTAssertTrue(controller.isVisible)
            XCTAssertNil(controller.input.nextKeyView)
            XCTAssertNotNil(controller.input.currentEditor())
            XCTAssertEqual(controller.selection.engine, .duckDuckGo)
            settings.setShowsEngineIcon(true)
            openWindow?.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(controller.input.frame.width, widthWithIcon)
            XCTAssertNotNil(controller.input.nextKeyView)
            settings.setShowsEngineIcon(false)
            controller.input.stringValue = "test query"
            controller.submit()
            XCTAssertEqual(opened?.host, "duckduckgo.com")
        }
    }

    func testNotchPlaceholderUsesMutedColorAndKeepsTheInputFont() throws {
        let suite = "LinkletSearchPlaceholderTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        settings.setPanelDesign(.notch)
        let controller = SearchWindowController(settings: settings, reduceMotion: { true }) { _ in }
        defer { controller.close() }
        controller.present()

        let placeholder = try XCTUnwrap(controller.input.placeholderAttributedString)
        XCTAssertEqual(placeholder.string, L("Search or enter address"))
        let color = try XCTUnwrap(placeholder.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let font = try XCTUnwrap(placeholder.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let expectedOpacity = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.72 : 0.44
        XCTAssertEqual(color.alphaComponent, expectedOpacity, accuracy: 0.001)
        XCTAssertEqual(font.pointSize, 20)
        XCTAssertEqual(font, controller.input.font)
        XCTAssertEqual(controller.input.textColor, .labelColor)

        settings.setPanelDesign(.floating)
        controller.present()
        XCTAssertEqual(controller.input.placeholderString, placeholder.string)
        XCTAssertEqual(controller.input.font?.pointSize, 24)
    }

    func testNotchStaysAtScreenEdgeAndKeepsTheCompactHeightWithoutBookmarks() {
        let screen = CGRect(x: -1440, y: 150, width: 1440, height: 900)
        let cutout = CGRect(x: -800, y: screen.maxY - 32, width: 160, height: 32)
        let placement = SearchNotchPlacement(screenFrame: screen, menuBarHeight: 32, hardwareNotch: cutout)
        let full = placement.panelFrame(showsFavorites: true)
        let compact = placement.panelFrame(showsFavorites: false)
        XCTAssertEqual(full.maxY, screen.maxY)
        XCTAssertEqual(compact.maxY, screen.maxY)
        XCTAssertEqual(full.midX, cutout.midX)
        XCTAssertEqual(compact.width, full.width)
        XCTAssertEqual(full.height - compact.height, SearchNotchLayout.favoritesHeight + SearchNotchLayout.rowGap)
        XCTAssertEqual(placement.outline(in: full.size, motion: .closed).rect.width, cutout.width)
        let open = placement.outline(in: full.size, motion: .open).rect
        XCTAssertEqual(open, CGRect(x: 0, y: 0, width: full.width, height: full.height - SearchNotchLayout.animationClearance))
        let rebound = placement.outline(in: full.size, motion: .closed.moving(toward: .open, fraction: 0.66)).rect
        XCTAssertGreaterThan(rebound.height, open.height)
        XCTAssertLessThanOrEqual(rebound.height, full.height)
        XCTAssertTrue(placement.containsHoverPoint(CGPoint(x: cutout.midX, y: cutout.minY - 2)))
        XCTAssertTrue(placement.containsHoverPoint(CGPoint(x: cutout.minX, y: screen.maxY)))
        XCTAssertTrue(placement.containsHoverPoint(CGPoint(x: cutout.maxX, y: screen.maxY)))
        XCTAssertFalse(placement.containsHoverPoint(CGPoint(x: cutout.maxX + 1, y: screen.maxY)))
        XCTAssertFalse(placement.containsHoverPoint(CGPoint(x: cutout.midX, y: screen.maxY + 1)))

        let external = SearchNotchPlacement(screenFrame: screen, menuBarHeight: 24, hardwareNotch: nil)
        XCTAssertFalse(external.containsHoverPoint(CGPoint(x: screen.midX, y: screen.maxY)))
        XCTAssertEqual(external.panelFrame(showsFavorites: false).midX, screen.midX)
    }

    func testNotchMotionSpreadsFirstAndRevealsSearchBeforeBookmarks() {
        let spread = SearchNotchMotion.closed.moving(toward: .open, fraction: 0.2)
        XCTAssertGreaterThan(spread.width, spread.depth)
        let revealing = SearchNotchMotion.closed.moving(toward: .open, fraction: 0.44)
        XCTAssertGreaterThan(revealing.searchOpacity, 0)
        XCTAssertEqual(revealing.favoritesOpacity, 0)
        XCTAssertEqual(revealing.moving(toward: .closed, fraction: 0), revealing)
        XCTAssertEqual(revealing.moving(toward: .closed, fraction: 1), .closed)
        XCTAssertEqual(SearchNotchMotion.closed.moving(toward: .open, fraction: 1), .open)
    }

    func testNotchShouldersExpandSymmetricallyWhileLeavingThePanelBodyInPlace() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let cutout = CGRect(x: 560, y: 768, width: 160, height: 32)
        let placement = SearchNotchPlacement(screenFrame: screen, menuBarHeight: 32, hardwareNotch: cutout)
        let size = placement.panelFrame(showsFavorites: true, preferredWidth: SearchNotchLayout.maximumWindowWidth).size
        let closed = placement.outline(in: size, motion: .closed)
        let unfolding = placement.outline(in: size, motion: .closed.moving(toward: .open, fraction: 0.30))
        let open = placement.outline(in: size, motion: .open)

        XCTAssertEqual(closed.contour.shoulder, 0)
        XCTAssertGreaterThan(unfolding.contour.shoulder, 0)
        XCTAssertLessThan(unfolding.contour.shoulder, open.contour.shoulder)
        XCTAssertEqual(unfolding.rect.midX, size.width / 2)
        XCTAssertEqual(open.rect.width - 2 * open.contour.shoulder, 660)

        let path = open.contour.path(in: open.rect)
        let shoulder = open.contour.shoulder
        for x in [open.rect.minX + shoulder / 2, open.rect.maxX - shoulder / 2] {
            XCTAssertTrue(path.contains(CGPoint(x: x, y: 1)), "The transition reaches the top edge")
            XCTAssertFalse(path.contains(CGPoint(x: x, y: shoulder / 2)), "The shoulder curves back into the body")
        }
        XCTAssertTrue(path.contains(CGPoint(x: open.rect.midX, y: open.rect.maxY - 1)))
    }

    func testNotchHoverWaitsForIntentAndDoesNotReopenUntilPointerLeaves() throws {
        let suite = "LinkletSearchHoverTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        settings.setPanelDesign(.notch)
        let screen = try XCTUnwrap(NSScreen.main).frame
        let cutout = CGRect(x: screen.midX - 80, y: screen.maxY - 32, width: 160, height: 32)
        let placement = SearchNotchPlacement(screenFrame: screen, menuBarHeight: 32, hardwareNotch: cutout)
        let edge = CGPoint(x: cutout.midX, y: screen.maxY)
        let outside = CGPoint(x: cutout.midX, y: screen.midY)
        let controller = SearchWindowController(settings: settings, reduceMotion: { true }) { _ in }
        defer { controller.close() }

        controller.pollNotchHover(at: edge, now: 1, placements: [placement])
        controller.pollNotchHover(at: edge, now: 1.08, placements: [placement])
        XCTAssertFalse(controller.isVisible)
        controller.pollNotchHover(at: edge, now: 1.17, placements: [placement])
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.window?.frame, placement.panelFrame(showsFavorites: false))

        controller.close()
        controller.pollNotchHover(at: edge, now: 2, placements: [placement])
        controller.pollNotchHover(at: edge, now: 3, placements: [placement])
        XCTAssertFalse(controller.isVisible)
        controller.pollNotchHover(at: outside, now: 4, placements: [placement])
        controller.pollNotchHover(at: edge, now: 5, placements: [placement])
        controller.pollNotchHover(at: edge, now: 5.17, placements: [placement])
        XCTAssertTrue(controller.isVisible)
        controller.pollNotchHover(at: outside, now: 6, placements: [placement])
        controller.pollNotchHover(at: outside, now: 6.26, placements: [placement])
        XCTAssertFalse(controller.isVisible)
    }

    func testNotchFitsNativeEditorTextAndCapsWidthWhilePreservingFocus() throws {
        let suite = "LinkletAdaptiveSearchWidthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        settings.setPanelDesign(.notch)
        let controller = SearchWindowController(settings: settings, reduceMotion: { true }) { _ in }
        controller.present()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let screen = try XCTUnwrap(window.screen)
        let maximum = SearchNotchPlacement(screen: screen).panelFrame(
            showsFavorites: false, preferredWidth: SearchNotchLayout.maximumWindowWidth
        )
        let compact = window.frame
        let editor = try XCTUnwrap(controller.input.currentEditor() as? NSTextView)
        func enter(_ text: String) {
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }

        enter("Swift")
        XCTAssertEqual(window.frame, compact)
        enter(String(repeating: "W", count: 22))
        let mediumWidth = window.frame.width
        XCTAssertGreaterThan(mediumWidth, compact.width)
        XCTAssertLessThan(mediumWidth, maximum.width)
        settings.setShowsEngineIcon(false)
        XCTAssertLessThan(window.frame.width, mediumWidth)

        let longQuery = String(repeating: "длинный запрос 👋 ", count: 200)
        enter(longQuery)
        XCTAssertEqual(window.frame, maximum)
        XCTAssertTrue(controller.input.currentEditor() === editor)
        XCTAssertEqual(editor.string, longQuery)
        XCTAssertEqual(editor.selectedRange().location, longQuery.utf16.count)
        enter("Short")
        XCTAssertEqual(window.frame, compact)

        controller.close()
        settings.setPanelDesign(.floating)
        controller.present()
        let floatingWindow = try XCTUnwrap(controller.window)
        let floatingFrame = floatingWindow.frame
        let floatingEditor = try XCTUnwrap(controller.input.currentEditor() as? NSTextView)
        floatingEditor.insertText(longQuery, replacementRange: floatingEditor.selectedRange())
        XCTAssertEqual(floatingWindow.frame, floatingFrame)
    }

    func testNotchAnimatesWidthWhileKeepingTheSameWindowAndScreenAnchor() async throws {
        let suite = "LinkletAnimatedSearchWidthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        settings.setPanelDesign(.notch)
        let controller = SearchWindowController(settings: settings, reduceMotion: { false }) { _ in }
        controller.present()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let editor = try XCTUnwrap(controller.input.currentEditor() as? NSTextView)
        let compact = window.frame

        editor.insertText(String(repeating: "W", count: 80), replacementRange: editor.selectedRange())
        XCTAssertEqual(window.frame, compact, "A long paste should start a width animation")
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertGreaterThan(window.frame.width, compact.width)
        XCTAssertEqual(window.frame.midX, compact.midX, accuracy: 0.5)
        XCTAssertEqual(window.frame.maxY, compact.maxY)
        XCTAssertTrue(controller.input.currentEditor() === editor)

        editor.insertText("short", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(window.frame, compact)
        XCTAssertTrue(controller.window === window)
    }

    func testChangingToFloatingClosesNotchAndDisablesHover() throws {
        let suite = "LinkletHoverDesignTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        let screen = try XCTUnwrap(NSScreen.main).frame
        let cutout = CGRect(x: screen.midX - 80, y: screen.maxY - 32, width: 160, height: 32)
        let placement = SearchNotchPlacement(screenFrame: screen, menuBarHeight: 32, hardwareNotch: cutout)
        let edge = CGPoint(x: cutout.midX, y: screen.maxY)
        let controller = SearchWindowController(settings: settings, reduceMotion: { true }) { _ in }
        controller.startNotchHover()
        defer { controller.close() }

        settings.setPanelDesign(.notch)
        controller.pollNotchHover(at: edge, now: 1, placements: [placement])
        controller.pollNotchHover(at: edge, now: 1.2, placements: [placement])
        XCTAssertTrue(controller.isVisible)

        settings.setPanelDesign(.floating)
        XCTAssertFalse(controller.window?.isVisible ?? true)
        controller.pollNotchHover(at: edge, now: 2, placements: [placement])
        controller.pollNotchHover(at: edge, now: 3, placements: [placement])
        XCTAssertFalse(controller.isVisible)
        controller.present()
        XCTAssertEqual(controller.window?.level, .floating)
        controller.pollNotchHover(at: edge, now: 4, placements: [placement])
        XCTAssertEqual(controller.window?.level, .floating)
    }

    func testBothSearchDesignsFollowTheSameBookmarkLibraryOrder() throws {
        let suite = "LinkletSharedSearchBookmarksTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults) { _ in throw URLError(.resourceUnavailable) }
        let library = LinkLibrary(defaults: defaults)
        library.bind(to: settings)
        let first = try settings.addFavoriteSite(name: "First", address: "first.example")
        let second = try settings.addFavoriteSite(name: "Second", address: "second.example")
        let folder = try XCTUnwrap(library.addFolder(name: "Work"))
        library.moveItem(second.id, before: nil, into: folder.id)
        library.moveItem(folder.id, before: first.id)
        XCTAssertEqual(settings.favoriteSites.map(\.id), [second.id, first.id])

        var opened: URL?
        let controller = SearchWindowController(settings: settings, reduceMotion: { true }) { opened = $0 }
        defer { controller.close() }
        let firstBookmark = keyEvent(keyCode: 18, characters: "1", modifiers: .command)
        for design in SearchPanelDesign.allCases {
            settings.setPanelDesign(design)
            controller.present()
            XCTAssertTrue(controller.handlePanelKeyEvent(firstBookmark))
            XCTAssertEqual(opened, second.url)
        }

        settings.removeFavoriteSite(second)
        for design in SearchPanelDesign.allCases {
            settings.setPanelDesign(design)
            controller.present()
            XCTAssertTrue(controller.handlePanelKeyEvent(firstBookmark))
            XCTAssertEqual(opened, first.url)
        }
    }

    func testSwitchingDesignKeepsSearchFocusAndKeyboardNavigationAcrossTenBookmarks() throws {
        let suite = "LinkletSearchDesignKeyboardTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        for index in 1...10 {
            _ = try settings.addFavoriteSite(name: "Saved bookmark \(index)", address: "example.com/\(index)")
        }
        var opened: URL?
        let controller = SearchWindowController(settings: settings, reduceMotion: { true }) { opened = $0 }
        defer { controller.close() }
        controller.present()
        XCTAssertEqual(controller.window?.frame.height, 220)
        XCTAssertNotNil(controller.input.currentEditor())

        settings.setPanelDesign(.notch)
        controller.present()
        XCTAssertEqual(controller.window?.level, .statusBar)
        XCTAssertNotNil(controller.input.currentEditor())
        XCTAssertTrue(controller.control(controller.input, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        for _ in 1..<10 {
            XCTAssertTrue(controller.handlePanelKeyEvent(keyEvent(keyCode: 124, characters: "", modifiers: [])))
        }
        XCTAssertTrue(controller.handlePanelKeyEvent(keyEvent(keyCode: 36, characters: "\r", modifiers: [])))
        XCTAssertEqual(opened?.absoluteString, "https://example.com/10")

        settings.setPanelDesign(.floating)
        controller.present()
        XCTAssertEqual(controller.window?.frame.height, 220)
        XCTAssertNotNil(controller.input.currentEditor())
    }

    func testNotchAnimationCanReverseAndFinishDismissing() async throws {
        let suite = "LinkletSearchAnimationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        settings.setPanelDesign(.notch)
        let controller = SearchWindowController(settings: settings, reduceMotion: { false }) { _ in }
        defer { controller.close() }

        controller.toggle()
        try await Task.sleep(for: .milliseconds(100))
        controller.toggle()
        XCTAssertFalse(controller.isVisible)
        controller.toggle()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(controller.isVisible)
        XCTAssertNotNil(controller.input.currentEditor())
        controller.toggle()
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertFalse(controller.window?.isVisible ?? true)

        controller.toggle()
        controller.toggle()
        controller.toggle()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(controller.window?.isKeyWindow ?? false)
        XCTAssertTrue(controller.isVisible)
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

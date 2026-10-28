import XCTest
import WebKit
import SwiftUI
import Network
import Carbon
import ImageIO
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

    func testMixedBookmarkOrderMigratesAndSurvivesMovesAndRelaunch() throws {
        let suite = "MixedBookmarks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        let a = try settings.addFavoriteSite(name: "A", address: "https://a.example")
        let b = try settings.addFavoriteSite(name: "B", address: "https://b.example")
        let c = try settings.addFavoriteSite(name: "C", address: "https://c.example")
        let library = LinkLibrary(defaults: defaults)
        let work = try XCTUnwrap(library.addFolder(name: "Work"))
        library.moveBookmark(b, to: work.id)
        defaults.removeObject(forKey: "bookmarkRootOrder") // Version 1.5 build 10 had no mixed order.
        let migrated = LinkLibrary(defaults: defaults)
        migrated.bind(to: settings)
        XCTAssertEqual(migrated.rootOrder, [a.id, c.id, work.id])
        migrated.moveItem(work.id, before: a.id)
        XCTAssertEqual(settings.favoriteSites.map(\.id), [b.id, a.id, c.id])
        migrated.moveItem(c.id, before: b.id, into: work.id)
        XCTAssertEqual(settings.favoriteSites.map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(migrated.folderID(for: c), work.id)
        migrated.moveItem(c.id, offset: 1)
        XCTAssertEqual(settings.favoriteSites.map(\.id), [b.id, c.id, a.id])
        // Reordering from Favorites settings uses the same folder assignment and insertion rules.
        settings.moveFavoriteSite(a.id, before: c.id)
        XCTAssertEqual(migrated.folderID(for: a), work.id)
        XCTAssertEqual(settings.favoriteSites.map(\.id), [b.id, a.id, c.id])
        migrated.moveItem(c.id, before: work.id)
        XCTAssertNil(migrated.folderID(for: c))
        XCTAssertEqual(migrated.rootOrder, [c.id, work.id])
        let restoredSettings = SearchSettings(defaults: defaults)
        let restored = LinkLibrary(defaults: defaults)
        restored.bind(to: restoredSettings)
        XCTAssertEqual(restored.rootOrder, [c.id, work.id])
        XCTAssertEqual(restoredSettings.favoriteSites.map(\.id), [c.id, b.id, a.id])
        restored.removeFolder(work)
        XCTAssertEqual(restored.rootOrder, [c.id, b.id, a.id])
        XCTAssertEqual(restoredSettings.favoriteSites.map(\.id), [c.id, b.id, a.id])
        XCTAssertTrue(restored.folderAssignments.isEmpty)
        restoredSettings.removeFavoriteSite(b)
        XCTAssertEqual(restored.rootOrder, [c.id, a.id])
        restored.moveItem(UUID(), before: a.id)
        XCTAssertEqual(restored.rootOrder, [c.id, a.id])
    }

    func testSharedIconsDeduplicateOriginsAndPersistOnlyBookmarks() async throws {
        let suite = "SharedIcons.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data([1, 2, 3])
        var requested: [URL] = []
        let settings = SearchSettings(defaults: defaults, fetchIcon: { url in
            requested.append(url)
            try await Task.sleep(for: .milliseconds(20))
            return data
        })
        let a = try settings.addFavoriteSite(name: "A", address: "https://example.com/a")
        _ = try settings.addFavoriteSite(name: "B", address: "https://example.com/b")
        let historyURL = URL(string: "https://user:password@example.com/history?secret=123#private")!
        async let first: Void = settings.ensureIcon(for: a.url)
        async let second: Void = settings.ensureIcon(for: historyURL)
        _ = await (first, second)
        XCTAssertEqual(requested, [URL(string: "https://example.com")!])
        XCTAssertEqual(settings.iconData(for: historyURL), data)
        XCTAssertTrue(settings.favoriteSites.allSatisfy { $0.faviconData == data })
        XCTAssertTrue(settings.loadingFavoriteIconIDs.isEmpty)
        XCTAssertEqual(SearchSettings(defaults: defaults).iconData(for: historyURL), data)
        let historyOnly = URL(string: "https://history.example/private?token=secret")!
        await settings.ensureIcon(for: historyOnly)
        XCTAssertEqual(settings.iconData(for: historyOnly), data)
        XCTAssertNil(SearchSettings(defaults: defaults).iconData(for: historyOnly))
        let saved = try settings.addFavoriteSite(name: "From history", address: historyOnly.absoluteString)
        XCTAssertEqual(saved.faviconData, data)
        XCTAssertEqual(SearchSettings(defaults: defaults).iconData(for: saved.url), data)
        XCTAssertNil(defaults.data(forKey: "recentLinks"))
    }

    func testIconServiceFollowsDeclaredIconsAndDownsamplesWithoutSendingPageURL() async throws {
        let largeIcon = NSImage(size: NSSize(width: 256, height: 256))
        largeIcon.lockFocus()
        NSColor.systemOrange.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 256, height: 256)).fill()
        largeIcon.unlockFocus()
        let png = try XCTUnwrap(NSBitmapImageRep(data: largeIcon.tiffRepresentation!)?.representation(using: .png, properties: [:]))
        let server = try PopupHTTPFixture(iconData: png)
        let port = try await server.start()
        defer { server.stop() }
        let page = URL(string: "http://127.0.0.1:\(port)/private/document?token=secret#fragment")!
        let icon = try await FavoriteSiteIconService.fetch(for: page)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(icon as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 128)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 128)
        XCTAssertEqual(server.iconRequests, ["GET /favicon.ico HTTP/1.1", "GET / HTTP/1.1", "GET /custom-icon.png HTTP/1.1"])
    }

    func testDeclaredIconParsingSupportsAttributeOrderRelativePathsAndRejectsUnsafeURLs() {
        let html = #"<link href='/icons/site.png?v=1&amp;x=2' rel='shortcut icon'><LINK REL=apple-touch-icon HREF=touch.png><link rel='stylesheet' href='style.css'><link rel='icon' href='file:///private/key'><link rel='icon' href='https://user:password@example.com/icon.png'>"#
        XCTAssertEqual(FavoriteSiteIconService.declaredIcons(in: html, baseURL: URL(string: "https://example.com/")!).map(\.absoluteString),
                       ["https://example.com/touch.png", "https://example.com/icons/site.png?v=1&x=2"])
    }

    func testFailedIconsDoNotRetryOnEveryRowButCanBeRefreshed() async {
        let suite = "FailedIcons.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var attempts = 0
        let settings = SearchSettings(defaults: defaults, fetchIcon: { _ in
            attempts += 1
            throw FavoriteSiteIconError.unavailable
        })
        let url = URL(string: "https://example.com")!
        await settings.ensureIcon(for: url)
        await settings.ensureIcon(for: url)
        XCTAssertEqual(attempts, 1)
        await settings.ensureIcon(for: url, refresh: true)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(settings.loadingFavoriteIconIDs.isEmpty)
    }

    private func iconPNG(size: Int, color: NSColor) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }

    func testICOSelectsLargestRepresentationRatherThanFirstSmallFrame() throws {
        let sizes = [16, 64, 128]
        let images = sizes.map { iconPNG(size: $0, color: .red) }
        var ico = Data([0, 0, 1, 0, UInt8(images.count), 0])
        var offset = 6 + images.count * 16
        func littleEndian(_ value: Int) -> Data {
            var number = UInt32(value).littleEndian
            return withUnsafeBytes(of: &number) { Data($0) }
        }
        for (index, image) in images.enumerated() {
            ico.append(contentsOf: [UInt8(sizes[index]), UInt8(sizes[index]), 0, 0, 1, 0, 32, 0])
            ico.append(littleEndian(image.count)); ico.append(littleEndian(offset)); offset += image.count
        }
        images.forEach { ico.append($0) }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(ico as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        let prepared = try FavoriteSiteIconService.prepare(ico)
        XCTAssertEqual(prepared.pixelSize, 128)
        let output = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 128)
    }

    func testSmallConventionalIconDoesNotHideLargerDeclaredIconAndHTTPValidationUpdatesIt() async throws {
        let server = try PopupHTTPFixture(iconData: iconPNG(size: 256, color: .red), conventionalIcon: iconPNG(size: 16, color: .blue))
        let port = try await server.start()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/private?token=secret")!
        let first = try await FavoriteSiteIconService.fetch(for: url)
        XCTAssertEqual(try FavoriteSiteIconService.prepare(first).pixelSize, 128)
        let second = try await FavoriteSiteIconService.fetch(for: url)
        XCTAssertEqual(first, second)
        XCTAssertEqual(server.notModifiedCount, 3)
        XCTAssertEqual(server.downloadedIconCount, 1)
        server.updateIcon(iconPNG(size: 256, color: .green))
        let changed = try await FavoriteSiteIconService.fetch(for: url)
        XCTAssertNotEqual(changed, first)
        XCTAssertEqual(server.downloadedIconCount, 2)
        XCTAssertTrue(server.iconRequests.allSatisfy { !$0.contains("private") && !$0.contains("secret") })
    }

    func testLegacyIconCacheUpgradesAutomaticallyAndKeepsTheNewVersion() async throws {
        let suite = "IconUpgrade.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = FavoriteSite.make(name: "Old", address: "https://example.com", faviconData: iconPNG(size: 16, color: .red))!
        defaults.set(try JSONEncoder().encode([old]), forKey: "favoriteSites")
        let replacement = iconPNG(size: 128, color: .green)
        var fetchCount = 0
        let settings = SearchSettings(defaults: defaults, fetchIcon: { _ in fetchCount += 1; return replacement })
        XCTAssertEqual(settings.iconData(for: old.url), old.faviconData)
        await settings.ensureIcon(for: old.url)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(settings.iconData(for: old.url), replacement)
        XCTAssertEqual(settings.favoriteSites.first?.faviconVersion, FavoriteSiteIconService.pipelineVersion)
        let restored = SearchSettings(defaults: defaults, fetchIcon: { _ in fetchCount += 1; return replacement })
        await restored.ensureIcon(for: old.url)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(restored.iconData(for: old.url), replacement)
    }

    func testClearHistoryRequiresConfirmationAndCancelPreservesSavedHistory() {
        let suite = "ClearHistoryConfirmation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LinkLibrary(defaults: defaults)
        library.setEnabled(true); library.setSavesHistory(true)
        library.recordOpening(URL(string: "https://example.com")!)
        library.confirmHistoryClear()
        XCTAssertEqual(library.recentLinks.count, 1)
        library.requestHistoryClear()
        XCTAssertTrue(library.isHistoryClearPending)
        XCTAssertEqual(LinkLibrary(defaults: defaults).recentLinks.count, 1)
        library.cancelHistoryClear()
        XCTAssertFalse(library.isHistoryClearPending)
        XCTAssertEqual(library.recentLinks.count, 1)
        library.requestHistoryClear(); library.confirmHistoryClear()
        XCTAssertFalse(library.isHistoryClearPending)
        XCTAssertTrue(library.recentLinks.isEmpty)
        XCTAssertNil(defaults.data(forKey: "recentLinks"))
    }

    func testEdgeHoverOpensAtAnyHeightAfterConfiguredDelayOrUsesOptionalIndicator() throws {
        let suite = "SidebarEdgeModes.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.linkLibrary.setEnabled(true)
        let library = model.linkLibrary
        library.setEdgeOpenDelay(0.7)
        XCTAssertFalse(library.showsRevealIndicator)
        let controller = SidebarWindowController(model: model, reduceMotion: { true })
        defer { controller.hide(animated: false); library.setEnabled(false) }
        let screen = try XCTUnwrap(NSScreen.main)
        let edge = NSPoint(x: screen.frame.minX, y: screen.visibleFrame.maxY - 100)
        XCTAssertFalse(SidebarWindowController.indicatorFrame(screenFrame: screen.frame).contains(edge))
        let now = Date().addingTimeInterval(3)
        controller.pollMouse(at: edge, now: now)
        controller.pollMouse(at: edge, now: now.addingTimeInterval(0.65))
        XCTAssertFalse(controller.window!.isVisible)
        controller.pollMouse(at: edge, now: now.addingTimeInterval(0.75))
        XCTAssertTrue(controller.window!.isVisible)
        XCTAssertNil(controller.indicatorWindow)
        controller.pollMouse(at: edge, now: now.addingTimeInterval(1.5))
        XCTAssertTrue(controller.window!.isVisible, "Holding the opening edge outside the panel's vertical margins must keep it open")
        controller.hide()
        library.setShowsRevealIndicator(true)
        let later = now.addingTimeInterval(5)
        controller.pollMouse(at: edge, now: later)
        controller.pollMouse(at: edge, now: later.addingTimeInterval(0.3))
        XCTAssertNotNil(controller.indicatorWindow)
        XCTAssertFalse(controller.window!.isVisible)
        controller.pollMouse(at: edge, now: later.addingTimeInterval(1))
        XCTAssertFalse(controller.window!.isVisible)
        let indicator = try XCTUnwrap(controller.indicatorWindow)
        controller.pollMouse(at: NSPoint(x: indicator.frame.midX, y: indicator.frame.midY), now: later.addingTimeInterval(1.1))
        XCTAssertTrue(controller.window!.isVisible)
        let restored = LinkLibrary(defaults: defaults)
        XCTAssertTrue(restored.showsRevealIndicator)
        XCTAssertEqual(restored.edgeOpenDelay, 0.7)
        library.setEdgeOpenDelay(.infinity)
        XCTAssertEqual(library.edgeOpenDelay, 0.4)
        library.setEdgeOpenDelay(99)
        XCTAssertEqual(library.edgeOpenDelay, 2)
    }

    func testEveryCompletedSiteLoadRefreshesSharedIconIncludingReloads() async throws {
        let suite = "NavigationIconRefresh.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        var requests = 0
        let settings = SearchSettings(defaults: defaults, fetchIcon: { _ in
            requests += 1
            return Data([UInt8(requests)])
        })
        let model = AppModel(defaults: defaults, searchSettings: settings, discoverTargets: { [] })
        let url = URL(string: "http://127.0.0.1:\(port)/site")!
        _ = try settings.addFavoriteSite(name: "Fixture", address: url.absoluteString)
        let session = model.previewSession
        var initialTitles = 0
        session.onPageFinished = { _, _ in initialTitles += 1 }
        session.load(url)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                             configuration: WebPreview.configuration(websiteDataStore: session.websiteDataStore))
        let coordinator = WebPreview.Coordinator(session: session)
        view.navigationDelegate = coordinator
        session.attach(view)
        defer { session.endSession() }
        for _ in 0..<100 { if requests == 1 { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(requests, 1)
        view.reload()
        for _ in 0..<100 { if requests == 2 { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(initialTitles, 1)
        XCTAssertEqual(settings.favoriteSites.first?.faviconData, Data([2]))
        XCTAssertEqual(settings.iconData(for: url), Data([2]))
        XCTAssertEqual(session.originalURL, url)
    }

    func testSidebarSectionsCollapseReorderAndPersistIndependentlyOfBookmarks() throws {
        let suite = "SidebarSections.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults)
        let library = LinkLibrary(defaults: defaults)
        library.bind(to: settings)
        let site = try settings.addFavoriteSite(name: "Docs", address: "https://swift.org")
        XCTAssertEqual(library.sectionOrder, [.open, .bookmarks, .recent])
        XCTAssertEqual(library.expandedSections, Set(SidebarSection.allCases))
        library.toggleSection(.bookmarks)
        library.moveSection(.recent, before: .bookmarks)
        XCTAssertEqual(library.sectionOrder, [.open, .recent, .bookmarks])
        XCTAssertFalse(library.expandedSections.contains(.bookmarks))
        XCTAssertTrue(library.expandedSections.contains(.recent))
        let restored = LinkLibrary(defaults: defaults)
        XCTAssertEqual(restored.sectionOrder, [.open, .recent, .bookmarks])
        XCTAssertEqual(restored.expandedSections, [.open, .recent])
        restored.toggleSection(.open)
        restored.moveSection(.open, before: nil)
        let reordered = LinkLibrary(defaults: defaults)
        XCTAssertEqual(reordered.sectionOrder, [.recent, .bookmarks, .open])
        XCTAssertEqual(reordered.expandedSections, [.recent])
        restored.moveSection(.open, before: .recent)
        restored.toggleSection(.open)
        XCTAssertEqual(library.rootOrder, [site.id])
        XCTAssertEqual(settings.favoriteSites, [site])
        restored.moveSection(.recent, before: nil)
        restored.toggleSection(.bookmarks)
        XCTAssertEqual(restored.sectionOrder, [.open, .bookmarks, .recent])
        XCTAssertEqual(restored.expandedSections, Set(SidebarSection.allCases))
        defaults.set(try JSONEncoder().encode([SidebarSection.recent, .recent]), forKey: "sidebarSectionOrder")
        XCTAssertEqual(LinkLibrary(defaults: defaults).sectionOrder, [.open, .recent, .bookmarks])
        // A profile from before Open windows keeps its chosen order and collapses.
        defaults.set(try JSONEncoder().encode([SidebarSection.recent, .bookmarks]), forKey: "sidebarSectionOrder")
        defaults.set(false, forKey: "sidebarExpanded.recent")
        let migrated = LinkLibrary(defaults: defaults)
        XCTAssertEqual(migrated.sectionOrder, [.open, .recent, .bookmarks])
        XCTAssertEqual(migrated.expandedSections, [.open, .bookmarks])
        XCTAssertEqual(settings.favoriteSites, [site])
    }

    func testRecentPaginationAddsTenAndResetsWithoutDiscardingHistory() {
        let suite = "RecentPagination.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LinkLibrary(defaults: defaults)
        library.setEnabled(true)
        for index in 0..<25 { library.recordOpening(URL(string: "https://example.com/\(index)")!) }
        XCTAssertEqual(library.visibleRecentLinks.count, 10)
        XCTAssertEqual(library.visibleRecentLinks.first?.address, "https://example.com/24")
        XCTAssertEqual(library.visibleRecentLinks.last?.address, "https://example.com/15")
        XCTAssertTrue(library.hasMoreRecentLinks)
        library.showMoreRecentLinks()
        XCTAssertEqual(library.visibleRecentLinks.count, 20)
        XCTAssertTrue(library.hasMoreRecentLinks)
        library.showMoreRecentLinks()
        XCTAssertEqual(library.visibleRecentLinks.count, 25)
        XCTAssertFalse(library.hasMoreRecentLinks)
        library.resetRecentDisplayLimit()
        XCTAssertEqual(library.visibleRecentLinks.count, 10)
        XCTAssertEqual(library.recentLinks.count, 25)
        XCTAssertNil(defaults.data(forKey: "recentLinks"))
        library.showMoreRecentLinks()
        library.clearHistory()
        XCTAssertEqual(library.recentDisplayLimit, 10)
        XCTAssertTrue(library.visibleRecentLinks.isEmpty)
    }

    func testRevealIndicatorAndItsArrowStayVerticallyCentered() throws {
        let suite = "RevealCenter.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        let controller = SidebarWindowController(model: model)
        defer { controller.hide() }
        let screen = try XCTUnwrap(NSScreen.main)
        controller.showIndicator(on: screen)
        let panel = try XCTUnwrap(controller.indicatorWindow)
        XCTAssertEqual(panel.frame.midY, screen.frame.midY, accuracy: 1)
        XCTAssertEqual(panel.frame.minX, screen.frame.minX, accuracy: 0.5)
        let translated = NSRect(x: -1440, y: -900, width: 1440, height: 900)
        XCTAssertEqual(SidebarWindowController.indicatorFrame(screenFrame: translated).midY, translated.midY)
        let view = try XCTUnwrap(panel.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var whiteRows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.alphaComponent > 0.9, color.redComponent > 0.9, color.greenComponent > 0.9, color.blueComponent > 0.9 {
                    whiteRows.append(y)
                }
            }
        }
        XCTAssertFalse(whiteRows.isEmpty)
        let center = Double(whiteRows.reduce(0, +)) / Double(max(1, whiteRows.count))
        XCTAssertEqual(center, Double(bitmap.pixelsHigh - 1) / 2, accuracy: 2)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-sidebar-indicator.png"))
    }

    func testSidebarDismissesForFocusChangesAndPointerExitAfterManualOpening() throws {
        let suite = "SidebarDismissal.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.linkLibrary.setEnabled(true)
        let controller = SidebarWindowController(model: model, reduceMotion: { true })
        defer { controller.hide(animated: false); model.linkLibrary.setEnabled(false) }
        model.linkLibrary.showMoreRecentLinks()
        controller.toggle()
        XCTAssertEqual(model.linkLibrary.recentDisplayLimit, 10)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.hasShadow)
        let now = Date().addingTimeInterval(2)
        controller.pollMouse(at: NSPoint(x: window.frame.midX, y: window.frame.midY), now: now)
        let outside = NSPoint(x: window.frame.maxX + 100, y: window.frame.midY)
        controller.pollMouse(at: outside, now: now)
        XCTAssertTrue(window.isVisible)
        controller.pollMouse(at: outside, now: now.addingTimeInterval(0.6))
        XCTAssertFalse(window.isVisible)
        controller.toggle()
        XCTAssertTrue(window.isVisible)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        XCTAssertFalse(window.isVisible)
    }

    func testSidebarShouldersRemainAtTheEdgeThroughoutReveal() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 500)
        XCTAssertTrue(SidebarContour(revealProgress: 0).path(in: rect).isEmpty)
        for progress: CGFloat in [0.02, 0.05, 0.1, 0.3, 0.7, 1] {
            let path = SidebarContour(revealProgress: progress).path(in: rect)
            XCTAssertEqual(path.boundingRect.minX, rect.minX, accuracy: 0.001)
            XCTAssertEqual(path.boundingRect.maxX, rect.width * progress, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(path.boundingRect.minY, rect.minY)
            XCTAssertLessThanOrEqual(path.boundingRect.maxY, rect.maxY)
            if progress * rect.width >= 48 {
                XCTAssertTrue(path.contains(CGPoint(x: 0.1, y: 12)), "The upper shoulder must stay anchored once there is room for both corners")
                XCTAssertTrue(path.contains(CGPoint(x: 0.1, y: 488)), "The lower shoulder must stay anchored during dismissal")
            }
            XCTAssertTrue(path.contains(CGPoint(x: progress * rect.width / 2, y: 250)))
            XCTAssertFalse(path.contains(CGPoint(x: 150, y: 2)), "The shoulder's outer area must remain transparent")
        }
    }

    func testSidebarRightCornersKeepTheirRadiusDuringDismissal() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 500)
        for width: CGFloat in [300, 90, 48, 40, 18, 8] {
            let path = SidebarContour(revealProgress: width / rect.width, shoulderProgress: 0).path(in: rect)
            // CoreGraphics avoids SwiftUI Path's coarse hit-test tolerance near trimmed curves.
            // Halfway along a 24 pt quadratic corner: x = right - 6, y = top + 6.
            XCTAssertTrue(path.cgPath.contains(CGPoint(x: width - 6.5, y: 30)), "Upper corner at width \(width)")
            XCTAssertFalse(path.cgPath.contains(CGPoint(x: width - 5.5, y: 30)), "The right corner must not flatten as the visible width gets smaller")
            XCTAssertTrue(path.cgPath.contains(CGPoint(x: width - 6.5, y: 470)), "Lower corner at width \(width)")
            XCTAssertFalse(path.cgPath.contains(CGPoint(x: width - 5.5, y: 470)))
            XCTAssertEqual(path.boundingRect.minX, 0, accuracy: 0.001)
            XCTAssertEqual(path.boundingRect.maxX, width, accuracy: 0.001)
        }
    }

    func testSidebarResizeHoverSetsCursorAndTracksInactivePanels() throws {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = SidebarResizeView(frame: NSRect(x: 0, y: 0, width: 10, height: 200))
        panel.contentView = view
        view.updateTrackingAreas()
        let area = try XCTUnwrap(view.trackingAreas.first)
        XCTAssertTrue(area.options.contains(.activeAlways), "Hover must work without making the sidebar key")
        XCTAssertTrue(area.options.contains(.cursorUpdate))
        XCTAssertTrue(area.options.contains(.inVisibleRect))
        view.setFrameSize(NSSize(width: 10, height: 300))
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1, "Resizing must replace the tracking area instead of leaving stale regions")
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        let original = NSCursor.current
        defer { original.set() }
        view.mouseEntered(with: event)
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
        view.cursorUpdate(with: event)
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
        view.mouseExited(with: event)
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
    }

    func testSidebarResizeTargetIsAboveHostingAtThePhysicalEdge() throws {
        let suite = "SidebarHitTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.linkLibrary.setEnabled(true)
        let controller = SidebarWindowController(model: model, reduceMotion: { true })
        defer { controller.hide(animated: false); model.linkLibrary.setEnabled(false) }
        controller.toggle()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.animationBehavior, .none)
        let content = try XCTUnwrap(window.contentView)
        for width in [CGFloat(200), 260, 300] {
            controller.resize(to: width)
            content.layoutSubtreeIfNeeded()
            let point = NSPoint(x: content.bounds.maxX - 1, y: content.bounds.midY)
            let handle = try XCTUnwrap(content.hitTest(point) as? SidebarResizeView)
            XCTAssertTrue(handle.superview === content, "The edge must not be hidden inside a transformed SwiftUI subtree")
            XCTAssertEqual(handle.frame.maxX, content.bounds.maxX)
            XCTAssertFalse(content.hitTest(NSPoint(x: 30, y: content.bounds.midY)) is SidebarResizeView)
            XCTAssertEqual(window.alphaValue, 1)
        }
    }

    func testSidebarWindowRoutesPointerAndResizeEventsToItsNativeEdge() throws {
        let suite = "SidebarEventTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.linkLibrary.setEnabled(true)
        let controller = SidebarWindowController(model: model, reduceMotion: { true })
        defer { controller.hide(animated: false); model.linkLibrary.setEnabled(false) }
        controller.toggle()
        controller.resize(to: 260)
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let originalCursor = NSCursor.current
        defer { originalCursor.set() }
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: window.frame.height / 2),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: 0))
        }
        NSCursor.arrow.set()
        window.sendEvent(try event(.mouseMoved, x: 259))
        XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight, "Real window routing must win over hosting-view cursor processing")
        window.sendEvent(try event(.leftMouseDown, x: 259))
        XCTAssertTrue(controller.isResizing)
        window.sendEvent(try event(.leftMouseDragged, x: 229))
        XCTAssertEqual(window.frame.width, 230, accuracy: 1)
        window.sendEvent(try event(.leftMouseUp, x: 229))
        XCTAssertFalse(controller.isResizing)
        XCTAssertEqual(model.linkLibrary.sidebarWidth, window.frame.width)
    }

    func testSidebarNarrowClosingFramesRemainOpaqueAndPixelAligned() async throws {
        let reveal = SidebarRevealState()
        let hosting = NSHostingView(rootView: SidebarRevealSurface(reveal: reveal) { Color.clear }
            .environment(\.displayScale, 2))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 500)
        reveal.shoulderProgress = 0
        for width in [CGFloat(35.3), 18.2, 8.4, 2.8, 0.1, 0] {
            reveal.progress = width / 300
            try await Task.sleep(for: .milliseconds(30))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / 300
            let alignedWidth = (width * 2).rounded() / 2
            for x in 0..<bitmap.pixelsWide {
                let alpha = bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0
                if CGFloat(x + 1) / scale <= alignedWidth {
                    XCTAssertGreaterThan(alpha, 0.99, "Closing must slide an opaque body rather than fading or blurring it")
                } else if CGFloat(x) / scale >= alignedWidth {
                    XCTAssertLessThan(alpha, 0.01)
                }
            }
        }
    }

    func testSidebarSystemSizesUseNativeFontMetrics() {
        var previousFont: CGFloat = 0
        var previousIcon: CGFloat = 0
        for (size, style) in [(SidebarRowSize.small, NSTableView.RowSizeStyle.small), (.medium, .medium), (.large, .large)] {
            let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
            let text = NSTextField(labelWithString: "Finder row")
            cell.addSubview(text); cell.textField = text; cell.rowSizeStyle = style
            cell.layoutSubtreeIfNeeded()
            let metrics = SidebarMetrics(rowSize: size)
            XCTAssertEqual(metrics.labelSize, text.font!.pointSize, "The custom sidebar must use the same font size as native source-list cells")
            XCTAssertGreaterThan(metrics.labelSize, previousFont)
            XCTAssertGreaterThan(metrics.iconSize, previousIcon)
            XCTAssertGreaterThanOrEqual(metrics.rowHeight, metrics.iconSize)
            previousFont = metrics.labelSize; previousIcon = metrics.iconSize
        }
    }

    func testSidebarEnvironmentMatchesSystemPreferenceAndUpdates() async throws {
        var observed: SidebarRowSize?
        let probe = SidebarSizeProbe { observed = $0 }
        let hosting = NSHostingView(rootView: AnyView(probe))
        hosting.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let table = NSTableView()
        table.style = .sourceList
        table.rowSizeStyle = .default
        let expected: SidebarRowSize
        switch table.effectiveRowSizeStyle {
        case .small: expected = .small
        case .large: expected = .large
        default: expected = .medium
        }
        XCTAssertEqual(observed, expected, "The custom hosting surface must receive the same system size as a native sidebar")
        for size in [SidebarRowSize.small, .medium, .large] {
            hosting.rootView = AnyView(probe.environment(\.sidebarRowSize, size))
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(observed, size, "Changes to the system environment must reach custom sidebar rows")
        }
    }

    func testSidebarRevealSurfaceRendersAnchoredShouldersAndClipsContent() async throws {
        let reveal = SidebarRevealState()
        let hosting = NSHostingView(rootView: SidebarRevealSurface(reveal: reveal) {
            Color.white.padding(.vertical, 24)
        })
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 500)
        let canvas = NSImage(size: NSSize(width: 1600, height: 560))
        canvas.lockFocus()
        NSColor.darkGray.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: canvas.size)).fill()
        canvas.unlockFocus()
        for (index, progress) in [CGFloat(0.05), 0.15, 0.4, 0.7, 1].enumerated() {
            reveal.progress = progress
            reveal.shoulderProgress = 1
            try await Task.sleep(for: .milliseconds(30))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
            let shoulder = try XCTUnwrap(bitmap.colorAt(x: 0, y: Int(18 * scale))?.usingColorSpace(.deviceRGB))
            if progress >= 0.15 {
                XCTAssertGreaterThan(shoulder.alphaComponent, 0.8, "Shoulders must meet the stationary edge once they fit beside the right corner")
                XCTAssertLessThan(shoulder.redComponent, 0.05)
            } else {
                XCTAssertLessThan(shoulder.alphaComponent, 0.01, "A shoulder must not detach from a narrow rounded body")
            }
            if progress < 1 {
                let outside = bitmap.colorAt(x: Int((300 * progress + 4) * scale), y: bitmap.pixelsHigh / 2)
                XCTAssertLessThan(outside?.alphaComponent ?? 1, 0.01, "Moving content must not leak past the visible right edge")
            }
            let snapshot = NSImage(size: hosting.bounds.size)
            snapshot.addRepresentation(bitmap)
            canvas.lockFocus()
            snapshot.draw(in: NSRect(x: 10 + CGFloat(index) * 320, y: 30, width: 300, height: 500))
            canvas.unlockFocus()
        }
        // At the end of dismissal the body remains visible after the shoulders are gone.
        reveal.progress = 1 - SidebarWindowController.motionProgress(0.82, opening: false)
        reveal.shoulderProgress = 1 - SidebarWindowController.shoulderMotionProgress(0.82, opening: false)
        try await Task.sleep(for: .milliseconds(30))
        hosting.layoutSubtreeIfNeeded()
        let closing = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: closing)
        let closingScale = CGFloat(closing.pixelsWide) / 300
        XCTAssertLessThan(closing.colorAt(x: 0, y: Int(12 * closingScale))?.alphaComponent ?? 1, 0.01)
        XCTAssertLessThan(closing.colorAt(x: 0, y: Int(488 * closingScale))?.alphaComponent ?? 1, 0.01)
        XCTAssertGreaterThan(closing.colorAt(x: Int(10 * closingScale), y: closing.pixelsHigh / 2)?.alphaComponent ?? 0, 0.99)
        try closing.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-sidebar18-closing.png"))
        let png = try XCTUnwrap(NSBitmapImageRep(data: canvas.tiffRepresentation!)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/linklet-sidebar17-motion.png"))
    }

    func testSidebarShouldersHaveASubtleLeadAndDisappearBeforeTheBody() {
        let early = 0.05
        let earlyBody = SidebarWindowController.motionProgress(early, opening: true)
        let earlyShoulder = SidebarWindowController.shoulderMotionProgress(early, opening: true)
        XCTAssertGreaterThan(earlyShoulder, earlyBody)
        XCTAssertLessThan(earlyShoulder - earlyBody, 0.06, "The shoulder lead must be subtle in the first frames")
        let closing = 0.82
        let body = 1 - SidebarWindowController.motionProgress(closing, opening: false)
        let shoulder = 1 - SidebarWindowController.shoulderMotionProgress(closing, opening: false)
        XCTAssertGreaterThan(body, 0.2, "The panel body must still be visible when the shoulders have gone")
        XCTAssertEqual(shoulder, 0)
        let rect = CGRect(x: 0, y: 0, width: 300, height: 500)
        let path = SidebarContour(revealProgress: body, shoulderProgress: shoulder).path(in: rect)
        XCTAssertFalse(path.contains(CGPoint(x: 0.1, y: 12)))
        XCTAssertFalse(path.contains(CGPoint(x: 0.1, y: 488)))
        XCTAssertTrue(path.contains(CGPoint(x: 10, y: 250)))
        XCTAssertEqual(path.boundingRect.minX, 0)
    }

    func testSidebarInsertionLineIsThinDashedAndCenteredBetweenRows() async throws {
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            Color.clear.frame(height: 26)
            SidebarInsertionGap(height: 20, targeted: true)
            Color.clear.frame(height: 26)
        })
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 240, height: 72)
        try await Task.sleep(for: .milliseconds(30))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        var rows = [Int]()
        for y in 0..<bitmap.pixelsHigh {
            if (0..<bitmap.pixelsWide).contains(where: { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.4 }) {
                rows.append(y)
            }
        }
        XCTAssertFalse(rows.isEmpty)
        let scale = CGFloat(bitmap.pixelsHigh) / 72
        XCTAssertLessThanOrEqual(rows.count, Int(ceil(scale)) + 1, "The old 6 pt solid rectangle must be replaced by a 1 pt stroke")
        let center = Double(rows.reduce(0, +)) / Double(max(1, rows.count))
        XCTAssertEqual(center, Double(bitmap.pixelsHigh - 1) / 2, accuracy: 1, "The line must be halfway between the adjacent rows")
        let row = rows.first ?? bitmap.pixelsHigh / 2
        if let inkX = (0..<bitmap.pixelsWide).first(where: { (bitmap.colorAt(x: $0, y: row)?.alphaComponent ?? 0) > 0.4 }),
           let ink = bitmap.colorAt(x: inkX, y: row)?.usingColorSpace(.deviceRGB) {
            XCTAssertLessThan(ink.redComponent, 0.5, "The insertion line should be subdued gray rather than near-white")
        }
        let solid = (0..<bitmap.pixelsWide).filter { (bitmap.colorAt(x: $0, y: row)?.alphaComponent ?? 0) > 0.4 }.count
        XCTAssertGreaterThan(solid, bitmap.pixelsWide / 3)
        XCTAssertLessThan(solid, bitmap.pixelsWide * 2 / 3, "Perforations need visible gaps, not a continuous bar")
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-sidebar18-insertion.png"))
    }

    func testSidebarMotionRemainsBoundedAndSettlesQuickly() {
        for opening in [true, false] {
            var previous = 0.0
            for step in 0...100 {
                let progress = SidebarWindowController.motionProgress(Double(step) / 100, opening: opening)
                XCTAssertGreaterThanOrEqual(progress, previous)
                XCTAssertLessThanOrEqual(progress, 1)
                previous = progress
            }
            XCTAssertEqual(previous, 1, accuracy: 0.000001)
        }
        // Most of the reveal is already visible after 100 ms, with a short settling tail.
        XCTAssertGreaterThan(SidebarWindowController.motionProgress(0.1 / SidebarWindowController.revealDuration, opening: true), 0.8)
    }

    func testSidebarMotionCanReverseWithoutJumpingOrStaleDismissal() async throws {
        let suite = "SidebarMotion.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.linkLibrary.setEnabled(true)
        let controller = SidebarWindowController(model: model, reduceMotion: { false })
        defer { controller.hide(animated: false); model.linkLibrary.setEnabled(false) }
        let screen = try XCTUnwrap(NSScreen.main)
        let expected = SidebarWindowController.panelFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        controller.toggle()
        let window = try XCTUnwrap(controller.window)
        let initialSize = window.frame.size // AppKit rounds screen geometry to backing pixels.
        try await Task.sleep(for: .milliseconds(100))
        let openingFrame = window.frame
        let openingProgress = controller.reveal.progress
        let openingShoulder = controller.reveal.shoulderProgress
        XCTAssertGreaterThan(openingProgress, 0)
        XCTAssertLessThan(openingProgress, 1)
        XCTAssertEqual(openingFrame.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual(openingFrame.size, initialSize)
        controller.hide()
        XCTAssertFalse(controller.isPresented)
        XCTAssertTrue(window.isVisible, "Closing must slide away rather than instantly disappear")
        XCTAssertTrue(window.ignoresMouseEvents, "A dismissing panel must not intercept clicks meant for the preview")
        XCTAssertEqual(controller.reveal.progress, openingProgress, "Reversing must preserve the visible contour")
        XCTAssertEqual(controller.reveal.shoulderProgress, openingShoulder)
        XCTAssertEqual(window.frame, openingFrame, "The window itself must remain anchored")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertLessThan(controller.reveal.progress, openingProgress)
        let closingProgress = controller.reveal.progress
        let closingShoulder = controller.reveal.shoulderProgress
        let closingFrame = window.frame
        controller.toggle()
        XCTAssertTrue(controller.isPresented)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertEqual(controller.reveal.progress, closingProgress, "Reopening must preserve the visible contour")
        XCTAssertEqual(controller.reveal.shoulderProgress, closingShoulder)
        XCTAssertEqual(window.frame, closingFrame, "Reopening must not move the window away from the edge")
        try await waitForSidebarMotion(controller)
        XCTAssertTrue(window.isVisible, "The canceled dismissal must not order out the reopened window")
        XCTAssertEqual(window.frame.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual(window.frame.size, initialSize)
        XCTAssertEqual(controller.reveal.progress, 1)
        controller.hide()
        try await waitForSidebarMotion(controller)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(controller.reveal.progress, 0)
        controller.toggle()
        model.linkLibrary.setEnabled(false)
        XCTAssertFalse(window.isVisible, "Disabling the feature must stop motion immediately")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(window.isVisible)
    }

    private func waitForSidebarMotion(_ controller: SidebarWindowController) async throws {
        let deadline = Date().addingTimeInterval(2)
        while controller.isAnimating && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(controller.isAnimating, "Window motion must finish even under test-runner load")
    }

    func testSidebarEditingFinishesRevealAndKeepsFrameAnchored() async throws {
        let suite = "SidebarEditingDuringMotion.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.linkLibrary.setEnabled(true)
        let controller = SidebarWindowController(model: model, reduceMotion: { false })
        defer { controller.hide(animated: false); model.linkLibrary.setEnabled(false) }
        controller.toggle()
        try await Task.sleep(for: .milliseconds(70))
        controller.editor.showFolder()
        let window = try XCTUnwrap(controller.window)
        let screen = try XCTUnwrap(window.screen)
        let frame = window.frame
        XCTAssertEqual(frame.minX, screen.frame.minX, accuracy: 0.5)
        XCTAssertFalse(controller.isAnimating)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(window.frame, frame, "An editor opened during the reveal must not continue to move")
        XCTAssertTrue(controller.editor.isEditing)
        XCTAssertNil(window.attachedSheet)
    }

    func testSidebarReducedMotionAvoidsSlidingInBothDirections() throws {
        let suite = "SidebarReducedMotion.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.linkLibrary.setEnabled(true)
        let controller = SidebarWindowController(model: model, reduceMotion: { true })
        defer { controller.hide(animated: false); model.linkLibrary.setEnabled(false) }
        controller.toggle()
        let window = try XCTUnwrap(controller.window)
        let screen = try XCTUnwrap(window.screen)
        XCTAssertEqual(window.frame.minX, screen.frame.minX, accuracy: 0.5)
        controller.hide()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(controller.isPresented)
    }

    func testSidebarWidthPersistsAndResizeNeverExceedsQuarterOfCurrentScreen() async throws {
        let suite = "SidebarWidth.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        let library = model.linkLibrary
        library.setSidebarWidth(500)
        XCTAssertEqual(LinkLibrary(defaults: defaults).sidebarWidth, 500)
        library.setSidebarWidth(.infinity)
        XCTAssertEqual(library.sidebarWidth, 500)
        for screen in [NSRect(x: -1440, y: -900, width: 1440, height: 900),
                       NSRect(x: 0, y: 0, width: 800, height: 600)] {
            let frame = SidebarWindowController.panelFrame(screenFrame: screen, visibleFrame: screen, preferredWidth: 500)
            XCTAssertEqual(frame.width, screen.width / 4)
            XCTAssertEqual(frame.minX, screen.minX)
        }
        library.setEnabled(true)
        let controller = SidebarWindowController(model: model)
        defer { controller.hide(animated: false); library.setEnabled(false) }
        controller.toggle()
        let window = try XCTUnwrap(controller.window)
        // The reveal starts outside the screen; wait until its reveal animation settles.
        try await waitForSidebarMotion(controller)
        let screen = try XCTUnwrap(window.screen)
        XCTAssertLessThanOrEqual(window.frame.width, screen.frame.width / 4)
        let originalFrame = window.frame
        controller.resize(to: 100_000)
        XCTAssertEqual(window.frame.width, screen.frame.width / 4, accuracy: 0.5)
        XCTAssertEqual(window.frame.minX, screen.frame.minX, accuracy: 0.5)
        XCTAssertEqual(window.frame.minY, originalFrame.minY)
        XCTAssertEqual(window.frame.height, originalFrame.height)
        controller.resize(to: 250)
        XCTAssertEqual(window.frame.width, min(250, screen.frame.width / 4), accuracy: 0.5)
    }

    func testInlineEditorsKeepNarrowSidebarAnchoredAndCancelWhenHidden() async throws {
        let suite = "InlineSidebarEditor.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults, fetchIcon: { _ in Data() })
        let model = AppModel(defaults: defaults, searchSettings: settings, discoverTargets: { [] })
        let library = model.linkLibrary
        library.setEnabled(true); library.setSidebarWidth(200)
        let folder = try XCTUnwrap(library.addFolder(name: "Existing folder"))
        let site = try settings.addFavoriteSite(name: "Existing bookmark", address: "https://example.com")
        let controller = SidebarWindowController(model: model)
        defer { controller.hide(animated: false); library.setEnabled(false) }
        controller.toggle()
        try await waitForSidebarMotion(controller)
        let window = try XCTUnwrap(controller.window)
        let originalFrame = window.frame
        let presentations: [() -> Void] = [
            { controller.editor.showFolder(folder) }, { controller.editor.showFolder() },
            { controller.editor.showBookmark(site: site) }, { controller.editor.showBookmark() }
        ]
        for present in presentations {
            present()
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(window.frame, originalFrame, "Inline editing must not resize or move the narrow panel")
            let outside = NSPoint(x: window.frame.maxX + 100, y: window.frame.midY)
            let now = Date().addingTimeInterval(3)
            controller.pollMouse(at: outside, now: now)
            controller.pollMouse(at: outside, now: now.addingTimeInterval(2))
            XCTAssertTrue(window.isVisible, "A draft must stay open while typing or copying a URL")
            controller.editor.cancel()
            XCTAssertFalse(controller.editor.isEditing)
            XCTAssertEqual(window.frame, originalFrame)
        }
        controller.editor.showFolder(folder)
        controller.hide()
        XCTAssertFalse(controller.editor.isEditing)
        XCTAssertEqual(library.folders.first?.name, "Existing folder")
        XCTAssertEqual(settings.favoriteSites.first?.name, "Existing bookmark")
    }

    func testSidebarMarginsUseScreenWidthIncludingNegativeOrigins() {
        let screen = NSRect(x: -1440, y: -900, width: 1440, height: 900)
        let visible = NSRect(x: -1440, y: -875, width: 1440, height: 875)
        let frame = SidebarWindowController.panelFrame(screenFrame: screen, visibleFrame: visible)
        XCTAssertEqual(frame.minX, screen.minX)
        XCTAssertEqual(frame.minY - screen.minY, 144)
        XCTAssertEqual(screen.maxY - frame.maxY, 144)
        XCTAssertEqual(frame.size, NSSize(width: 300, height: 612))
        XCTAssertTrue(visible.contains(frame))
        let small = NSRect(x: 0, y: 0, width: 3000, height: 500)
        XCTAssertEqual(SidebarWindowController.panelFrame(screenFrame: small, visibleFrame: small).height, 300)
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
        let settings = SearchSettings(defaults: defaults, fetchIcon: { _ in
            // A deterministic favicon fixture keeps this screenshot independent of internet access.
            let image = NSImage(size: NSSize(width: 32, height: 32))
            image.lockFocus()
            NSColor.systemOrange.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 32, height: 32), xRadius: 6, yRadius: 6).fill()
            ("S" as NSString).draw(at: NSPoint(x: 8, y: 4), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 23), .foregroundColor: NSColor.black])
            image.unlockFocus()
            return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        })
        let model = AppModel(defaults: defaults, searchSettings: settings, discoverTargets: { [] })
        model.linkLibrary.setEnabled(true)
        let reference = try model.searchSettings.addFavoriteSite(name: "Swift Documentation", address: "swift.org/documentation")
        _ = try model.searchSettings.addFavoriteSite(name: "Apple Developer", address: "developer.apple.com")
        let folder = try XCTUnwrap(model.linkLibrary.addFolder(name: "Work"))
        model.linkLibrary.moveBookmark(reference, to: folder.id)
        for index in 1...25 {
            let url = URL(string: "https://example.com/article/\(index)")!
            model.linkLibrary.recordOpening(url)
            model.linkLibrary.updateTitle("Article \(index)", for: url)
        }
        let controller = SidebarWindowController(model: model)
        defer { controller.hide(animated: false); model.linkLibrary.setEnabled(false) }
        controller.toggle()
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(model.previewSession.isActive)
        XCTAssertEqual(window.level, .floating)
        try await waitForSidebarMotion(controller)
        let screen = try XCTUnwrap(window.screen)
        let expected = SidebarWindowController.panelFrame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        XCTAssertEqual(window.frame.width, expected.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, expected.height, accuracy: 1) // AppKit aligns the animated frame to pixels.
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertEqual(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 2)?.alphaComponent ?? 1, 0, accuracy: 0.01)
            let interior = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 12, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(interior.redComponent, 0, accuracy: 0.01)
            XCTAssertEqual(interior.greenComponent, 0, accuracy: 0.01)
            XCTAssertEqual(interior.blueComponent, 0, accuracy: 0.01)
            let canvas = NSImage(size: NSSize(width: view.bounds.width + 80, height: view.bounds.height + 80))
            canvas.lockFocus()
            NSColor.darkGray.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: canvas.size)).fill()
            let snapshot = NSImage(size: view.bounds.size)
            snapshot.addRepresentation(bitmap)
            snapshot.draw(in: NSRect(x: 40, y: 40, width: view.bounds.width, height: view.bounds.height))
            canvas.unlockFocus()
            try NSBitmapImageRep(data: canvas.tiffRepresentation!)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-1.5-sidebar.png"))
        }
        controller.toggle()
        XCTAssertFalse(controller.isPresented)
        try await waitForSidebarMotion(controller)
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
        defer { session.windowRegistry.closeAll(); session.endSession() }
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
        XCTAssertEqual(coordinator.popupWindows.count, 1, "Replacing the opener must leave its independent window alive")
        XCTAssertTrue(coordinator.popupWindows.values.first?.session.isActive == true)
        XCTAssertNil(session.webView)
    }

    func testTargetBlankLinkCreatesIndependentWindowAndPreservesSource() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let session = PreviewSession()
        let original = URL(string: "http://127.0.0.1:\(port)/site")!
        session.load(original)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                             configuration: WebPreview.configuration(websiteDataStore: session.websiteDataStore))
        let coordinator = WebPreview.Coordinator(session: session)
        view.uiDelegate = coordinator
        view.navigationDelegate = coordinator
        coordinator.startObserving(view)
        session.attach(view)
        defer { session.windowRegistry.closeAll(); session.endSession() }
        try await waitUntil { (try? await view.evaluateJavaScript("window.result")) as? String == "pending" }
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "fixture", .value: "keep-session"])!
        await view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        _ = try await view.evaluateJavaScript("const link=document.createElement('a');link.href='/destination';link.target='_blank';document.body.append(link);link.click();true")
        try await waitUntil { coordinator.popupWindows.values.first?.session.pageTitle == "Destination" }
        let popup = try XCTUnwrap(coordinator.popupWindows.values.first)
        XCTAssertNil(popup.window?.parent)
        XCTAssertTrue(session.webView === view)
        XCTAssertEqual(view.url, original)
        XCTAssertEqual(view.title, "Original site")
        XCTAssertEqual(session.originalURL, original)
        XCTAssertFalse(view.canGoBack)
        XCTAssertTrue(popup.webView.configuration.websiteDataStore === view.configuration.websiteDataStore)
        let cookies = await popup.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == "fixture" && $0.value == "keep-session" })
        popup.close()
        XCTAssertEqual(view.url, original)
        XCTAssertEqual(view.title, "Original site")
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
        defer { session.windowRegistry.closeAll(); session.endSession() }
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
        defer { session.windowRegistry.closeAll(); session.endSession() }
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
        XCTAssertTrue(window.contentViewController is NSHostingController<PreviewPageView>)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        let webRect = popup.webView.convert(popup.webView.bounds, to: content)
        XCTAssertTrue(content.bounds.contains(webRect))
        let topInset = content.isFlipped ? webRect.minY - content.bounds.minY : content.bounds.maxY - webRect.maxY
        XCTAssertEqual(topInset, PreviewLayout.topBarHeight, accuracy: 2)
        let viewport = try await popup.webView.evaluateJavaScript("[innerWidth, innerHeight]") as? [Int]
        XCTAssertGreaterThan(viewport?.first ?? 0, 300)
        XCTAssertGreaterThan(viewport?.last ?? 0, 300)
        let address = try addressControl(in: window)
        let frameBeforeExpansion = window.frame
        // performClick bypasses AppKit's normal activation on a user's click.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        address.addressButton.performClick(nil)
        try await waitUntil { address.isExpanded && address.addressField.currentEditor() != nil }
        XCTAssertEqual(address.addressField.stringValue, longURL)
        XCTAssertEqual(window.frame, frameBeforeExpansion, "Long OAuth URLs must not resize the window")
        try sendAddressKey(to: window, code: 53, characters: "\u{1b}")
        try await waitUntil { !address.isExpanded }
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-popup-layout.png"))
        }
        window.setContentSize(NSSize(width: 640, height: 500))
        content.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(window.frame.width, 640)
        XCTAssertTrue(content.bounds.contains(popup.webView.convert(popup.webView.bounds, to: content)))
        XCTAssertGreaterThan(popup.webView.visibleRect.height, 300)
    }

    func testAddressDisclosurePreservesPageAndGeometryInMainAndSiteWindows() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "AddressDisclosureTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "keepsPreviewVisibleWhenInactive")
        let target = BrowserTarget.browser(name: "Safari", applicationURL: URL(fileURLWithPath: "/Applications/Safari.app"))
        let model = AppModel(defaults: defaults, discoverTargets: { [target] })
        model.refreshTargets()
        model.siteData.selectModeForPreview(false)
        defer { model.closeAllWindows(); defaults.removePersistentDomain(forName: suite) }
        let sourceURL = URL(string: "http://127.0.0.1:\(port)/site")!
        model.showPreview(url: sourceURL)
        try await waitUntil { model.previewSession.pageTitle == "Original site" }
        let sourceWindow = try XCTUnwrap(NSApp.windows.first { window in
            (window.contentViewController as? NSHostingController<PreviewRootView>)?.rootView.session === model.previewSession
        })
        let source = try XCTUnwrap(model.previewSession.webView)
        _ = try await source.evaluateJavaScript("window.open('/destination','address-test');true")
        try await waitUntil { model.windowRegistry.windows.count == 2 && model.windowRegistry.windows.last?.title == "Destination" }
        let popup = try XCTUnwrap(model.windowRegistry.webWindows(openedBy: model.previewSession.windowID).values.first)
        let siteWindow = try XCTUnwrap(popup.window)

        for (window, session, screenshotName) in [(sourceWindow, model.previewSession, "main"), (siteWindow, popup.session, "site")] {
            window.makeKeyAndOrderFront(nil)
            window.setContentSize(NSSize(width: 640, height: 500))
            window.contentView?.layoutSubtreeIfNeeded()
            let address = try addressControl(in: window)
            let page = try XCTUnwrap(session.webView)
            let url = try XCTUnwrap(session.currentURL)
            let navigationID = session.navigationID
            let frame = window.frame
            let pageFrame = page.frame
            XCTAssertEqual(address.addressButton.title, "http://127.0.0.1:\(port)")
            XCTAssertFalse(address.isExpanded)
            XCTAssertLessThanOrEqual(address.frame.width, 180)
            _ = try await page.evaluateJavaScript("window.addressSentinel='kept';true")
            address.addressButton.performClick(nil)
            try await waitUntil { address.isExpanded && address.addressField.currentEditor() != nil }
            window.contentView?.layoutSubtreeIfNeeded()
            let editor = try XCTUnwrap(address.addressField.currentEditor())
            XCTAssertEqual(editor.string, url.absoluteString)
            XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: url.absoluteString.utf16.count))
            XCTAssertTrue(address.addressField.isEditable)
            XCTAssertEqual(window.frame, frame)
            XCTAssertEqual(page.frame, pageFrame)
            XCTAssertEqual(session.navigationID, navigationID)
            XCTAssertTrue(session.webView === page)
            let kept = try await page.evaluateJavaScript("window.addressSentinel") as? String
            XCTAssertEqual(kept, "kept")
            let editingView = try XCTUnwrap(editor as? NSTextView)
            editingView.insertText("unfinished draft", replacementRange: editingView.selectedRange())
            _ = try await page.evaluateJavaScript("history.replaceState(null,'','#address-test');true")
            let changedURL = try XCTUnwrap(URL(string: url.absoluteString + "#address-test"))
            try await waitUntil { session.currentURL == changedURL }
            // Allow SwiftUI's URL update to reach the native field too.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(editingView.string, "unfinished draft", "A live URL update must not overwrite the draft")
            try sendAddressKey(to: window, code: 53, characters: "\u{1b}")
            try await waitUntil { !address.isExpanded }
            XCTAssertTrue(window.isVisible, "Escape collapses the address instead of closing the page")
            try await waitUntil { address.addressField.stringValue == changedURL.absoluteString }
            try sendAddressKey(to: window, code: 37, characters: "д", modifiers: .command)
            try await waitUntil { address.isExpanded && address.addressField.currentEditor() != nil }
            let targetPath = url.path == "/site" ? "/destination" : "/site"
            let destination = URL(string: "http://127.0.0.1:\(port)" + targetPath)!
            let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "address-login", .value: "kept"])!
            await page.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            let input = try XCTUnwrap(address.addressField.currentEditor() as? NSTextView)
            input.insertText(destination.absoluteString, replacementRange: input.selectedRange())
            try sendAddressKey(to: window, code: 36, characters: "\r")
            try await waitUntil { !address.isExpanded && session.currentURL == destination && !session.isLoading }
            XCTAssertTrue(session.webView === page)
            XCTAssertEqual(session.navigationID, navigationID)
            XCTAssertEqual(session.originalURL, sourceURL)
            XCTAssertTrue(session.canGoBack, "Address entry must retain back/forward history")
            let cookies = await page.configuration.websiteDataStore.httpCookieStore.allCookies()
            XCTAssertTrue(cookies.contains { $0.name == "address-login" && $0.value == "kept" })
            session.goBack()
            try await waitUntil { session.currentURL == changedURL && !session.isLoading }
            try sendAddressKey(to: window, code: 37, characters: "l", modifiers: .command)
            try await waitUntil { address.isExpanded && address.addressField.currentEditor() != nil }
            let other = window === sourceWindow ? siteWindow : sourceWindow
            other.makeKeyAndOrderFront(nil)
            try await waitUntil { !address.isExpanded }
            window.contentView?.layoutSubtreeIfNeeded()
            if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-address-\(screenshotName).png"))
            }
        }
    }

    func testAddressLabelRetainsAuthenticationHostPortAndHTTPSFormatting() throws {
        for (input, expected) in [
            ("https://www.example.com/path?q=one", "example.com"),
            ("https://accounts.google.com/signin", "accounts.google.com"),
            ("https://example.com:8443/path", "example.com:8443"),
            ("http://localhost:8080/path", "http://localhost:8080"),
            ("http://[::1]:8080/path", "http://[::1]:8080"),
            ("about:blank", "about:blank")
        ] {
            XCTAssertEqual(PreviewAddressControlView.compactAddress(for: try XCTUnwrap(URL(string: input))), expected)
        }
    }

    func testAddressSearchUsesTheCurrentlySelectedEngineWithoutSendingATestRequest() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "AddressSearchTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "keepsPreviewVisibleWhenInactive")
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.siteData.selectModeForPreview(false)
        defer { model.closeAllWindows(); defaults.removePersistentDomain(forName: suite) }
        let original = URL(string: "http://127.0.0.1:\(port)/site")!
        model.showPreview(url: original)
        try await waitUntil { model.previewSession.pageTitle == "Original site" }
        let window = try XCTUnwrap(NSApp.windows.first { window in
            (window.contentViewController as? NSHostingController<PreviewRootView>)?.rootView.session === model.previewSession
        })
        let page = try XCTUnwrap(model.previewSession.webView)
        let capture = AddressNavigationCapture()
        page.navigationDelegate = capture
        let address = try addressControl(in: window)
        address.addressButton.performClick(nil)
        try await waitUntil { address.addressField.currentEditor() != nil }
        let editor = try XCTUnwrap(address.addressField.currentEditor() as? NSTextView)
        let query = "A+B & тест"
        editor.insertText(query, replacementRange: editor.selectedRange())
        // Select after the field has opened to verify this reads live settings.
        model.searchSettings.setEngine(.bing)
        try sendAddressKey(to: window, code: 36, characters: "\r")
        try await waitUntil { capture.urls.count == 1 }
        XCTAssertEqual(capture.urls, [SearchEngine.bing.searchURL(for: query)])
        XCTAssertFalse(address.isExpanded)
        XCTAssertTrue(model.previewSession.webView === page)
        XCTAssertEqual(model.previewSession.originalURL, original)
        XCTAssertFalse(model.previewSession.submitAddress("  \n  ", engine: .bing))
    }

    func testLatestAddressWinsWhileLocalAdBlockRulesArePreparing() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "AddressPreparationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: AdBlockService.enabledKey)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let blocker = AdBlockService(defaults: defaults, cacheDirectory: cache, automaticUpdates: false)
        let data = SiteDataService(defaults: defaults, persistentStore: .nonPersistent())
        let session = PreviewSession(adBlockService: blocker, siteData: data)
        defer {
            session.endSession()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: cache)
        }
        let original = URL(string: "http://127.0.0.1:\(port)/site")!
        let destination = URL(string: "http://127.0.0.1:\(port)/destination")!
        var recordedTitles = 0
        session.onPageFinished = { _, _ in recordedTitles += 1 }
        session.load(original)
        let page = WKWebView(frame: .zero, configuration: WebPreview.configuration(websiteDataStore: session.websiteDataStore))
        let coordinator = WebPreview.Coordinator(session: session)
        page.uiDelegate = coordinator
        page.navigationDelegate = coordinator
        coordinator.startObserving(page)
        session.attach(page)
        let navigationID = session.navigationID
        // Even a repeated URL must supersede earlier pending requests to it.
        XCTAssertTrue(session.submitAddress(destination.absoluteString, engine: .google))
        XCTAssertTrue(session.submitAddress(original.absoluteString, engine: .google))
        XCTAssertTrue(session.submitAddress(destination.absoluteString, engine: .google))
        try await waitUntil { session.pageTitle == "Destination" && !session.isLoading }
        XCTAssertFalse(server.pageRequests.contains { $0.hasPrefix("GET /site ") })
        XCTAssertEqual(server.pageRequests.filter { $0.hasPrefix("GET /destination ") }.count, 1)
        XCTAssertTrue(session.webView === page)
        XCTAssertEqual(session.navigationID, navigationID)
        XCTAssertEqual(session.originalURL, original)
        XCTAssertEqual(recordedTitles, 0, "The skipped incoming page must not be renamed after the new address")
    }

    func testSharedChromeRegistersNestedWindowsAndActivatesWithoutReloading() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "UnifiedWindowTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "keepsPreviewVisibleWhenInactive")
        let target = BrowserTarget.browser(name: "Safari", applicationURL: URL(fileURLWithPath: "/Applications/Safari.app"))
        let model = AppModel(defaults: defaults, discoverTargets: { [target] })
        model.refreshTargets()
        model.siteData.selectModeForPreview(false)
        defer { model.closeAllWindows(); defaults.removePersistentDomain(forName: suite) }
        let url = URL(string: "http://127.0.0.1:\(port)/site")!
        model.showPreview(url: url)
        let parentWindow = try XCTUnwrap(NSApp.windows.first { window in
            (window.contentViewController as? NSHostingController<PreviewRootView>)?.rootView.session === model.previewSession
        })
        try await waitUntil { model.previewSession.pageTitle == "Original site" }
        let parent = try XCTUnwrap(model.previewSession.webView)
        XCTAssertEqual(model.previewSession.pageTitle, "Original site", "WebKit URL: \(String(describing: parent.url)), session URL: \(String(describing: model.previewSession.currentURL)), error: \(String(describing: model.previewSession.errorMessage))")
        let registry = model.windowRegistry
        XCTAssertEqual(registry.windows.map(\.id), [model.previewSession.windowID])
        _ = try await parent.evaluateJavaScript("window.child=window.open('/destination','child','width=650,height=500');true")
        try await waitUntil { registry.windows.count == 2 && registry.windows.last?.title == "Destination" }
        let childID = try XCTUnwrap(registry.windows.last?.id)
        XCTAssertEqual(registry.windows.last?.parentID, model.previewSession.windowID)
        let childWindow = try XCTUnwrap(NSApp.windows.first { window in
            (window.contentViewController as? NSHostingController<PreviewRootView>)?.rootView.session.windowID == childID
        })
        XCTAssertNil(childWindow.parent)
        XCTAssertTrue(parentWindow.childWindows?.isEmpty ?? true)
        let initialChildFrame = childWindow.frame
        parentWindow.setFrameOrigin(NSPoint(x: parentWindow.frame.minX + 30, y: parentWindow.frame.minY + 20))
        XCTAssertEqual(childWindow.frame, initialChildFrame, "Moving the source must not drag the new window")
        let movedParentFrame = parentWindow.frame
        childWindow.setFrameOrigin(NSPoint(x: childWindow.frame.minX - 25, y: childWindow.frame.minY - 15))
        XCTAssertEqual(parentWindow.frame, movedParentFrame, "Moving the new window must not affect its source")
        let childHost = try XCTUnwrap(childWindow.contentViewController as? NSHostingController<PreviewRootView>)
        let childSession = childHost.rootView.session
        let child = try XCTUnwrap(childSession.webView)
        XCTAssertTrue(childHost.rootView.model === model)
        XCTAssertEqual(childWindow.titleVisibility, parentWindow.titleVisibility)
        XCTAssertEqual(childWindow.minSize, parentWindow.minSize)
        XCTAssertTrue(child.configuration.websiteDataStore === parent.configuration.websiteDataStore)
        XCTAssertEqual(childSession.originalURL, url)
        _ = try await child.evaluateJavaScript("window.sentinel='preserved';document.title='Child changed';window.open('about:blank','nested');true")
        try await waitUntil { registry.windows.count == 3 && registry.windows.contains { $0.title == "Child changed" } }
        let nested = try XCTUnwrap(registry.windows.last)
        XCTAssertEqual(nested.parentID, childID)
        registry.activate(model.previewSession.windowID)
        registry.activate(childID)
        let sentinel = try await child.evaluateJavaScript("window.sentinel") as? String
        XCTAssertEqual(sentinel, "preserved")
        XCTAssertTrue(childSession.webView === child)
        XCTAssertEqual(registry.windows.map(\.id), [model.previewSession.windowID, childID, nested.id])

        if let content = childWindow.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-unified-popup.png"))
        }
        let nestedController = try XCTUnwrap(registry.webWindows(openedBy: childID)[nested.id])
        _ = try await nestedController.webView.evaluateJavaScript("window.sentinel='survives-close';true")
        registry.close(childID)
        try await waitUntil { registry.windows.map(\.id) == [model.previewSession.windowID, nested.id] }
        XCTAssertTrue(parent.configuration.websiteDataStore === model.previewSession.websiteDataStore)
        XCTAssertEqual(model.previewSession.pageTitle, "Original site")
        parentWindow.close()
        try await waitUntil { registry.windows.map(\.id) == [nested.id] }
        XCTAssertTrue(model.hasOpenWindows, "The app must retain its independent windows after the source closes")
        registry.activate(nested.id)
        let keptValue = try await nestedController.webView.evaluateJavaScript("window.sentinel") as? String
        XCTAssertEqual(keptValue, "survives-close")
        _ = try await nestedController.webView.evaluateJavaScript("window.close();true")
        try await waitUntil { registry.windows.isEmpty }
        XCTAssertFalse(model.hasOpenWindows)
    }

    func testSidebarOpenWindowsTracksLivePagesAndActivatesWithoutReloading() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "SidebarOpenWindows.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "keepsPreviewVisibleWhenInactive")
        let settings = SearchSettings(defaults: defaults, fetchIcon: { _ in throw FavoriteSiteIconError.unavailable })
        let model = AppModel(defaults: defaults, searchSettings: settings, discoverTargets: { [] })
        model.siteData.selectModeForPreview(false)
        model.linkLibrary.setEnabled(true)
        let sidebar = SidebarWindowController(model: model, reduceMotion: { true })
        defer {
            sidebar.hide(animated: false)
            model.closeAllWindows()
            model.linkLibrary.setEnabled(false)
            defaults.removePersistentDomain(forName: suite)
        }
        let source = URL(string: "http://127.0.0.1:\(port)/site")!
        model.showPreview(url: source)
        try await waitUntil { model.previewSession.pageTitle == "Original site" }
        let page = try XCTUnwrap(model.previewSession.webView)
        _ = try await page.evaluateJavaScript("window.open('/destination','sidebar-child');true")
        try await waitUntil { model.windowRegistry.windows.count == 2 && model.windowRegistry.windows.last?.title == "Destination" }
        let popup = try XCTUnwrap(model.windowRegistry.webWindows(openedBy: model.previewSession.windowID).values.first)
        let popupWindow = try XCTUnwrap(popup.window)
        _ = try await popup.webView.evaluateJavaScript("window.sidebarSentinel='kept';document.title='Changed window';true")
        try await waitUntil { model.windowRegistry.windows.last?.title == "Changed window" }
        // Production chrome hides native buttons; enable miniaturization in this fixture.
        popupWindow.styleMask.insert(.miniaturizable)
        popupWindow.miniaturize(nil)
        try await waitUntil { model.windowRegistry.windows.last?.isMiniaturized == true }
        sidebar.toggle()
        let content = try XCTUnwrap(sidebar.window?.contentView)
        let sourceID = "sidebar-window-\(model.previewSession.windowID.uuidString)"
        let popupID = "sidebar-window-\(popup.session.windowID.uuidString)"
        try await waitUntil { self.accessibilityNode(in: content, identifier: popupID) != nil }
        XCTAssertNotNil(accessibilityNode(in: content, identifier: sourceID))
        let row = try XCTUnwrap(accessibilityNode(in: content, identifier: popupID))
        let before = server.pageRequests
        XCTAssertEqual(row.value(forKey: "accessibilityPerformPress") as? Bool, true)
        try await waitUntil { !sidebar.isPresented && !popupWindow.isMiniaturized && popupWindow.isKeyWindow }
        let sentinel = try await popup.webView.evaluateJavaScript("window.sidebarSentinel") as? String
        XCTAssertEqual(sentinel, "kept")
        XCTAssertEqual(server.pageRequests, before, "Selecting a live window must not issue a new page request")

        sidebar.toggle()
        try await waitUntil { self.accessibilityNode(in: content, identifier: popupID) != nil }
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-open-windows-sidebar.png"))
        }
        let section = try XCTUnwrap(accessibilityNode(in: content, identifier: "sidebar-section-open"))
        XCTAssertEqual(section.value(forKey: "accessibilityPerformPress") as? Bool, true)
        try await waitUntil { self.accessibilityNode(in: content, identifier: popupID) == nil }
        XCTAssertFalse(model.linkLibrary.expandedSections.contains(.open))
        XCTAssertEqual(section.value(forKey: "accessibilityPerformPress") as? Bool, true)
        try await waitUntil { self.accessibilityNode(in: content, identifier: popupID) != nil }
        // Site-controlled window.close must remove the visible row immediately.
        _ = try await popup.webView.evaluateJavaScript("window.close();true")
        try await waitUntil { self.accessibilityNode(in: content, identifier: popupID) == nil }
        XCTAssertNotNil(accessibilityNode(in: content, identifier: sourceID))
        model.windowRegistry.close(model.previewSession.windowID)
        try await waitUntil { self.accessibilityNode(in: content, identifier: "sidebar-open-empty") != nil }
        XCTAssertNil(accessibilityNode(in: content, identifier: sourceID))
        XCTAssertNil(defaults.data(forKey: "recentLinks"))
        XCTAssertTrue(LinkLibrary(defaults: defaults).recentLinks.isEmpty)
    }

    private func accessibilityNode(in value: Any, identifier: String) -> NSObject? {
        guard let element = value as? NSObject else { return nil }
        // SwiftUI AX elements expose these selectors without adopting the full
        // NSAccessibility protocol. KVC also bridges the Boolean Press action.
        if element.responds(to: NSSelectorFromString("accessibilityIdentifier")),
           element.value(forKey: "accessibilityIdentifier") as? String == identifier { return element }
        let children = element.responds(to: NSSelectorFromString("accessibilityChildren"))
            ? element.value(forKey: "accessibilityChildren") as? [Any] ?? [] : []
        for child in children {
            if let match = accessibilityNode(in: child, identifier: identifier) { return match }
        }
        // AppKit containers ignored by AX may not expose their hosting view as an AX child.
        if let view = value as? NSView {
            for child in view.subviews {
                if let match = accessibilityNode(in: child, identifier: identifier) { return match }
            }
        }
        return nil
    }

    func testRegistryDistinguishesDuplicateAddressesAndRestoresMinimizedWindow() async throws {
        let registry = BrowserWindowRegistry()
        let blocker = AdBlockService(automaticUpdates: false)
        let first = PreviewSession(adBlockService: blocker, windowRegistry: registry)
        let second = PreviewSession(adBlockService: blocker, windowRegistry: registry)
        let url = URL(string: "https://example.com/same")!
        first.load(url); second.load(url)
        let one = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                           styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        let two = NSWindow(contentRect: one.frame, styleMask: one.styleMask, backing: .buffered, defer: false)
        one.isReleasedWhenClosed = false; two.isReleasedWhenClosed = false
        defer { one.close(); two.close(); first.endSession(); second.endSession() }
        one.makeKeyAndOrderFront(nil); two.makeKeyAndOrderFront(nil)
        registry.register(one, session: first)
        registry.register(two, session: second)
        registry.register(one, session: first)
        XCTAssertEqual(registry.windows.map(\.id), [first.windowID, second.windowID])
        XCTAssertEqual(registry.windows.map(\.url), [url, url])
        two.miniaturize(nil)
        try await waitUntil { registry.windows.last?.isMiniaturized == true }
        registry.activate(second.windowID)
        try await waitUntil { !two.isMiniaturized && registry.windows.last?.isKey == true }
        registry.close(first.windowID)
        XCTAssertEqual(registry.windows.map(\.id), [second.windowID])
        // Unknown and previously closed IDs are harmless.
        registry.activate(first.windowID)
        registry.close(UUID())
    }

    func testIncomingWindowsShareRegistryAndClosingOnePreservesTheOther() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "IncomingWindowRegistryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "keepsPreviewVisibleWhenInactive")
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.siteData.selectModeForPreview(false)
        model.setOpensLinksInNewWindows(true)
        defer { model.closeAllWindows(); defaults.removePersistentDomain(forName: suite) }
        let url = URL(string: "http://127.0.0.1:\(port)/site")!
        model.showPreview(url: url)
        try await waitUntil { model.windowRegistry.windows.first?.title == "Original site" }
        let originalView = try XCTUnwrap(model.previewSession.webView)
        model.showPreview(url: url)
        try await waitUntil { model.windowRegistry.windows.count == 2 && model.windowRegistry.windows.last?.title == "Original site" }
        XCTAssertEqual(model.windowRegistry.windows.map(\.url), [url, url])
        XCTAssertNotEqual(model.windowRegistry.windows.first?.id, model.windowRegistry.windows.last?.id)
        XCTAssertTrue(model.windowRegistry.windows.allSatisfy { $0.parentID == nil })
        model.windowRegistry.close(try XCTUnwrap(model.windowRegistry.windows.last?.id))
        XCTAssertEqual(model.windowRegistry.windows.map(\.id), [model.previewSession.windowID])
        XCTAssertTrue(model.previewSession.webView === originalView)
        XCTAssertEqual(model.previewSession.pageTitle, "Original site")
        model.closeAllWindows()
        XCTAssertTrue(model.windowRegistry.windows.isEmpty)
    }

    func testRegistryExcludesWelcomeAndDropsReleasedEntries() throws {
        let registry = BrowserWindowRegistry()
        let session = PreviewSession(adBlockService: AdBlockService(automaticUpdates: false), windowRegistry: registry)
        session.showWelcome(isDefault: false)
        var window: NSWindow? = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window?.isReleasedWhenClosed = false
        registry.register(try XCTUnwrap(window), session: session)
        XCTAssertTrue(registry.windows.isEmpty)
        session.load(URL(string: "https://example.com")!)
        registry.refresh()
        XCTAssertEqual(registry.windows.count, 1)
        window?.close()
        window = nil
        registry.refresh()
        XCTAssertTrue(registry.windows.isEmpty)
        session.endSession()
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

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("WebKit fixture did not complete within 10 seconds", file: file, line: line)
    }

    private func addressControl(in window: NSWindow) throws -> PreviewAddressControlView {
        func find(_ view: NSView) -> PreviewAddressControlView? {
            if let address = view as? PreviewAddressControlView { return address }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(window.contentView.flatMap(find))
    }

    private func sendAddressKey(to window: NSWindow, code: UInt16, characters: String,
                                modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.postEvent(event, atStart: true)
        if let next = NSApp.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) {
            NSApp.sendEvent(next)
        }
    }
}

/// Cancel before WebKit contacts the search provider; only inspect the intended URL.
@MainActor
private final class AddressNavigationCapture: NSObject, WKNavigationDelegate {
    var urls: [URL] = []
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url { urls.append(url) }
        decisionHandler(.cancel)
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
    private var receivedPageRequests: [String] = []
    var pageRequests: [String] { lock.lock(); defer { lock.unlock() }; return receivedPageRequests }
    private var iconData: Data?
    private let conventionalIcon: Data?
    private var iconVersion = 1
    private var responsesNotModified = 0
    private var iconDownloads = 0
    var notModifiedCount: Int { lock.lock(); defer { lock.unlock() }; return responsesNotModified }
    var downloadedIconCount: Int { lock.lock(); defer { lock.unlock() }; return iconDownloads }
    func updateIcon(_ data: Data) { lock.lock(); defer { lock.unlock() }; iconData = data; iconVersion += 1 }
    private var receivedIconRequests: [String] = []
    var iconRequests: [String] { lock.lock(); defer { lock.unlock() }; return receivedIconRequests }
    var postCount: Int { lock.lock(); defer { lock.unlock() }; return receivedPosts }
    var postBody: String { lock.lock(); defer { lock.unlock() }; return receivedBody }

    init(iconData: Data? = nil, conventionalIcon: Data? = nil) throws {
        self.iconData = iconData
        self.conventionalIcon = conventionalIcon
        listener = try NWListener(using: .tcp, on: .any)
    }

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
        lock.lock()
        receivedPageRequests.append(firstLine)
        let currentIcon = iconData
        let currentVersion = iconVersion
        lock.unlock()
        if let currentIcon {
            let isIcon = firstLine.hasPrefix("GET /custom-icon.png ")
            let isConventional = firstLine.hasPrefix("GET /favicon.ico ")
            let payload = isIcon ? currentIcon : (isConventional && conventionalIcon != nil ? conventionalIcon! : Data("<link href='/custom-icon.png' rel='icon' sizes='256x256'>".utf8))
            let available = !isConventional || conventionalIcon != nil
            let etag = isIcon ? "\"icon-\(currentVersion)\"" : (isConventional ? "\"conventional-v1\"" : "\"html-v1\"")
            let unchanged = available && headers.contains("If-None-Match: \(etag)")
            lock.lock()
            receivedIconRequests.append(firstLine)
            if unchanged { responsesNotModified += 1 }
            if isIcon && !unchanged { iconDownloads += 1 }
            lock.unlock()
            let status = unchanged ? "304 Not Modified" : (available ? "200 OK" : "404 Not Found")
            let body = unchanged ? Data() : payload
            let contentType = isIcon || (isConventional && available) ? "image/png" : "text/html"
            var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nETag: \(etag)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let status: String
        var extraHeaders = ""
        let html: String
        if firstLine.hasPrefix("POST /authorize ") {
            lock.lock(); receivedPosts += 1; receivedBody = body; lock.unlock()
            status = "302 Found"
            extraHeaders = "Location: http://localhost:\(port)/callback\r\nSet-Cookie: login=fixture; Path=/; SameSite=Lax\r\n"
            html = ""
        } else if firstLine.hasPrefix("GET /destination ") {
            status = "200 OK"
            html = "<title>Destination</title><h1>Ordinary destination</h1>"
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

private struct SidebarSizeProbe: NSViewRepresentable {
    @Environment(\.sidebarRowSize) private var rowSize
    let report: (SidebarRowSize) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { report(rowSize) }
}

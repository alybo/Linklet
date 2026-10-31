import XCTest
import WebKit
import SwiftUI
import Network
import Carbon
import ImageIO
import ObjectiveC
import Darwin
import CoreLocation
@testable import Linklet

@MainActor
final class LinkLibraryTests: XCTestCase {
    func testHistoryIsOptInBoundedAndIndependentOfSidebar() throws {
        let suite = "LinkLibraryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LinkLibrary(defaults: defaults)
        let url = URL(string: "https://example.com/original")!
        XCTAssertFalse(library.isEnabled)
        XCTAssertFalse(library.savesHistory)
        library.recordOpening(url)
        XCTAssertEqual(library.recentLinks.count, 1, "History does not depend on sidebar visibility")
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

    func testHistoryMigratesPositionsAndDoesNotUndoClearOrOptOut() async throws {
        let suite = "HistoryPositions.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(string: "https://example.com/article")!
        defaults.set(true, forKey: "sidebarSavesHistory")
        defaults.set(try JSONSerialization.data(withJSONObject: [["id": UUID().uuidString,
            "address": url.absoluteString, "title": "Old history", "openedAt": 0]]), forKey: "recentLinks")
        let library = LinkLibrary(defaults: defaults)
        XCTAssertEqual(library.recentLinks.first?.title, "Old history")
        XCTAssertNil(library.recentLinks.first?.position)
        library.updatePosition(PagePosition(x: 0, y: 720), for: url)
        library.recordClosing(url, title: "Article", position: PagePosition(x: 0, y: 720))
        XCTAssertEqual(LinkLibrary(defaults: defaults).recentLinks.first?.position?.y, 720)
        library.clearHistory()
        library.recordClosing(URL(string: "about:blank")!, title: "Not a history page", position: .top,
                              revision: library.historyRevision)
        XCTAssertTrue(library.recentLinks.isEmpty)
        library.updatePosition(PagePosition(x: 0, y: 800), for: url)
        library.recordClosing(url, title: "Must stay cleared", position: .top)
        XCTAssertTrue(library.recentLinks.isEmpty)
        library.recordVisit(url, title: "New visit")
        library.updatePosition(PagePosition(x: 0, y: 900), for: url)
        library.flushHistory()
        XCTAssertEqual(LinkLibrary(defaults: defaults).recentLinks.first?.position?.y, 900,
                       "Quitting must flush positions before the scroll debounce expires")
        library.updatePosition(PagePosition(x: 0, y: 950), for: url)
        library.setSavesHistory(false)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(defaults.data(forKey: "recentLinks"))
        XCTAssertEqual(library.recentLinks.first?.position?.y, 950)
        XCTAssertTrue(LinkLibrary(defaults: defaults).recentLinks.isEmpty)
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

    func testFolderDisclosureMigratesAndPreservesAllClosedStateWithoutHistory() throws {
        let suite = "FolderDisclosure.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = BookmarkFolder(id: UUID(), name: "Work")
        let second = BookmarkFolder(id: UUID(), name: "Reference")
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "bookmarkFolders")
        let library = LinkLibrary(defaults: defaults)
        XCTAssertEqual(library.expandedFolderIDs, [first.id, second.id], "Older profiles keep their previous appearance")
        library.toggleFolder(first.id)
        XCTAssertEqual(LinkLibrary(defaults: defaults).expandedFolderIDs, [second.id])
        library.toggleFolder(second.id)
        let restored = LinkLibrary(defaults: defaults)
        XCTAssertTrue(restored.expandedFolderIDs.isEmpty, "An empty saved set means all folders are closed")
        let third = try XCTUnwrap(restored.addFolder(name: "New folder"))
        XCTAssertEqual(LinkLibrary(defaults: defaults).expandedFolderIDs, [third.id])
        let settings = SearchSettings(defaults: defaults, fetchIcon: { _ in Data() })
        restored.bind(to: settings)
        let site = try settings.addFavoriteSite(name: "Docs", address: "https://swift.org")
        restored.moveBookmark(site, to: first.id)
        XCTAssertEqual(LinkLibrary(defaults: defaults).expandedFolderIDs, [first.id, third.id],
                       "Moving a bookmark into a folder reveals it and saves that state")
        restored.removeFolder(third)
        XCTAssertEqual(LinkLibrary(defaults: defaults).expandedFolderIDs, [first.id])
        restored.toggleFolder(UUID())
        XCTAssertEqual(LinkLibrary(defaults: defaults).expandedFolderIDs, [first.id])
        defaults.set([first.id.uuidString, third.id.uuidString, "invalid"], forKey: "bookmarkExpandedFolderIDs")
        XCTAssertEqual(LinkLibrary(defaults: defaults).expandedFolderIDs, [first.id], "Deleted and malformed IDs are ignored")
        XCTAssertFalse(restored.savesHistory)
        XCTAssertNil(defaults.object(forKey: "recentLinks"))
        XCTAssertEqual(SearchSettings(defaults: defaults).favoriteSites.map(\.id), [site.id])
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

    func testSidebarCanBeDisabledForFullscreenAcrossEveryEntryPoint() throws {
        let suite = "SidebarFullscreen.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        let library = model.linkLibrary
        library.setEnabled(true)
        var options: NSApplication.PresentationOptions = []
        let controller = SidebarWindowController(model: model, reduceMotion: { true }, presentationOptions: { options })
        defer { controller.hide(animated: false); library.setEnabled(false) }
        XCTAssertFalse(library.hidesInFullScreen, "The new restriction is opt-in")
        library.setHidesInFullScreen(true)
        XCTAssertTrue(LinkLibrary(defaults: defaults).hidesInFullScreen)
        controller.toggle()
        XCTAssertTrue(controller.isPresented)
        options = [.fullScreen, .autoHideMenuBar, .autoHideDock]
        controller.refreshFullScreenAvailability()
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(controller.window!.isVisible)
        controller.toggle()
        controller.showDownloads()
        let screen = try XCTUnwrap(NSScreen.main)
        controller.showIndicator(on: screen)
        let edge = NSPoint(x: screen.frame.minX, y: screen.visibleFrame.midY)
        controller.pollMouse(at: edge, now: Date().addingTimeInterval(4))
        controller.pollMouse(at: edge, now: Date().addingTimeInterval(7))
        XCTAssertFalse(controller.isPresented)
        XCTAssertNil(controller.indicatorWindow)
        controller.editor.showFolder()
        controller.refreshFullScreenAvailability()
        XCTAssertFalse(controller.editor.isEditing)
        XCTAssertFalse(controller.window!.isVisible, "A delayed inline editor cannot bypass fullscreen suppression")
        // Hidden Dock/menu preferences by themselves do not mean fullscreen.
        options = [.autoHideMenuBar, .autoHideDock]
        controller.toggle()
        XCTAssertTrue(controller.isPresented)
        controller.hide(animated: false)
        options = [.fullScreen]
        library.setHidesInFullScreen(false)
        controller.toggle()
        XCTAssertTrue(controller.isPresented)
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
        XCTAssertEqual(library.sectionOrder, [.open, .bookmarks, .recent, .downloads])
        XCTAssertEqual(library.expandedSections, Set(SidebarSection.allCases))
        library.toggleSection(.bookmarks)
        library.moveSection(.recent, before: .bookmarks)
        XCTAssertEqual(library.sectionOrder, [.open, .recent, .bookmarks, .downloads])
        XCTAssertFalse(library.expandedSections.contains(.bookmarks))
        XCTAssertTrue(library.expandedSections.contains(.recent))
        let restored = LinkLibrary(defaults: defaults)
        XCTAssertEqual(restored.sectionOrder, [.open, .recent, .bookmarks, .downloads])
        XCTAssertEqual(restored.expandedSections, [.open, .recent, .downloads])
        restored.toggleSection(.open)
        restored.moveSection(.open, before: nil)
        let reordered = LinkLibrary(defaults: defaults)
        XCTAssertEqual(reordered.sectionOrder, [.recent, .bookmarks, .downloads, .open])
        XCTAssertEqual(reordered.expandedSections, [.recent, .downloads])
        restored.moveSection(.open, before: .recent)
        restored.toggleSection(.open)
        XCTAssertEqual(library.rootOrder, [site.id])
        XCTAssertEqual(settings.favoriteSites, [site])
        restored.moveSection(.recent, before: nil)
        restored.toggleSection(.bookmarks)
        XCTAssertEqual(restored.sectionOrder, [.open, .bookmarks, .downloads, .recent])
        XCTAssertEqual(restored.expandedSections, Set(SidebarSection.allCases))
        defaults.set(try JSONEncoder().encode([SidebarSection.recent, .recent]), forKey: "sidebarSectionOrder")
        XCTAssertEqual(LinkLibrary(defaults: defaults).sectionOrder, [.open, .recent, .bookmarks, .downloads])
        // A profile from before Open windows keeps its chosen order and collapses.
        defaults.set(try JSONEncoder().encode([SidebarSection.recent, .bookmarks]), forKey: "sidebarSectionOrder")
        defaults.set(false, forKey: "sidebarExpanded.recent")
        let migrated = LinkLibrary(defaults: defaults)
        XCTAssertEqual(migrated.sectionOrder, [.open, .recent, .bookmarks, .downloads])
        XCTAssertEqual(migrated.expandedSections, [.open, .bookmarks, .downloads])
        XCTAssertEqual(settings.favoriteSites, [site])
    }

    func testDownloadedFilePublishingPreservesExistingFilesAndDetectsConflicts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("report.txt")
        try Data("original".utf8).write(to: target)
        let prepared = try DownloadFiles.prepare(destination: target)
        defer { DownloadFiles.remove(prepared.folder) }
        let source = prepared.folder.appendingPathComponent("report.txt")
        try Data("complete".utf8).write(to: source)
        try DownloadFiles.publish(source: source, destination: target, existing: prepared.existing)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "complete")
        XCTAssertNotNil(try target.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        XCTAssertThrowsError(try DownloadFiles.publish(source: source, destination: target, existing: nil))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "complete")
        let snapshot = try DownloadFiles.fingerprint(target)
        try Data("changed in another app".utf8).write(to: target)
        XCTAssertThrowsError(try DownloadFiles.publish(source: source, destination: target, existing: snapshot))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "changed in another app")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["report.txt"])
        XCTAssertEqual(DownloadManager.safeFilename("../../report.txt"), "report.txt")
        XCTAssertEqual(DownloadManager.safeFilename("..\\hidden\\report.txt"), "report.txt")
        XCTAssertFalse(DownloadManager.safeFilename("\n\r").isEmpty)
    }

    func testSidebarAppearanceIsOptInAndPreservesExistingPreferences() throws {
        let suite = "SidebarAppearance.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LinkLibrary(defaults: defaults)
        XCTAssertEqual(library.sidebarAppearance, .black)
        library.setSidebarWidth(240)
        library.setEdgeOpenDelay(0.7)
        library.toggleSection(.recent)
        library.moveSection(.downloads, before: .open)
        let order = library.sectionOrder
        library.setSidebarAppearance(.glass)
        let restored = LinkLibrary(defaults: defaults)
        XCTAssertEqual(restored.sidebarAppearance, .glass)
        XCTAssertFalse(restored.isEnabled, "Trying glass must not enable screen-edge activation")
        XCTAssertEqual(restored.sidebarWidth, 240)
        XCTAssertEqual(restored.edgeOpenDelay, 0.7)
        XCTAssertEqual(restored.sectionOrder, order)
        XCTAssertFalse(restored.expandedSections.contains(.recent))
        restored.setSidebarAppearance(.black)
        XCTAssertEqual(LinkLibrary(defaults: defaults).sidebarAppearance, .black)
        defaults.set("unknown-future-style", forKey: "sidebarAppearance")
        XCTAssertEqual(LinkLibrary(defaults: defaults).sidebarAppearance, .black)
    }

    func testSidebarAppearanceRenderingAndReducedTransparencyFallback() async throws {
        guard SidebarAppearance.supportsGlass else { throw XCTSkip("Liquid Glass requires macOS 26") }
        let reveal = SidebarRevealState()
        reveal.progress = 1
        reveal.shoulderProgress = 1
        let sceneSize = NSSize(width: 460, height: 600)
        for (appearance, reduced, name) in [(SidebarAppearance.black, false, "black"), (.glass, false, "glass"), (.glass, true, "glass-reduced")] {
            let scene = ZStack(alignment: .leading) {
                SidebarGlassTestBackdrop()
                SidebarRevealSurface(reveal: reveal, appearance: appearance, reduceTransparency: reduced) { Color.clear }
                    .frame(width: 320, height: sceneSize.height)
            }.frame(width: sceneSize.width, height: sceneSize.height).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: scene)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: sceneSize),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setContentSize(sceneSize)
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(180))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Liquid Glass is composed by WindowServer. AppKit bitmap capture
            // returns intermediate material layers. Color assertions cover opaque
            // backgrounds/tint; the native optics also get an on-screen check.
            let scale = CGFloat(bitmap.pixelsWide) / sceneSize.width
            func sample(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
                try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
            }
            // Opaque correction must keep the left side truly black in glass
            // mode too, including the original concave screen-edge shoulders.
            for point in [CGPoint(x: 30, y: 300), CGPoint(x: 2, y: 18), CGPoint(x: 2, y: 582)] {
                let left = try sample(point.x, point.y)
                XCTAssertLessThan(left.redComponent + left.greenComponent + left.blueComponent, 0.03)
                XCTAssertGreaterThan(left.alphaComponent, 0.99)
            }
            if appearance == .black || reduced {
                let right = try sample(300, 300)
                XCTAssertLessThan(right.redComponent + right.greenComponent + right.blueComponent, 0.03)
            }
            // The existing contour leaves the center of the top edge exposed.
            if appearance == .black || reduced {
                let outside = try sample(160, 5)
                XCTAssertGreaterThan(outside.blueComponent, 0.1)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-sidebar-\(name).png"))
            }
            window.close()
        }
    }

    func testSidebarGlassKeepsItsAppearanceWhileKeyboardFocusMovesNormally() async throws {
        guard SidebarAppearance.supportsGlass else { throw XCTSkip("Liquid Glass requires macOS 26") }
        let selector = NSSelectorFromString("_hasActiveAppearance")
        guard class_getInstanceMethod(NSPanel.self, selector) != nil else {
            throw XCTSkip("This macOS no longer exposes the experimental glass appearance hook")
        }
        let suite = "SidebarGlassFocus.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.linkLibrary.setSidebarAppearance(.glass)
        model.linkLibrary.setEnabled(true)
        let controller = SidebarWindowController(model: model, reduceMotion: { true })
        controller.toggle()
        let panel = try XCTUnwrap(controller.window)
        // Keep the surface visible for comparison; normal resign-key dismissal
        // is covered separately by the sidebar interaction tests.
        panel.delegate = nil
        let other = NSPanel(contentRect: NSRect(x: 600, y: 100, width: 200, height: 100),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 180, height: 24))
        other.contentView?.addSubview(field)
        defer { other.close(); controller.hide(animated: false); model.linkLibrary.setEnabled(false) }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(try XCTUnwrap(panel.method(for: selector)), to: Getter.self)
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.isKeyWindow)
        XCTAssertTrue(getter(panel, selector))
        other.makeKeyAndOrderFront(nil)
        XCTAssertTrue(other.makeFirstResponder(field))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(other.isKeyWindow, "A decorative glass effect must not retain keyboard focus")
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)
        XCTAssertTrue(getter(panel, selector), "Inactive glass must keep the same native lensing appearance")
        XCTAssertTrue(other.firstResponder is NSTextView)
        XCTAssertTrue(panel.isVisible)
        model.linkLibrary.setSidebarAppearance(.black)
        try await Task.sleep(for: .milliseconds(100))
        let native = try XCTUnwrap(class_getInstanceMethod(NSPanel.self, selector))
        let nativeGetter = unsafeBitCast(method_getImplementation(native), to: Getter.self)
        XCTAssertEqual(getter(panel, selector), nativeGetter(panel, selector), "Black mode must restore AppKit's original behavior")
        model.linkLibrary.setSidebarAppearance(.glass)
        XCTAssertTrue(getter(panel, selector))
    }

    func testSidebarAppearancePickerChangesTheLivePanelWithoutResizing() async throws {
        guard SidebarAppearance.supportsGlass else { throw XCTSkip("Liquid Glass requires macOS 26") }
        let suite = "SidebarAppearancePicker.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.linkLibrary.setEnabled(true)
        let controller = SidebarWindowController(model: model, reduceMotion: { true })
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800),
                                styleMask: [.titled], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        settings.contentView = NSHostingView(rootView: SidebarSettingsView(library: model.linkLibrary, show: {}))
        defer { settings.close(); controller.hide(animated: false); model.linkLibrary.setEnabled(false) }
        settings.orderFront(nil)
        settings.contentView?.layoutSubtreeIfNeeded()
        controller.toggle()
        let panel = try XCTUnwrap(controller.window)
        let frame = panel.frame
        func segmented(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl, control.segmentCount == 2 { return control }
            return view.subviews.compactMap { segmented(in: $0) }.first
        }
        try await Task.sleep(for: .milliseconds(100))
        let picker = try XCTUnwrap(settings.contentView.flatMap { segmented(in: $0) })
        XCTAssertEqual(model.linkLibrary.sidebarAppearance, .black)
        picker.selectedSegment = 1
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.linkLibrary.sidebarAppearance, .glass)
        XCTAssertEqual(panel.frame, frame)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.isOpaque)
        picker.selectedSegment = 0
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.linkLibrary.sidebarAppearance, .black)
        XCTAssertEqual(panel.frame, frame)
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
    func testSidebarFavoritePlusOpensBookmarkFormWithoutTogglingSection() async throws {
        let pointer = CGEvent(source: nil)?.location
        defer { if let pointer { CGWarpMouseCursorPosition(pointer) } }
        let suite = "SidebarFavoriteHeader.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchSettings(defaults: defaults, fetchIcon: { _ in Data() })
        let model = AppModel(defaults: defaults, searchSettings: settings, discoverTargets: { [] })
        model.linkLibrary.setEnabled(true)
        model.linkLibrary.setSidebarWidth(240)
        let sidebar = SidebarWindowController(model: model, reduceMotion: { true })
        defer { sidebar.hide(animated: false); model.linkLibrary.setEnabled(false) }
        sidebar.toggle()
        let window = try XCTUnwrap(sidebar.window)
        let content = try XCTUnwrap(window.contentView)
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        func frame(_ node: NSObject) throws -> NSRect {
            try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        }
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws {
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y))
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.postEvent(event, atStart: true)
            while let queued = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(queued)
            }
        }
        for expanded in [true, false] {
            if model.linkLibrary.expandedSections.contains(.bookmarks) != expanded { model.linkLibrary.toggleSection(.bookmarks) }
            try await waitUntil { self.accessibilityNode(in: content, identifier: "sidebar-section-bookmarks") != nil }
            let header = try XCTUnwrap(accessibilityNode(in: content, identifier: "sidebar-section-bookmarks"))
            let headerFrame = try frame(header)
            try mouse(.mouseMoved, at: NSPoint(x: headerFrame.midX, y: headerFrame.midY))
            try await Task.sleep(for: .milliseconds(180))
            let add = try XCTUnwrap(accessibilityNode(in: content, identifier: "sidebar-add-bookmark"))
            let addFrame = try frame(add)
            let point = NSPoint(x: addFrame.midX, y: addFrame.midY)
            try mouse(.mouseMoved, at: point)
            try mouse(.leftMouseDown, at: point)
            try mouse(.leftMouseUp, at: point)
            try await waitUntil { sidebar.editor.isEditing }
            XCTAssertEqual(model.linkLibrary.expandedSections.contains(.bookmarks), expanded)
            guard case .bookmark(nil, nil) = sidebar.editor.presentation?.target else {
                XCTFail("The plus must open a new-bookmark form directly"); return
            }
            sidebar.editor.cancel()
        }
    }

    func testHistoryTracksRedirectSPAAndReopensLastClosedPosition() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "VisitedHistory.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "keepsPreviewVisibleWhenInactive")
        defaults.set(true, forKey: "sidebarSavesHistory")
        let settings = SearchSettings(defaults: defaults, fetchIcon: { _ in Data() })
        let model = AppModel(defaults: defaults, searchSettings: settings, discoverTargets: { [] })
        model.siteData.selectModeForPreview(false)
        defer { model.closeAllWindows(); defaults.removePersistentDomain(forName: suite) }
        let incoming = URL(string: "http://127.0.0.1:\(port)/history-start")!
        let reader = URL(string: "http://127.0.0.1:\(port)/history-reader")!
        model.showPreview(url: incoming)
        let session = model.previewSession
        try await waitUntil { session.pageTitle == "Reader" && !session.isLoading }
        XCTAssertFalse(model.linkLibrary.isEnabled)
        XCTAssertEqual(session.originalURL, incoming)
        XCTAssertEqual(model.linkLibrary.recentLinks.map(\.address), [reader.absoluteString])
        let view = try XCTUnwrap(session.webView)
        let window = try XCTUnwrap(view.window)
        _ = try await view.evaluateJavaScript("history.pushState(null,'','/history-reader?section=last#note');document.title='Reader — last';scrollTo(0,1250);true")
        let final = URL(string: reader.absoluteString + "?section=last#note")!
        try await waitUntil {
            model.linkLibrary.recentLinks.first?.address == final.absoluteString &&
            model.linkLibrary.recentLinks.first?.title == "Reader — last" &&
            (model.linkLibrary.recentLinks.first?.position?.y ?? 0) >= 1249
        }
        _ = try await view.evaluateJavaScript("window.open('/destination','history-child');true")
        try await waitUntil { model.linkLibrary.recentLinks.first?.title == "Destination" }
        window.performClose(nil)
        try await waitUntil { !session.isActive }
        let closed = try XCTUnwrap(model.linkLibrary.recentLinks.first)
        XCTAssertEqual(closed.address, final.absoluteString, "The last closed location moves above newer visits in other windows")
        XCTAssertEqual(closed.position?.y ?? 0, 1250, accuracy: 2)
        let persisted = try XCTUnwrap(LinkLibrary(defaults: defaults).recentLinks.first)
        XCTAssertEqual(persisted.address, final.absoluteString)
        XCTAssertEqual(persisted.position?.y ?? 0, 1250, accuracy: 2)
        model.showRecentLink(closed)
        try await waitUntil { session.currentURL == final && !session.isLoading && session.webView != nil }
        let reopened = try XCTUnwrap(session.webView)
        try await waitUntil { ((try? await reopened.evaluateJavaScript("scrollY")) as? Double ?? 0) >= 1249 }
        XCTAssertEqual(session.originalURL, final)
        XCTAssertNil(session.pageFailure)
        XCTAssertNotNil(model.linkLibrary.recentLinks.first { $0.address == reader.absoluteString })
        // Back/forward visits also use their real URL rather than the incoming URL.
        _ = try await reopened.evaluateJavaScript("history.pushState(null,'','/history-reader?second');true")
        try await waitUntil { model.linkLibrary.recentLinks.first?.address.hasSuffix("?second") == true }
        session.goBack()
        try await waitUntil { session.currentURL == final && model.linkLibrary.recentLinks.first?.address == final.absoluteString }
    }

    func testNetworkRetryAndRealWebContentRecoveryKeepWindowAndHistory() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "Recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "keepsPreviewVisibleWhenInactive")
        let settings = SearchSettings(defaults: defaults, fetchIcon: { _ in Data() })
        let model = AppModel(defaults: defaults, searchSettings: settings, discoverTargets: { [] })
        model.siteData.selectModeForPreview(false)
        defer { model.closeAllWindows(); defaults.removePersistentDomain(forName: suite) }
        let original = URL(string: "http://127.0.0.1:\(port)/site")!
        let target = URL(string: "http://127.0.0.1:\(port)/recovery")!
        model.showPreview(url: original)
        let session = model.previewSession
        try await waitUntil { session.pageTitle == "Original site" && !session.isLoading }
        let view = try XCTUnwrap(session.webView)
        let window = try XCTUnwrap(view.window)
        let navigationID = session.navigationID
        _ = try await view.evaluateJavaScript("window.recoverySentinel='kept';true")
        XCTAssertTrue(session.submitAddress(target.absoluteString, engine: .google))
        try await waitUntil { session.pageFailure != nil && !session.isLoading }
        XCTAssertEqual(session.pageFailure?.url, target)
        XCTAssertEqual(session.currentURL, target)
        XCTAssertEqual(session.originalURL, original)
        XCTAssertFalse(model.linkLibrary.recentLinks.contains { $0.address == target.absoluteString })
        XCTAssertTrue(session.canReturnToLoadedPage)
        session.returnToLoadedPage()
        let sentinel = try await view.evaluateJavaScript("window.recoverySentinel") as? String
        XCTAssertEqual(sentinel, "kept", "Returning from a provisional error must keep the live page and its form state")
        XCTAssertEqual(session.currentURL, original)
        XCTAssertTrue(session.submitAddress(target.absoluteString, engine: .google))
        try await waitUntil { session.pageFailure != nil }
        window.contentView?.layoutSubtreeIfNeeded()
        if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-page-error.png"))
        }
        server.enableRecovery()
        let button = try XCTUnwrap(window.contentView.flatMap { accessibilityNode(in: $0, identifier: "preview-retry-page") })
        XCTAssertEqual(button.value(forKey: "accessibilityPerformPress") as? Bool, true)
        try await waitUntil { session.pageFailure == nil && session.pageTitle == "Recovered" && !session.isLoading }
        XCTAssertTrue(session.webView === view)
        XCTAssertEqual(session.navigationID, navigationID)
        XCTAssertEqual(session.originalURL, original)
        XCTAssertEqual(model.linkLibrary.recentLinks.first?.address, target.absoluteString)
        let other = UploadTestPage(url: original)
        defer { other.close() }
        try await waitUntil { other.session.pageTitle == "Original site" && !other.session.isLoading }
        _ = try await other.view.evaluateJavaScript("window.independentSentinel='alive';true")
        session.changePageZoom(increase: true)
        // A client-requested WebKit termination suppresses the public crash
        // callback. Kill only this fixture view's own WebContent PID instead.
        // These runtime hooks exist only in the test bundle, not production.
        let processID = NSSelectorFromString("_webProcessIdentifier")
        guard view.responds(to: processID) else { throw XCTSkip("This WebKit lacks the test-only WebContent PID accessor") }
        typealias ProcessIDGetter = @convention(c) (AnyObject, Selector) -> Int32
        let getter = unsafeBitCast(view.method(for: processID), to: ProcessIDGetter.self)
        let pid = getter(view, processID)
        guard pid > 0, pid != getpid() else { throw XCTSkip("The fixture has no live WebContent process") }
        XCTAssertEqual(Darwin.kill(pid, SIGKILL), 0)
        try await waitUntil { session.pageFailure?.kind == .crashed }
        XCTAssertTrue(window.isVisible)
        XCTAssertNil(other.session.pageFailure)
        let otherSentinel = try await other.view.evaluateJavaScript("window.independentSentinel") as? String
        XCTAssertEqual(otherSentinel, "alive")
        let requests = server.pageRequests.count
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(server.pageRequests.count, requests, "Do not automatically reload after a crash")
        session.reload() // Same action as Cmd-R, with an explicit recovery request.
        try await waitUntil { session.pageFailure == nil && session.pageTitle == "Recovered" && !session.isLoading }
        XCTAssertTrue(session.webView === view)
        XCTAssertEqual(view.pageZoom, 1.1, accuracy: 0.001)
        XCTAssertEqual(session.originalURL, original)
    }

    func testCancellationHTTPDocumentsAndUnsafePOSTRetryAreHandledSeparately() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let original = URL(string: "http://127.0.0.1:\(port)/site")!
        let page = UploadTestPage(url: original)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Original site" && !page.session.isLoading }
        page.coordinator.webView(page.view, didFailProvisionalNavigation: nil,
                                 withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(page.session.pageFailure)
        XCTAssertTrue(page.session.submitAddress("http://127.0.0.1:\(port)/http-error", engine: .google))
        try await waitUntil { page.session.pageTitle == "Access denied by website" && !page.session.isLoading }
        XCTAssertNil(page.session.pageFailure)
        XCTAssertNil(page.session.errorMessage, "HTTP error documents should render without a second modal error")
        let target = URL(string: "http://127.0.0.1:\(port)/post-failure")!
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        page.session.prepareNavigation(request, in: page.view)
        page.coordinator.webView(page.view, didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                               userInfo: [NSURLErrorFailingURLErrorKey: target]))
        try await waitUntil { page.session.pageFailure != nil }
        XCTAssertEqual(page.session.pageFailure?.kind, .offline)
        XCTAssertFalse(page.session.pageFailure?.allowsRetry ?? true, "Never turn an uncommitted POST into an accidental GET or replay an unavailable body")
        let before = server.pageRequests.count
        page.session.retryPageLoad()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.pageRequests.count, before)
        page.session.returnToLoadedPage()
        page.coordinator.webView(page.view, didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted,
                               userInfo: [NSURLErrorFailingURLErrorKey: target]))
        try await waitUntil { page.session.pageFailure?.kind == .certificate }
    }

    func testBookmarkStateAndAddressCopyFeedbackInIndependentWindows() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "CompactToolbar.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "keepsPreviewVisibleWhenInactive")
        let settings = SearchSettings(defaults: defaults, fetchIcon: { _ in Data() })
        let model = AppModel(defaults: defaults, searchSettings: settings, discoverTargets: { [] })
        model.siteData.selectModeForPreview(false)
        defer { model.closeAllWindows(); defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.general
        let savedClipboard = (pasteboard.pasteboardItems ?? []).map { original -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for type in original.types { if let data = original.data(forType: type) { item.setData(data, forType: type) } }
            return item
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(savedClipboard) }
        let original = URL(string: "http://127.0.0.1:\(port)/site")!
        model.showPreview(url: original)
        try await waitUntil { model.previewSession.pageTitle == "Original site" }
        let source = try XCTUnwrap(model.previewSession.webView)
        _ = try await source.evaluateJavaScript("window.open('/site','toolbar-child');true")
        try await waitUntil { model.windowRegistry.webWindows(openedBy: model.previewSession.windowID).values.first?.session.pageTitle == "Original site" }
        let child = try XCTUnwrap(model.windowRegistry.webWindows(openedBy: model.previewSession.windowID).values.first?.session)
        let sessions = [model.previewSession, child]
        let windows = try sessions.map { try XCTUnwrap($0.webView?.window) }
        func bookmark(in window: NSWindow) -> NSObject? {
            window.contentView.flatMap { accessibilityNode(in: $0, identifier: "preview-bookmark") }
        }
        for window in windows {
            try await waitUntil { bookmark(in: window)?.value(forKey: "accessibilityValue") as? String == L("Not bookmarked") }
        }
        let site = try settings.addFavoriteSite(name: "Saved page", address: original.absoluteString)
        for window in windows {
            try await waitUntil { bookmark(in: window)?.value(forKey: "accessibilityValue") as? String == L("Saved bookmark") }
        }
        // Clicking an existing bookmark edits it. Saving must not create a duplicate.
        NSApp.activate(ignoringOtherApps: true)
        windows[0].makeKeyAndOrderFront(nil)
        try await waitUntil { windows[0].isKeyWindow && NSApp.isActive }
        XCTAssertEqual(bookmark(in: windows[0])?.value(forKey: "accessibilityPerformPress") as? Bool, true)
        try await waitUntil { windows[0].attachedSheet != nil }
        let sheet = try XCTUnwrap(windows[0].attachedSheet)
        try sendAddressKey(to: sheet, code: 36, characters: "\r")
        try await waitUntil { windows[0].attachedSheet == nil }
        XCTAssertEqual(settings.favoriteSites.count, 1)
        XCTAssertEqual(settings.favoriteSites.first?.id, site.id)
        settings.removeFavoriteSite(site)
        for window in windows {
            try await waitUntil { bookmark(in: window)?.value(forKey: "accessibilityValue") as? String == L("Not bookmarked") }
        }

        for (index, session) in sessions.enumerated() {
            let window = windows[index]
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await waitUntil { window.isKeyWindow && NSApp.isActive }
            window.contentView?.layoutSubtreeIfNeeded()
            let address = try addressControl(in: window)
            address.updateActions(hovered: false, bookmarked: false, editingBookmark: false)
            try await waitUntil { address.copyButton.alphaValue == 0 && address.bookmarkButton.alphaValue == 0 }
            XCTAssertEqual(address.copyButton.alphaValue, 0)
            XCTAssertEqual(address.bookmarkButton.alphaValue, 0)
            let restingFrame = address.frame
            address.updateActions(hovered: true, bookmarked: false, editingBookmark: false)
            try await waitUntil { address.copyButton.alphaValue == 1 && address.bookmarkButton.alphaValue == 1 }
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(address.copyButton.alphaValue, 1)
            XCTAssertEqual(address.bookmarkButton.alphaValue, 1)
            XCTAssertEqual(address.frame, restingFrame, "Revealing actions must not move the address")
            XCTAssertEqual(address.copyButton.frame.width, PreviewLayout.controlHeight)
            XCTAssertEqual(address.copyButton.frame.height, PreviewLayout.controlHeight)
            XCTAssertEqual(address.bookmarkButton.frame.size, address.copyButton.frame.size)
            XCTAssertEqual(address.bookmarkButton.frame.minX - address.copyButton.frame.maxX, PreviewLayout.toolbarItemSpacing)
            XCTAssertEqual(address.addressButton.frame.minX - address.bookmarkButton.frame.maxX,
                           PreviewLayout.toolbarItemSpacing + PreviewLayout.toolbarContentInset)
            let view = try XCTUnwrap(session.webView)
            _ = try await view.evaluateJavaScript("history.replaceState(null,'','/site?copy=full#fragment');window.toolbarSentinel='kept';true")
            let current = URL(string: original.absoluteString + "?copy=full#fragment")!
            try await waitUntil { session.currentURL == current && address.addressButton.toolTip?.hasPrefix(current.absoluteString) == true }
            let frame = address.frame
            let pageFrame = view.frame
            let domain = address.addressButton.title
            func click(_ type: NSEvent.EventType, onIcon: Bool = true, modifiers: NSEvent.ModifierFlags = []) throws {
                // Synthetic clicks do not move the system pointer into SwiftUI's
                // toolbar tracking area; reveal the native controls explicitly.
                address.updateActions(hovered: true, bookmarked: false, editingBookmark: false)
                let target = onIcon ? address.copyButton.frame : address.addressButton.frame
                let point = address.convert(NSPoint(x: target.midX, y: target.midY), to: nil)
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
                let upType: NSEvent.EventType = type == .leftMouseDown ? .leftMouseUp : .rightMouseUp
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: upType, location: point, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 0))
                // Native NSButton tracks synchronously until mouse-up.
                NSApp.postEvent(up, atStart: true)
                NSApp.postEvent(event, atStart: true)
                let mask = NSEvent.EventTypeMask(rawValue: 1 << type.rawValue)
                if let next = NSApp.nextEvent(matching: mask, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) { NSApp.sendEvent(next) }
                let upMask = NSEvent.EventTypeMask(rawValue: 1 << upType.rawValue)
                if let remaining = NSApp.nextEvent(matching: upMask, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(remaining) }
            }
            // Both mouse buttons copy from the icon, leaving the domain visible.
            try click(.leftMouseDown)
            XCTAssertEqual(pasteboard.string(forType: .string), current.absoluteString)
            XCTAssertTrue(address.isShowingCopyFeedback)
            XCTAssertFalse(address.isExpanded)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(address.addressButton.alphaValue, 1)
            XCTAssertEqual(address.addressButton.title, domain)
            XCTAssertEqual(address.copyButton.accessibilityValue() as? String, L("Copied!"))
            XCTAssertEqual(address.frame, frame)
            XCTAssertEqual(view.frame, pageFrame)
            if index == 0 {
                if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-address-icon-copied.png"))
                }
                try await Task.sleep(for: .milliseconds(1100))
                try click(.rightMouseDown)
                try await Task.sleep(for: .milliseconds(900))
                XCTAssertTrue(address.isShowingCopyFeedback, "Repeated copy restarts the two-second lifetime")
                try await waitUntil { !address.isShowingCopyFeedback && address.copyButton.accessibilityValue() == nil }
            } else {
                // Domain clicks open the editor even while the icon shows a checkmark.
                try click(.leftMouseDown, onIcon: false)
                try await waitUntil { address.isExpanded && address.addressField.currentEditor() != nil }
                XCTAssertFalse(address.isShowingCopyFeedback)
                window.contentView?.layoutSubtreeIfNeeded()
                XCTAssertEqual(address.addressField.frame.midY, address.bounds.midY, accuracy: 0.5)
                let editor = try XCTUnwrap(address.addressField.currentEditor() as? NSTextView)
                let editorFrame = editor.convert(editor.bounds, to: address)
                XCTAssertEqual(editorFrame.midY, address.bounds.midY, accuracy: 1,
                               "The live editor and insertion cursor must be centered too")
                if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-address-editor-centered.png"))
                }
                try sendAddressKey(to: window, code: 53, characters: "\u{1b}")
            }
            try click(.leftMouseDown, modifiers: .control)
            XCTAssertTrue(address.isShowingCopyFeedback)
            XCTAssertFalse(address.isExpanded)
            _ = try await view.evaluateJavaScript("history.replaceState(null,'','/destination');true")
            try await waitUntil { session.currentURL?.path == "/destination" && !address.isShowingCopyFeedback }
            XCTAssertEqual(session.originalURL, original)
            let sentinel = try await view.evaluateJavaScript("window.toolbarSentinel") as? String
            XCTAssertEqual(sentinel, "kept")
        }
    }

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
            XCTAssertLessThanOrEqual(address.addressButton.frame.width + 2 * PreviewLayout.toolbarContentInset, 180)
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
        let pointer = CGEvent(source: nil)?.location
        defer { if let pointer { CGWarpMouseCursorPosition(pointer) } }
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
        // Hover reveals a separate close target; it must not activate the source
        // window or close its still-live child as a side effect.
        let sourceRow = try XCTUnwrap(accessibilityNode(in: content, identifier: sourceID))
        let sourceFrame = try XCTUnwrap(sourceRow.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let panel = try XCTUnwrap(sidebar.window)
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        func movePointer(to point: NSPoint) throws {
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: screenTop - point.y))
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: panel.convertPoint(fromScreen: point),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            NSApp.postEvent(event, atStart: true)
            while let queued = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(queued)
            }
        }
        try movePointer(to: NSPoint(x: sourceFrame.midX, y: sourceFrame.midY))
        try await Task.sleep(for: .milliseconds(180))
        let close = try XCTUnwrap(accessibilityNode(in: content, identifier: "sidebar-close-window-\(model.previewSession.windowID.uuidString)"))
        let closeFrame = try XCTUnwrap(close.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let closePoint = NSPoint(x: closeFrame.midX, y: closeFrame.midY)
        try movePointer(to: closePoint)
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-sidebar-hover-close.png"))
        }
        for type in [NSEvent.EventType.leftMouseUp, .leftMouseDown] {
            NSApp.postEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: closePoint),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)), atStart: true)
        }
        while let queued = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
        try await waitUntil { !model.previewSession.isActive && self.accessibilityNode(in: content, identifier: sourceID) == nil }
        XCTAssertTrue(popup.session.isActive)
        XCTAssertEqual(model.windowRegistry.windows.map(\.id), [popup.session.windowID])
        XCTAssertEqual(server.pageRequests, before, "Closing a row must not issue any page request")
        // Site-controlled window.close must remove the visible row immediately.
        _ = try await popup.webView.evaluateJavaScript("window.close();true")
        try await waitUntil { self.accessibilityNode(in: content, identifier: popupID) == nil }
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

    func testWebWindowDeliversMouseMovesAfterTextEntryAndMapDragging() async throws {
        let pointerPosition = CGEvent(source: nil)?.location
        defer { if let pointerPosition { CGWarpMouseCursorPosition(pointerPosition) } }
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "WebCursorTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "keepsPreviewVisibleWhenInactive")
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.siteData.selectModeForPreview(false)
        defer { model.closeAllWindows(); defaults.removePersistentDomain(forName: suite) }
        model.showPreview(url: URL(string: "http://127.0.0.1:\(port)/cursor")!)
        try await waitUntil { model.previewSession.pageTitle == "Cursor fixture" }
        let source = try XCTUnwrap(model.previewSession.webView)
        _ = try await source.evaluateJavaScript("window.open('/cursor','cursor-child');true")
        try await waitUntil { model.windowRegistry.windows.count == 2 && model.windowRegistry.windows.last?.title == "Cursor fixture" }
        let popup = try XCTUnwrap(model.windowRegistry.webWindows(openedBy: model.previewSession.windowID).values.first)
        for page in [source, popup.webView] {
            let window = try XCTUnwrap(page.window)
            // Reproduce the native cursor rectangle retained by a hosting view
            // or field editor above WebKit in the NSView hierarchy.
            let originalContent = try XCTUnwrap(window.contentView)
            let originalController = window.contentViewController
            let cursorHost = CursorRectFixtureHost(frame: originalContent.frame)
            window.contentView = cursorHost
            originalContent.frame = cursorHost.bounds
            originalContent.autoresizingMask = [.width, .height]
            cursorHost.addSubview(originalContent)
            window.resetCursorRects()
            defer {
                if let originalController { window.contentViewController = originalController }
                else { window.contentView = originalContent }
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(page)
            window.contentView?.layoutSubtreeIfNeeded()
            // Cursor updates are rejected by WebKit while an appearing window
            // is still transparent and another window is under the pointer.
            try await waitUntil { window.alphaValue == 1 && window.isKeyWindow }
            guard window.isKeyWindow else { return }
            XCTAssertTrue(window.acceptsMouseMovedEvents, "WebKit needs mouse moves to refresh hover and cursors")
            func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws {
                let location = page.convert(point, to: nil)
                let screenPoint = window.convertPoint(toScreen: location)
                CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x,
                    y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenPoint.y))
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: type == .leftMouseDown ? 1 : 0, pressure: type == .leftMouseDown ? 1 : 0))
                // Let AppKit update tracking areas before dispatch, just as for a
                // physical event. Direct sendEvent bypasses that queue processing.
                NSApp.postEvent(event, atStart: true)
                while let queued = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02),
                                                   inMode: .default, dequeue: true) {
                    NSApp.sendEvent(queued)
                }
            }
            try mouse(.mouseMoved, NSPoint(x: 70, y: 50))
            try mouse(.leftMouseDown, NSPoint(x: 70, y: 50))
            try mouse(.leftMouseUp, NSPoint(x: 70, y: 50))
            try sendAddressKey(to: window, code: 0, characters: "a")
            try await waitUntil { (try? await page.evaluateJavaScript("document.getElementById('entry').value")) as? String == "a" }
            try mouse(.mouseMoved, NSPoint(x: 70, y: 150))
            try await waitUntil { (try? await page.evaluateJavaScript("window.lastMove")) as? String == "map" }
            try await waitUntil { NSCursor.current == .openHand }
            try mouse(.leftMouseDown, NSPoint(x: 70, y: 150))
            try await waitUntil { NSCursor.current == .closedHand }
            try mouse(.leftMouseDragged, NSPoint(x: 100, y: 170))
            try mouse(.leftMouseUp, NSPoint(x: 100, y: 170))
            try await waitUntil { NSCursor.current == .openHand }
            try mouse(.mouseMoved, NSPoint(x: 70, y: 270))
            try await waitUntil { (try? await page.evaluateJavaScript("window.lastMove")) as? String == "plain" }
            try await waitUntil { NSCursor.current == .arrow }
            let state = try await page.evaluateJavaScript("[document.getElementById('entry').value,window.released,document.getElementById('map').style.cursor]") as? [String]
            XCTAssertEqual(state, ["a", "yes", "grab"])
            XCTAssertFalse(window.areCursorRectsEnabled, "Native hosting rectangles must yield to the page's CSS cursor")
            try mouse(.mouseMoved, NSPoint(x: 200, y: -20))
            XCTAssertTrue(window.areCursorRectsEnabled, "Address/find fields and window chrome regain native cursor rectangles")
        }
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

    func testDownloadsUseNativeRequestsForAttachmentsPOSTBlobDataAndSiteWindows() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        var choices = 0
        let manager = DownloadManager { name in choices += 1; return folder.appendingPathComponent("\(choices)-\(name)") }
        let page = DownloadTestPage(manager: manager, url: URL(string: "http://127.0.0.1:\(port)/download-page")!)
        defer { page.close(); manager.cancelAll() }
        let view = try XCTUnwrap(page.view)
        try await waitUntil { page.session.pageTitle == "Downloads fixture" }
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "login", .value: "fixture"])!
        await view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        let triggers = ["document.getElementById('attachment').click()", "document.getElementById('export').submit()",
                        "saveBlob()", "saveData()", "document.getElementById('inline').click()"]
        let expected = ["attachment payload", "authorized:token=fixture", "blob payload", "data payload", "inline payload"]
        for (index, trigger) in triggers.enumerated() {
            _ = try await view.evaluateJavaScript(trigger + ";true")
            try await waitUntil { manager.items.count == index + 1 && manager.items.last?.state == .finished }
            let item = try XCTUnwrap(manager.items.last)
            let saved = try XCTUnwrap(item.destination)
            XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), expected[index])
            XCTAssertNotNil(try saved.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
            XCTAssertEqual(view.url?.path, "/download-page")
            XCTAssertEqual(page.session.originalURL?.path, "/download-page")
        }
        XCTAssertEqual(server.downloadRequests.filter { $0.hasPrefix("POST /export ") }.count, 1, "Never replay a POST through URLSession")
        _ = try await view.evaluateJavaScript("window.open('/download-page','download-child');true")
        try await waitUntil { page.session.windowRegistry.webWindows(openedBy: page.session.windowID).count == 1 }
        let child = try XCTUnwrap(page.session.windowRegistry.webWindows(openedBy: page.session.windowID).values.first)
        try await waitUntil { child.session.pageTitle == "Downloads fixture" }
        _ = try await child.webView.evaluateJavaScript("document.getElementById('attachment').click();true")
        try await waitUntil { manager.items.count == 6 && manager.items.last?.state == .finished }
        XCTAssertTrue(child.session.windowRegistry.downloads === manager)
        page.session.windowRegistry.closeAll()

        let suite = "DownloadSidebar.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, windowRegistry: page.session.windowRegistry, discoverTargets: { [] })
        let sidebar = SidebarWindowController(model: model, reduceMotion: { true })
        defer { sidebar.hide(animated: false) }
        XCTAssertFalse(model.linkLibrary.isEnabled)
        sidebar.showDownloads()
        XCTAssertTrue(sidebar.isPresented, "Downloads must be accessible even with edge activation disabled")
        let content = try XCTUnwrap(sidebar.window?.contentView)
        let last = try XCTUnwrap(manager.items.last)
        try await waitUntil { self.accessibilityNode(in: content, identifier: "sidebar-download-\(last.id.uuidString)") != nil }
        // Let the requested section scroll into view before taking the snapshot.
        try await Task.sleep(for: .milliseconds(150))
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-downloads-sidebar.png"))
        }
        manager.clearFinished()
        XCTAssertTrue(manager.items.isEmpty)
    }

    func testDownloadSurvivesClosingItsPrivatePageAndReleasesCookiesAfterFinishing() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = DownloadManager { name in folder.appendingPathComponent(name) }
        let page = DownloadTestPage(manager: manager, url: URL(string: "http://127.0.0.1:\(port)/download-page")!)
        defer { page.close(); manager.cancelAll() }
        try await waitUntil { page.session.pageTitle == "Downloads fixture" }
        let store = try XCTUnwrap(page.view?.configuration.websiteDataStore)
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "login", .value: "fixture"])!
        await store.httpCookieStore.setCookie(cookie)
        _ = try await page.view?.evaluateJavaScript("document.getElementById('slow').click();true")
        try await waitUntil { manager.items.last?.received ?? 0 > 0 && manager.items.last?.state == .downloading }
        page.close()
        let liveCookies = await store.httpCookieStore.allCookies()
        XCTAssertTrue(liveCookies.contains { $0.name == "login" })
        XCTAssertTrue(manager.hasActiveDownloads)
        try await waitUntil { manager.items.last?.state == .finished }
        let file = try XCTUnwrap(manager.items.last?.destination)
        XCTAssertEqual(try Data(contentsOf: file).count, 524_288)
        try await waitUntil { await store.httpCookieStore.allCookies().isEmpty }
    }

    func testDownloadCancellationAndNetworkFailureKeepExistingFileAndOtherDownloads() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appendingPathComponent("existing.txt")
        try Data("keep".utf8).write(to: existing)
        let manager = DownloadManager { name in
            if name == "skip.txt" { return nil }
            return name == "slow.bin" || name == "broken.bin" ? existing : folder.appendingPathComponent(name)
        }
        let page = DownloadTestPage(manager: manager, url: URL(string: "http://127.0.0.1:\(port)/download-page")!)
        defer { page.close(); manager.cancelAll() }
        let view = try XCTUnwrap(page.view)
        try await waitUntil { page.session.pageTitle == "Downloads fixture" }
        _ = try await view.evaluateJavaScript("document.getElementById('slow').click();true")
        try await waitUntil { manager.items.first?.received ?? 0 > 0 }
        _ = try await view.evaluateJavaScript("document.getElementById('attachment').click();true")
        try await waitUntil { manager.items.count == 2 && manager.items.last?.state == .finished }
        let slow = try XCTUnwrap(manager.items.first)
        manager.cancel(slow.id)
        try await waitUntil { !manager.hasActiveDownloads }
        XCTAssertEqual(slow.state, .cancelled)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
        _ = try await view.evaluateJavaScript("document.getElementById('skip').click();true")
        try await waitUntil { manager.items.count == 3 && manager.items.last?.state == .cancelled }
        _ = try await view.evaluateJavaScript("document.getElementById('broken').click();true")
        try await waitUntil { manager.items.count == 4 && manager.items.last?.state == .failed }
        XCTAssertNotNil(manager.items.last?.error)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
        _ = try await view.evaluateJavaScript("document.getElementById('slow').click();true")
        try await waitUntil { manager.items.count == 5 && manager.items.last?.state == .downloading && manager.items.last?.received ?? 0 > 0 }
        await manager.stopForTermination()
        try await waitUntil { !manager.hasPendingWork }
        XCTAssertEqual(manager.items.last?.state, .cancelled)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
    }

    func testNativeContextMenusDownloadImagesAndLinkedFilesInMainAndSiteWindows() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        var choices = 0
        let manager = DownloadManager { name in choices += 1; return folder.appendingPathComponent("\(choices)-\(name)") }
        let page = DownloadTestPage(manager: manager, url: URL(string: "http://127.0.0.1:\(port)/image-page")!)
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        PreviewWindowAppearance.apply(to: main)
        let source = try XCTUnwrap(page.view)
        main.contentView = source
        main.center()
        main.makeKeyAndOrderFront(nil)
        page.session.windowRegistry.register(main, session: page.session)
        defer { page.session.windowRegistry.closeAll(); page.close(); manager.cancelAll() }
        try await waitUntil { page.session.pageTitle == "Image context fixture" }
        _ = try await source.evaluateJavaScript("window.contextSentinel='kept';window.open('/image-page','image-child');true")
        try await waitUntil { page.session.windowRegistry.webWindows(openedBy: page.session.windowID).count == 1 }
        let child = try XCTUnwrap(page.session.windowRegistry.webWindows(openedBy: page.session.windowID).values.first)
        for (index, view) in [source, child.webView].enumerated() {
            try await waitUntil { (try? await view.evaluateJavaScript("document.getElementById('photo')?.naturalWidth > 0")) as? Bool == true }
            let beforeURL = view.url
            try await selectNativeContextMenuItem(tag: Int(WebMenuItemTagDownloadImageToDisk), point: NSPoint(x: 60, y: 60), in: view)
            try await waitUntil { manager.items.count == index + 1 && manager.items.last?.state == .finished }
            let saved = try XCTUnwrap(manager.items.last?.destination)
            XCTAssertEqual(try Data(contentsOf: saved), PopupHTTPFixture.picture)
            XCTAssertTrue(saved.lastPathComponent.hasSuffix("photo.png"))
            XCTAssertEqual(view.url, beforeURL)
        }
        try await selectNativeContextMenuItem(tag: Int(WebMenuItemTagDownloadLinkToDisk), point: NSPoint(x: 80, y: 210), in: source)
        try await waitUntil { manager.items.count == 3 && manager.items.last?.state == .finished }
        let linked = try XCTUnwrap(manager.items.last?.destination)
        XCTAssertEqual(try String(contentsOf: linked, encoding: .utf8), "attachment payload")
        let sentinel = try await source.evaluateJavaScript("window.contextSentinel") as? String
        XCTAssertEqual(sentinel, "kept")
    }

    private func selectNativeContextMenuItem(tag: Int, point: NSPoint, in view: WKWebView) async throws {
        let window = try XCTUnwrap(view.window)
        let originalPointer = CGEvent(source: nil)?.location
        defer { if let originalPointer { CGWarpMouseCursorPosition(originalPointer) } }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        window.contentView?.layoutSubtreeIfNeeded()
        var selected = false
        var openedMenu: NSMenu?
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu,
                      let index = menu.items.firstIndex(where: { $0.tag == tag }) else { return }
                openedMenu = menu
                let action = Timer(timeInterval: 0.05, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        menu.performActionForItem(at: index)
                        selected = true
                        menu.cancelTrackingWithoutAnimation()
                    }
                }
                RunLoop.main.add(action, forMode: .common)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer); openedMenu?.cancelTrackingWithoutAnimation() }
        let location = view.convert(point, to: nil)
        let screenPoint = window.convertPoint(toScreen: location)
        CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenPoint.y))
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0))
            NSApp.postEvent(event, atStart: true)
            while let queued = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(queued)
            }
        }
        try await waitUntil { selected }
        XCTAssertTrue(selected, "The actual WebKit context-menu command must be selected")
    }

    func testNativeDownloadSavePanelSuggestsNameAndCancelsWithoutSaving() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let manager = DownloadManager()
        let page = DownloadTestPage(manager: manager, url: URL(string: "http://127.0.0.1:\(port)/download-page")!)
        defer { page.close(); manager.cancelAll() }
        try await waitUntil { page.session.pageTitle == "Downloads fixture" }
        _ = try await page.view?.evaluateJavaScript("document.getElementById('attachment').click();true")
        try await waitUntil { NSApp.windows.contains { $0 is NSSavePanel && $0.isVisible } }
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is NSSavePanel && $0.isVisible } as? NSSavePanel)
        XCTAssertEqual(panel.nameFieldStringValue, "report.txt")
        page.close()
        panel.cancel(nil)
        try await waitUntil { manager.items.last?.state == .cancelled && !manager.hasActiveDownloads }
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
        XCTFail("WebKit fixture did not complete within 10 seconds (app active: \(NSApp.isActive), activation policy: \(NSApp.activationPolicy().rawValue))", file: file, line: line)
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

@MainActor
final class WebUploadTests: XCTestCase {
    func testPickerUploadsSingleAndMultipleFilesInMainAndPopupWindows() async throws {
        let server = try UploadHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/page")!)
        defer { page.close() }
        try await waitUntil { (try? await page.view.evaluateJavaScript("document.title")) as? String == "Upload fixture" }
        _ = try await page.view.evaluateJavaScript("window.open('/page','upload-child');true")
        try await waitUntil { page.coordinator.popupWindows.values.first?.session.pageTitle == "Upload fixture" }
        let popup = try XCTUnwrap(page.coordinator.popupWindows.values.first)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Upload.\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = folder.appendingPathComponent("first file.txt")
        let two = folder.appendingPathComponent("second.bin")
        let firstBytes = Data("single upload payload".utf8)
        let secondBytes = Data([0, 255, 42, 13, 10, 128])
        try firstBytes.write(to: one)
        try secondBytes.write(to: two)
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "upload_session", .value: "fixture"])!
        await page.view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        for (view, coordinator) in [(page.view, page.coordinator), (popup.webView, popup.coordinator)] {
            var panels: [UploadTestPanel] = []
            coordinator.makeFileUploadPanel = {
                let panel = UploadTestPanel()
                panel.selection = panels.isEmpty ? [one] : [one, two]
                panel.automaticResponse = .OK
                panels.append(panel)
                return panel
            }
            _ = try await view.evaluateJavaScript("document.getElementById('single').click();true")
            try await waitUntil { (try? await view.evaluateJavaScript("document.getElementById('single').files.length")) as? Int == 1 }
            XCTAssertFalse(panels[0].allowsMultipleSelection)
            XCTAssertTrue(panels[0].canChooseFiles)
            XCTAssertFalse(panels[0].canChooseDirectories)
            XCTAssertTrue(panels[0].message.contains("http://127.0.0.1:\(port)"))
            let bytes = try await view.callAsyncJavaScript("return Array.from(new Uint8Array(await document.getElementById('single').files[0].arrayBuffer()))", in: nil, contentWorld: .page) as? [UInt8]
            XCTAssertEqual(bytes, Array(firstBytes))
            _ = try await view.evaluateJavaScript("document.getElementById('multiple').click();true")
            try await waitUntil { (try? await view.evaluateJavaScript("document.getElementById('multiple').files.length")) as? Int == 2 }
            XCTAssertTrue(panels[1].allowsMultipleSelection)
            let result = try await view.callAsyncJavaScript("return await sendUpload(document.getElementById('multiple').files)", in: nil, contentWorld: .page) as? String
            XCTAssertEqual(result, "ok")
            XCTAssertEqual(view.url?.path, "/page")
            XCTAssertEqual(page.session.originalURL?.path, "/page")
        }
        XCTAssertEqual(server.uploads.count, 2)
        for upload in server.uploads {
            XCTAssertTrue(upload.headers.lowercased().contains("multipart/form-data; boundary="))
            XCTAssertTrue(upload.headers.contains("upload_session=fixture"))
            XCTAssertNotNil(upload.body.range(of: firstBytes))
            XCTAssertNotNil(upload.body.range(of: secondBytes))
        }
    }

    func testFolderSelectionAndCancellationUseWebKitFileLists() async throws {
        let server = try UploadHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/page")!)
        defer { page.close() }
        try await waitUntil { (try? await page.view.evaluateJavaScript("document.title")) as? String == "Upload fixture" }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UploadFolder.\(UUID())")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("one".utf8).write(to: folder.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: folder.appendingPathComponent("nested/two.txt"))
        let chooser = UploadTestPanel()
        chooser.selection = [folder]
        chooser.automaticResponse = .OK
        page.coordinator.makeFileUploadPanel = { chooser }
        _ = try await page.view.evaluateJavaScript("document.getElementById('folder').click();true")
        try await waitUntil { (try? await page.view.evaluateJavaScript("document.getElementById('folder').files.length")) as? Int == 2 }
        XCTAssertTrue(chooser.canChooseDirectories)
        XCTAssertFalse(chooser.canChooseFiles)
        let paths = try await page.view.evaluateJavaScript("Array.from(document.getElementById('folder').files,f=>f.webkitRelativePath).sort()") as? [String]
        XCTAssertEqual(paths, ["\(folder.lastPathComponent)/nested/two.txt", "\(folder.lastPathComponent)/one.txt"])
        let cancel = UploadTestPanel()
        cancel.automaticResponse = .cancel
        page.coordinator.makeFileUploadPanel = { cancel }
        _ = try await page.view.evaluateJavaScript("document.getElementById('single').click();true")
        try await waitUntil { cancel.presented }
        let count = try await page.view.evaluateJavaScript("document.getElementById('single').files.length") as? Int
        XCTAssertEqual(count, 0)
        XCTAssertTrue(server.uploads.isEmpty)
    }

    func testNativeUploadSheetCancelsOnNavigationAndWindowClose() async throws {
        let server = try UploadHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/page")!)
        defer { page.close() }
        try await waitUntil { (try? await page.view.evaluateJavaScript("document.title")) as? String == "Upload fixture" }
        _ = try await page.view.evaluateJavaScript("document.getElementById('multiple').click();true")
        try await waitUntil { page.window.attachedSheet is NSOpenPanel }
        let first = try XCTUnwrap(page.window.attachedSheet as? NSOpenPanel)
        XCTAssertTrue(first.allowsMultipleSelection)
        XCTAssertTrue(first.message.contains("http://127.0.0.1:\(port)"))
        page.view.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/next")!))
        try await waitUntil { page.window.attachedSheet == nil && page.view.url?.path == "/next" }
        _ = try await page.view.evaluateJavaScript("document.getElementById('single').click();true")
        try await waitUntil { page.window.attachedSheet is NSOpenPanel }
        let second = try XCTUnwrap(page.window.attachedSheet)
        page.window.close()
        try await waitUntil { second.sheetParent == nil }
        XCTAssertTrue(server.uploads.isEmpty)
    }

    func testNativeFileDropReachesInputAndDropZoneInMainAndPopup() async throws {
        let server = try UploadHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/page")!)
        defer { page.close() }
        try await waitUntil { (try? await page.view.evaluateJavaScript("document.title")) as? String == "Upload fixture" }
        _ = try await page.view.evaluateJavaScript("window.open('/page','drop-child');true")
        try await waitUntil { page.coordinator.popupWindows.values.first?.session.pageTitle == "Upload fixture" }
        let popup = try XCTUnwrap(page.coordinator.popupWindows.values.first)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Drop.\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = folder.appendingPathComponent("drop-one.txt")
        let two = folder.appendingPathComponent("drop-two.txt")
        try Data("first dragged payload".utf8).write(to: one)
        try Data("second dragged payload".utf8).write(to: two)
        for view in [page.view, popup.webView] {
            try await drop([one], onto: "single", in: view)
            try await waitUntil { (try? await view.evaluateJavaScript("document.getElementById('single').files.length")) as? Int == 1 }
            try await drop([one, two], onto: "dropzone", in: view)
            try await waitUntil { (try? await view.evaluateJavaScript("window.droppedFiles?.length")) as? Int == 2 }
            let text = try await view.callAsyncJavaScript("return await droppedFiles[1].text()", in: nil, contentWorld: .page) as? String
            XCTAssertEqual(text, "second dragged payload")
            let result = try await view.callAsyncJavaScript("return await sendUpload(droppedFiles)", in: nil, contentWorld: .page) as? String
            XCTAssertEqual(result, "ok")
            XCTAssertEqual(view.url?.path, "/page")
        }
        XCTAssertEqual(server.uploads.count, 2)
    }

    func testLocalFileNavigationIsNotHandedToAnotherApplication() async throws {
        let server = try UploadHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/page")!)
        defer { page.close() }
        try await waitUntil { (try? await page.view.evaluateJavaScript("document.title")) as? String == "Upload fixture" }
        var opened: [URL] = []
        page.coordinator.openExternalURL = { opened.append($0) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID()).txt")
        try Data("local file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let probe = UploadPolicyProbe(coordinator: page.coordinator)
        page.view.navigationDelegate = probe
        page.view.loadFileURL(file, allowingReadAccessTo: file)
        try await waitUntil { probe.localFileDecision != nil }
        XCTAssertEqual(probe.localFileDecision, .cancel)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertNotEqual(page.view.url, file)
    }

    private func drop(_ urls: [URL], onto id: String, in view: WKWebView) async throws {
        let window = try XCTUnwrap(view.window)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let value = try await view.evaluateJavaScript("(()=>{const r=document.getElementById('\(id)').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
        let position = try XCTUnwrap(value as? [Double])
        let point = NSPoint(x: position[0], y: position[1])
        let windowPoint = view.convert(point, to: nil)
        var receiver = view.hitTest(view.convert(point, to: view.superview))
        while let candidate = receiver, candidate.registeredDraggedTypes.isEmpty { receiver = candidate.superview }
        let target = try XCTUnwrap(receiver)
        let info = UploadDraggingInfo(urls: urls, window: window, point: windowPoint)
        _ = target.draggingEntered(info)
        for _ in 0..<40 {
            if !target.draggingUpdated(info).isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(target.prepareForDragOperation(info))
        XCTAssertTrue(target.performDragOperation(info))
        target.concludeDragOperation(info)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Upload fixture did not complete within 10 seconds")
    }
}

@MainActor
private final class UploadPolicyProbe: NSObject, WKNavigationDelegate {
    let coordinator: WebPreview.Coordinator
    var localFileDecision: WKNavigationActionPolicy?
    init(coordinator: WebPreview.Coordinator) { self.coordinator = coordinator }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        coordinator.webView(webView, decidePolicyFor: navigationAction) { policy in
            if navigationAction.request.url?.isFileURL == true { self.localFileDecision = policy }
            decisionHandler(policy)
        }
    }
}

@MainActor
private final class UploadTestPage {
    let session: PreviewSession
    let view: WKWebView
    let coordinator: WebPreview.Coordinator
    let window: NSWindow
    private let suite = "UploadPage.\(UUID())"
    private let defaults: UserDefaults

    init(url: URL, configure: (WKWebViewConfiguration) -> Void = { _ in }) {
        defaults = UserDefaults(suiteName: suite)!
        let data = SiteDataService(defaults: defaults, persistentStore: .nonPersistent())
        session = PreviewSession(adBlockService: AdBlockService(defaults: defaults, automaticUpdates: false), siteData: data)
        session.load(url)
        let configuration = WebPreview.configuration(websiteDataStore: session.websiteDataStore)
        configure(configuration)
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        coordinator = WebPreview.Coordinator(session: session)
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        coordinator.startObserving(view)
        session.attach(view)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        PreviewWindowAppearance.apply(to: window)
        let host = NSHostingController(rootView: PreviewPageView(session: session, existingWebView: view))
        host.sizingOptions = []
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
        coordinator.cancelFileUpload()
        session.windowRegistry.closeAll()
        window.close()
        session.endSession()
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class CursorRectFixtureHost: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }
}

@MainActor
private final class UploadTestPanel: NSOpenPanel {
    var selection: [URL] = []
    var automaticResponse: NSApplication.ModalResponse?
    var presented = false
    private var reply: ((NSApplication.ModalResponse) -> Void)?
    override var urls: [URL] { selection }
    override func beginSheetModal(for window: NSWindow, completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
        presented = true
        reply = handler
        if let automaticResponse { DispatchQueue.main.async { [weak self] in self?.finish(automaticResponse) } }
    }
    override func cancel(_ sender: Any?) { finish(.cancel) }
    private func finish(_ response: NSApplication.ModalResponse) {
        let handler = reply
        reply = nil
        handler?(response)
    }
}

@MainActor
private final class UploadDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingLocation: NSPoint
    let draggingSourceOperationMask: NSDragOperation = .copy
    let draggingSource: Any? = nil
    let draggingSequenceNumber = Int.random(in: 1000...99999)
    let draggedImageLocation = NSPoint.zero
    let draggedImage: NSImage? = nil
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    private let urls: [URL]

    init(urls: [URL], window: NSWindow, point: NSPoint) {
        self.urls = urls
        draggingDestinationWindow = window
        draggingLocation = point
        super.init()
        draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop: ObjCBool = false
        for (index, url) in urls.enumerated() {
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: draggingLocation.x, y: draggingLocation.y, width: 20, height: 20), contents: NSImage(size: NSSize(width: 20, height: 20)))
            block(item, index, &stop)
            if stop.boolValue { break }
        }
    }
}

private final class UploadHTTPFixture: @unchecked Sendable {
    struct Upload { let headers: String; let body: Data }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Linklet.UploadHTTPFixture", qos: .utility)
    private let lock = NSLock()
    private var received: [Upload] = []
    var uploads: [Upload] { lock.lock(); defer { lock.unlock() }; return received }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = self.listener.port?.rawValue else { return }
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: port)
                case .failed(let error): continuation.resume(throwing: error)
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var data = data; data.append(bytes ?? Data())
            guard data.count < 2_097_152 else { connection.cancel(); return }
            guard let split = data.range(of: Data("\r\n\r\n".utf8)), let headers = String(data: data[..<split.lowerBound], encoding: .utf8) else {
                if complete { connection.cancel() } else { self.receive(connection, data: data) }; return
            }
            let length = headers.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = data[split.upperBound...]
            guard body.count >= length else { self.receive(connection, data: data); return }
            let upload = headers.hasPrefix("POST /upload ")
            if upload { self.lock.lock(); self.received.append(Upload(headers: headers, body: Data(body.prefix(length)))); self.lock.unlock() }
            let payload = Data((upload ? "ok" : Self.html).utf8)
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(upload ? "text/plain" : "text/html"); charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(payload)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    private static let html = """
    <!doctype html><meta charset="utf-8"><title>Upload fixture</title>
    <style>body{font:16px system-ui;margin:24px}input{display:block;width:350px;height:40px;margin:10px 0}#dropzone{width:350px;height:100px;border:3px dashed #777;margin-top:24px}</style>
    <input id="single" type="file"><input id="multiple" type="file" multiple><input id="folder" type="file" multiple webkitdirectory>
    <div id="dropzone">Drop files here</div>
    <script>
    let zone=document.getElementById('dropzone');
    zone.addEventListener('dragover',e=>e.preventDefault());
    zone.addEventListener('drop',e=>{e.preventDefault();window.droppedFiles=Array.from(e.dataTransfer.files)});
    async function sendUpload(files){let body=new FormData();for(let file of files)body.append('files',file,file.name);return await (await fetch('/upload',{method:'POST',body})).text()}
    </script>
    """
}

@MainActor
private final class DownloadTestPage {
    let session: PreviewSession
    var view: WKWebView?
    private var coordinator: WebPreview.Coordinator?
    private let suite = "DownloadPage.\(UUID())"
    private let defaults: UserDefaults

    init(manager: DownloadManager, url: URL) {
        defaults = UserDefaults(suiteName: suite)!
        let data = SiteDataService(defaults: defaults, persistentStore: .nonPersistent())
        session = PreviewSession(adBlockService: AdBlockService(defaults: defaults, automaticUpdates: false),
                                 siteData: data, windowRegistry: BrowserWindowRegistry(downloads: manager))
        session.load(url)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                            configuration: WebPreview.configuration(websiteDataStore: session.websiteDataStore))
        let observer = WebPreview.Coordinator(session: session)
        web.navigationDelegate = observer
        web.uiDelegate = observer
        observer.startObserving(web)
        coordinator = observer
        view = web
        session.attach(web)
    }

    func close() {
        session.endSession()
        coordinator = nil
        view = nil
        defaults.removePersistentDomain(forName: suite)
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
    static let picture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Linklet.PopupHTTPFixture", qos: .utility)
    private let lock = NSLock()
    private var receivedPosts = 0
    private var receivedBody = ""
    private var receivedPageRequests: [String] = []
    var pageRequests: [String] { lock.lock(); defer { lock.unlock() }; return receivedPageRequests }
    private var receivedDownloadRequests: [String] = []
    var downloadRequests: [String] { lock.lock(); defer { lock.unlock() }; return receivedDownloadRequests }
    private var iconData: Data?
    private let conventionalIcon: Data?
    private var iconVersion = 1
    private var responsesNotModified = 0
    private var recoveryEnabled = false
    func enableRecovery() { lock.lock(); recoveryEnabled = true; lock.unlock() }
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
        let canRecover = recoveryEnabled
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
        if firstLine.hasPrefix("GET /recovery ") {
            if !canRecover { connection.cancel(); return }
            status = "200 OK"
            html = "<title>Recovered</title><p>The website is available again.</p>"
        } else if firstLine.hasPrefix("GET /history-start ") {
            status = "302 Found"
            extraHeaders = "Location: /history-reader\r\n"
            html = ""
        } else if firstLine.hasPrefix("GET /history-reader") {
            status = "200 OK"
            html = """
            <!doctype html><meta charset="utf-8"><title>Reader</title>
            <style>body{margin:0;font:18px system-ui}main{height:6000px;background:linear-gradient(white,#b5cef3)}p{margin:0;padding:24px}</style>
            <main><p>History and scroll restoration fixture</p><div style="padding-top:1200px">Last reading position</div></main>
            """
        } else if firstLine.hasPrefix("GET /http-error ") {
            status = "403 Forbidden"
            html = "<title>Access denied by website</title><p>The website's own error document.</p>"
        } else if firstLine.hasPrefix("GET /photo.png ") {
            let bytes = Self.picture
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(bytes)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            return
        } else if firstLine.hasPrefix("GET /image-page ") {
            status = "200 OK"
            html = "<title>Image context fixture</title><img id='photo' src='/photo.png' style='position:absolute;left:24px;top:24px;width:160px;height:120px'><a href='/attachment' style='position:absolute;left:24px;top:200px'>Download linked file</a>"
        } else if firstLine.hasPrefix("GET /download-page ") {
            status = "200 OK"
            html = """
            <title>Downloads fixture</title><a id='attachment' href='/attachment'>Attachment</a>
            <a id='inline' download='inline.txt' href='/inline'>Inline</a>
            <a id='slow' href='/slow'>Slow</a><a id='skip' href='/skip'>Skip</a><a id='broken' href='/broken'>Broken</a>
            <form id='export' method='POST' action='/export'><input name='token' value='fixture'></form>
            <script>
            function saveBlob(){let a=document.createElement('a');a.href=URL.createObjectURL(new Blob(['blob payload'],{type:'text/plain'}));a.download='blob.txt';a.click()}
            function saveData(){let a=document.createElement('a');a.href='data:text/plain,data%20payload';a.download='data.txt';a.click()}
            </script>
            """
        } else if ["GET /attachment ", "GET /inline ", "GET /slow ", "GET /skip ", "GET /broken ", "POST /export "].contains(where: firstLine.hasPrefix) {
            lock.lock(); receivedDownloadRequests.append(firstLine); lock.unlock()
            let isExport = firstLine.hasPrefix("POST /export ")
            let authenticated = headers.contains("login=fixture")
            let slow = firstLine.hasPrefix("GET /slow ")
            let broken = firstLine.hasPrefix("GET /broken ")
            let skip = firstLine.hasPrefix("GET /skip ")
            let inline = firstLine.hasPrefix("GET /inline ")
            let filename = slow ? "slow.bin" : (broken ? "broken.bin" : (skip ? "skip.txt" : "report.txt"))
            let payload = isExport ? (authenticated ? "authorized:\(body)" : "unauthorized") : (inline ? "inline payload" : "attachment payload")
            let size = slow ? 524_288 : (broken ? 4096 : payload.utf8.count)
            let contentType = slow || broken ? "application/octet-stream" : "text/plain"
            let disposition = inline ? "inline" : "attachment; filename=\"\(filename)\""
            let code = isExport && !authenticated ? "401 Unauthorized" : "200 OK"
            let header = "HTTP/1.1 \(code)\r\nContent-Type: \(contentType)\r\nContent-Disposition: \(disposition)\r\nContent-Length: \(size)\r\nConnection: close\r\n\r\n"
            if slow {
                connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                    guard error == nil else { connection.cancel(); return }
                    self?.stream(connection, remaining: size)
                })
            } else {
                connection.send(content: Data((header + payload).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
            return
        } else if firstLine.hasPrefix("POST /authorize ") {
            lock.lock(); receivedPosts += 1; receivedBody = body; lock.unlock()
            status = "302 Found"
            extraHeaders = "Location: http://localhost:\(port)/callback\r\nSet-Cookie: login=fixture; Path=/; SameSite=Lax\r\n"
            html = ""
        } else if firstLine.hasPrefix("GET /find-highlight ") {
            status = "200 OK"
            extraHeaders = "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n"
            html = """
            <!doctype html><html lang="ru"><meta charset="utf-8"><title>Выделение текста</title>
            <style>:root{color-scheme:light dark}body{font:17px -apple-system;margin:0;padding:64px 40px}h1{font-size:52px;font-weight:400;margin:0 0 42px}p{line-height:1.7}</style>
            <h1 id="word">Выделители</h1><p>Текст остаётся на своём месте, пока правая граница следует за запросом.</p>
            <input id="draft" value="Черновик"><div style="height:1200px"></div><p>Выделители внизу страницы</p></html>
            """
        } else if firstLine.hasPrefix("GET /find-frame ") {
            status = "200 OK"
            html = "<title>Find frame</title><p>needle inside a cross-origin frame</p>"
        } else if firstLine.hasPrefix("GET /find ") {
            status = "200 OK"
            html = """
            <!doctype html><meta charset="utf-8"><title>Find fixture</title>
            <style>body{font:16px -apple-system;padding:24px}input{display:block;margin:20px 0}</style>
            <h1>Find on page</h1><p>Needle and ne<b>ed</b>le.</p><p>NEEDLE</p>
            <p hidden>needle is hidden</p><input id="draft" value="unchanged">
            <iframe src="http://localhost:\(port)/find-frame"></iframe>
            <div style="height:1400px"></div><p id="last-match">needle at the end</p>
            """
        } else if firstLine.hasPrefix("GET /cursor ") {
            status = "200 OK"
            html = """
            <title>Cursor fixture</title><style>
            body{margin:0}#entry{position:absolute;left:30px;top:30px;width:220px;height:40px}
            #map{position:absolute;left:30px;top:110px;width:300px;height:100px;cursor:grab;background:#ddd;user-select:none}
            #plain{position:absolute;left:30px;top:240px;width:300px;height:100px;cursor:default;background:#eee}
            </style><input id="entry"><div id="map">Drag map</div><div id="plain">Normal pointer</div><script>
            window.lastMove='';window.released='no';
            document.addEventListener('mousemove',e=>window.lastMove=e.target.id);
            const map=document.getElementById('map');
            map.addEventListener('mousedown',()=>map.style.cursor='grabbing');
            document.addEventListener('mouseup',()=>{map.style.cursor='grab';window.released='yes'});
            </script>
            """
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

    private func stream(_ connection: NWConnection, remaining: Int) {
        guard remaining > 0 else { connection.cancel(); return }
        let count = min(8192, remaining)
        connection.send(content: Data(repeating: 120, count: count), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + 0.03) { self.stream(connection, remaining: remaining - count) }
        })
    }
}

private struct SidebarGlassTestBackdrop: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.04, green: 0.16, blue: 0.44)))
            for index in -8...18 {
                let x = CGFloat(index) * 55
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: 0))
                stripe.addLine(to: CGPoint(x: x + 22, y: 0))
                stripe.addLine(to: CGPoint(x: x + size.height * 0.4 + 22, y: size.height))
                stripe.addLine(to: CGPoint(x: x + size.height * 0.4, y: size.height))
                stripe.closeSubpath()
                context.fill(stripe, with: .color(Color(red: 0.08, green: 0.31, blue: 0.70)))
            }
        }
    }
}

private struct SidebarSizeProbe: NSViewRepresentable {
    @Environment(\.sidebarRowSize) private var rowSize
    let report: (SidebarRowSize) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { report(rowSize) }
}

@MainActor
final class SiteMediaPermissionTests: XCTestCase {
    @available(macOS 27.0, *)
    func testNativeProviderDeliversPositionThroughRealWebKitAndStopsOnRevocation() async throws {
        let server = try PopupHTTPFixture(); let port = try await server.start()
        defer { server.stop() }
        let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 37.3317, longitude: -122.0301),
                             altitude: 0, horizontalAccuracy: 20, verticalAccuracy: -1, timestamp: Date())
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/site")!) { configuration in
            configuration.processPool = WKProcessPool()
            XCTAssertTrue(NativeLocationProvider.install(in: configuration.processPool))
            NativeLocationProvider.useTestLocation(fix, in: configuration.processPool)
        }
        defer { page.close() }
        let pool = page.view.configuration.processPool
        let service = page.session.siteData.mediaPermissions
        service.systemStatus = { _ in .authorized }
        service.requestSystemAccess = { _, _ in XCTFail("Synthetic location must not request physical location") }
        service.presentAlert = { _, _, reply in reply(.alertFirstButtonReturn) }
        try await waitUntil { page.session.pageTitle == "Original site" && !page.session.isLoading }
        _ = try await page.view.evaluateJavaScript("window.geoResult='pending'; window.geoWatch=navigator.geolocation.watchPosition(p=>{window.geoPosition=[p.coords.latitude,p.coords.longitude,p.coords.accuracy,p.timestamp];window.geoResult='granted'},e=>window.geoResult='error:'+e.code,{timeout:5000,maximumAge:0,enableHighAccuracy:true});true")
        try await waitUntil { ((try? await page.view.evaluateJavaScript("window.geoResult")) as? String) != "pending" }
        let result = try await page.view.evaluateJavaScript("window.geoResult") as? String
        XCTAssertEqual(result, "granted", "A successful permission callback alone does not provide coordinates on macOS")
        guard result == "granted" else { return }
        let positionValue = try await page.view.evaluateJavaScript("window.geoPosition") as? [Double]
        let position = try XCTUnwrap(positionValue)
        XCTAssertEqual(position[0], fix.coordinate.latitude, accuracy: 0.000001)
        XCTAssertEqual(position[1], fix.coordinate.longitude, accuracy: 0.000001)
        XCTAssertEqual(position[2], 20)
        XCTAssertEqual(position[3], fix.timestamp.timeIntervalSince1970 * 1000, accuracy: 1)
        XCTAssertTrue(NativeLocationProvider.isUpdating(in: pool))
        let rule = try XCTUnwrap(service.rules.first)
        service.setChoice(.deny, device: .location, ruleID: rule.id)
        try await waitUntil { !NativeLocationProvider.isUpdating(in: pool) && !page.session.isLoading }
        XCTAssertTrue(page.session.webView === page.view)
        _ = try await page.view.evaluateJavaScript("window.geoResult='pending';navigator.geolocation.getCurrentPosition(()=>window.geoResult='unexpected',e=>window.geoResult=String(e.code),{timeout:5000});true")
        try await waitUntil { ((try? await page.view.evaluateJavaScript("window.geoResult")) as? String) != "pending" }
        let denied = try await page.view.evaluateJavaScript("window.geoResult") as? String
        XCTAssertEqual(denied, "1")
        XCTAssertFalse(NativeLocationProvider.isUpdating(in: pool))
    }

    func testLocationConsentIsIndependentAndRevocationReloadsSameWebView() async throws {
        let server = try PopupHTTPFixture(); let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/site")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Original site" && !page.session.isLoading }
        let service = page.session.siteData.mediaPermissions
        service.systemStatus = { _ in .notDetermined }
        service.requestSystemAccess = { _, _ in XCTFail("WebKit, not Linklet, owns the Core Location system request") }
        var alertCount = 0
        service.presentAlert = { alert, _, reply in
            alertCount += 1
            XCTAssertTrue(alert.messageText.contains(L("your location")))
            alert.suppressionButton?.state = .on
            reply(.alertFirstButtonReturn)
        }
        let origin = try XCTUnwrap(MediaSiteOrigin(url: page.view.url!))
        let context = SiteMediaRule(top: origin, requester: origin)
        var result: WKPermissionDecision?
        service.request(in: page.view, context: context, devices: [.location]) { result = $0 }
        XCTAssertEqual(result, .grant)
        XCTAssertEqual(service.rules.first?.location, .allow)
        XCTAssertEqual(service.rules.first?.camera, .ask)
        XCTAssertEqual(service.rules.first?.microphone, .ask)
        XCTAssertTrue(service.hasPendingOrActiveCapture)
        let rule = try XCTUnwrap(service.rules.first)
        _ = try await page.view.evaluateJavaScript("window.locationDocumentToken = 'before-revoke'")
        service.setChoice(.deny, device: .location, ruleID: rule.id)
        try await waitUntil { ((try? await page.view.evaluateJavaScript("typeof window.locationDocumentToken")) as? String) == "undefined" && !page.session.isLoading }
        XCTAssertTrue(page.session.webView === page.view)
        XCTAssertEqual(page.session.originalURL, origin.url.appendingPathComponent("site"))
        result = nil
        service.request(in: page.view, context: context, devices: [.location]) { result = $0 }
        XCTAssertEqual(result, .deny)
        XCTAssertEqual(alertCount, 1)
        page.close()
        XCTAssertTrue(service.rules.isEmpty)
    }

    func testOldMediaRulesDecodeWithLocationStillAsking() throws {
        let old = Data(#"[{"top":{"address":"https://example.org"},"requester":{"address":"https://example.org"},"camera":"allow","microphone":"deny"}]"#.utf8)
        let rules = try JSONDecoder().decode([SiteMediaRule].self, from: old)
        XCTAssertEqual(rules.first?.camera, .allow)
        XCTAssertEqual(rules.first?.microphone, .deny)
        XCTAssertEqual(rules.first?.location, .ask)
        let decoded = try JSONDecoder().decode([SiteMediaRule].self, from: JSONEncoder().encode(rules))
        XCTAssertEqual(decoded, rules)
    }

    @available(macOS 27.0, *)
    func testRealWebKitGeolocationDenialUsesNativeSiteConsentWithoutCoordinates() async throws {
        let server = try PopupHTTPFixture(); let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/site")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Original site" && !page.session.isLoading }
        let service = page.session.siteData.mediaPermissions
        service.systemStatus = { _ in .authorized }
        var prompts = 0
        service.presentAlert = { _, _, reply in prompts += 1; reply(.alertSecondButtonReturn) }
        _ = try await page.view.evaluateJavaScript("window.geoResult='pending'; navigator.geolocation.getCurrentPosition(()=>window.geoResult='unexpected-location',e=>window.geoResult=String(e.code),{timeout:5000});true")
        try await waitUntil { ((try? await page.view.evaluateJavaScript("window.geoResult")) as? String) != "pending" }
        let result = try await page.view.evaluateJavaScript("window.geoResult") as? String
        XCTAssertEqual(result, "1")
        XCTAssertEqual(prompts, 1, "The public macOS 27 geolocation delegate must request site consent")
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSLocationUsageDescription"))
    }

    func testAdGuardMenuToggleReloadsWithoutReplacingViewOrHistory() async throws {
        let server = try PopupHTTPFixture(); let port = try await server.start()
        defer { server.stop() }
        let original = URL(string: "http://127.0.0.1:\(port)/site")!
        let page = UploadTestPage(url: original)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Original site" && !page.session.isLoading }
        XCTAssertTrue(page.session.submitAddress("http://127.0.0.1:\(port)/destination", engine: .google))
        try await waitUntil { page.session.pageTitle == "Destination" && !page.session.isLoading }
        let backList = page.view.backForwardList.backList.map(\.url)
        let originalHandoff = page.session.originalURL
        let navigationID = page.session.navigationID
        let menu = NSMenu(); menu.addItem(withTitle: "Native download", action: nil, keyEquivalent: "")
        page.coordinator.appendAdGuardItem(to: menu, in: page.view)
        let item = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(item.title, L("Turn On AdGuard"))
        XCTAssertEqual(menu.items.first?.title, "Native download")
        _ = try await page.view.evaluateJavaScript("window.adGuardReloadToken = 'before'")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        await page.session.adBlockService.waitForPolicyUpdate()
        try await waitUntil { ((try? await page.view.evaluateJavaScript("typeof window.adGuardReloadToken")) as? String) == "undefined" && !page.session.isLoading }
        XCTAssertNil(page.session.adBlockService.errorMessage)
        XCTAssertTrue(page.session.webView === page.view)
        XCTAssertEqual(page.session.navigationID, navigationID)
        XCTAssertEqual(page.view.backForwardList.backList.map(\.url), backList)
        XCTAssertEqual(page.session.originalURL, originalHandoff)
        let updatedMenu = NSMenu(); page.coordinator.appendAdGuardItem(to: updatedMenu, in: page.view)
        XCTAssertEqual(updatedMenu.items.last?.title, L("Turn Off AdGuard"))
    }

    func testNativeWebKitContextMenuContainsAdGuardAction() async throws {
        let server = try PopupHTTPFixture(); let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/site")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Original site" && !page.session.isLoading }
        NSApp.activate(ignoringOtherApps: true)
        page.window.makeKeyAndOrderFront(nil)
        var titles: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
            guard let menu = notification.object as? NSMenu else { return }
            titles = menu.items.map(\.title)
            DispatchQueue.main.async { menu.cancelTracking() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let location = page.view.convert(NSPoint(x: 200, y: 200), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: page.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                                                 windowNumber: page.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(down, atStart: false); NSApp.postEvent(up, atStart: false)
        try await waitUntil { !titles.isEmpty }
        XCTAssertTrue(titles.contains(L("Turn On AdGuard")), "The actual WebKit native menu must invoke the customization delegate")
    }

    func testConcurrentCameraDenialDoesNotCancelMicrophoneConsent() async throws {
        let server = try PopupHTTPFixture(); let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/site")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Original site" && !page.session.isLoading }
        let service = page.session.siteData.mediaPermissions
        service.systemStatus = { _ in .authorized }
        let origin = try XCTUnwrap(MediaSiteOrigin(url: page.view.url!))
        let context = SiteMediaRule(top: origin, requester: origin)
        var prompts: [(NSAlert, (NSApplication.ModalResponse) -> Void)] = []
        service.presentAlert = { alert, _, reply in prompts.append((alert, reply)) }
        var camera: WKPermissionDecision?
        var microphone: WKPermissionDecision?
        service.request(in: page.view, context: context, devices: [.camera]) { camera = $0 }
        service.request(in: page.view, context: context, devices: [.microphone]) { microphone = $0 }
        XCTAssertEqual(prompts.count, 1)
        prompts[0].0.suppressionButton?.state = .on
        prompts[0].1(.alertSecondButtonReturn)
        XCTAssertEqual(camera, .deny)
        XCTAssertNil(microphone)
        XCTAssertEqual(prompts.count, 2)
        prompts[1].1(.alertFirstButtonReturn)
        XCTAssertEqual(microphone, .grant)
        XCTAssertEqual(service.rules.first?.camera, .deny)
        XCTAssertEqual(service.rules.first?.microphone, .ask, "A one-time grant does not become a remembered permission")
    }

    func testPrivateSiteChoicesAreSeparateAndExpireWithLastWindow() async throws {
        let server = try PopupHTTPFixture(); let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/site")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Original site" && !page.session.isLoading }
        let service = page.session.siteData.mediaPermissions
        service.systemStatus = { _ in .authorized }
        let origin = try XCTUnwrap(MediaSiteOrigin(url: page.view.url!))
        let context = SiteMediaRule(top: origin, requester: origin)
        var prompts = 0
        service.presentAlert = { alert, _, reply in
            prompts += 1
            XCTAssertTrue(alert.messageText.contains(origin.address))
            XCTAssertEqual(alert.suppressionButton?.title, L("Remember until all website windows close"))
            alert.suppressionButton?.state = .on
            reply(prompts == 1 ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        }
        var microphone: WKPermissionDecision?
        service.request(in: page.view, context: context, devices: [.microphone]) { microphone = $0 }
        XCTAssertEqual(microphone, .grant)
        XCTAssertEqual(service.rules.first?.microphone, .allow)
        XCTAssertEqual(service.rules.first?.camera, .ask)
        var camera: WKPermissionDecision?
        service.request(in: page.view, context: context, devices: [.camera]) { camera = $0 }
        XCTAssertEqual(camera, .deny)
        XCTAssertEqual(service.rules.first?.camera, .deny)
        XCTAssertEqual(service.rules.first?.microphone, .allow)
        XCTAssertFalse(service.persists)
        page.close()
        XCTAssertTrue(service.rules.isEmpty)
    }

    func testPendingNativeAndSystemDecisionsCannotGrantAfterNavigationOrClose() async throws {
        let server = try PopupHTTPFixture(); let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/site")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Original site" && !page.session.isLoading }
        let service = page.session.siteData.mediaPermissions
        let origin = try XCTUnwrap(MediaSiteOrigin(url: page.view.url!))
        let context = SiteMediaRule(top: origin, requester: origin)
        service.systemStatus = { _ in .notDetermined }
        var systemReply: ((Bool) -> Void)?
        service.requestSystemAccess = { _, reply in systemReply = reply }
        service.presentAlert = { _, _, reply in reply(.alertFirstButtonReturn) }
        var decisions: [WKPermissionDecision] = []
        service.request(in: page.view, context: context, devices: [.camera]) { decisions.append($0) }
        XCTAssertTrue(service.hasPendingOrActiveCapture, "The native system prompt must not cause preview auto-close")
        XCTAssertNotNil(systemReply)
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertTrue(page.session.submitAddress("http://127.0.0.1:\(port)/destination", engine: .google))
        try await waitUntil { page.session.pageTitle == "Destination" && !page.session.isLoading }
        XCTAssertEqual(decisions, [.deny])
        systemReply?(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(decisions, [.deny], "A late TCC answer cannot grant the new document")
        var siteReply: ((NSApplication.ModalResponse) -> Void)?
        service.presentAlert = { _, _, reply in siteReply = reply }
        service.systemStatus = { _ in .authorized }
        service.request(in: page.view, context: context, devices: [.microphone]) { decisions.append($0) }
        XCTAssertNotNil(siteReply)
        page.close()
        XCTAssertEqual(decisions, [.deny, .deny])
        siteReply?(.alertFirstButtonReturn)
        XCTAssertEqual(decisions, [.deny, .deny])
    }

    func testOriginScopePersistenceAndSystemDenialUseNativeControls() async throws {
        let server = try PopupHTTPFixture(); let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/site")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Original site" && !page.session.isLoading }
        let suite = "PersistentMediaRules.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SiteMediaPermissions(defaults: defaults, persists: true, systemStatus: { _ in .authorized })
        service.attach(page.view, session: page.session)
        defer { service.detach(page.view) }
        let top = try XCTUnwrap(MediaSiteOrigin(url: page.view.url!))
        let sdk = try XCTUnwrap(MediaSiteOrigin(url: URL(string: "https://camera.example")!))
        let context = SiteMediaRule(top: top, requester: sdk)
        service.presentAlert = { alert, _, reply in
            XCTAssertTrue(alert.messageText.contains(sdk.address))
            XCTAssertTrue(alert.informativeText.contains(top.address))
            alert.suppressionButton?.state = .on
            reply(.alertFirstButtonReturn)
        }
        var result: WKPermissionDecision?
        service.request(in: page.view, context: context, devices: [.camera]) { result = $0 }
        XCTAssertEqual(result, .grant)
        let stored = SiteMediaPermissions(defaults: defaults, persists: true)
        XCTAssertEqual(stored.rules.first?.camera, .allow)
        XCTAssertEqual(stored.rules.first?.top, top)
        XCTAssertEqual(stored.rules.first?.requester, sdk)
        let otherTop = try XCTUnwrap(MediaSiteOrigin(url: URL(string: "https://other.example")!))
        service.request(in: page.view, context: SiteMediaRule(top: otherTop, requester: sdk), devices: [.camera]) { result = $0 }
        XCTAssertEqual(result, .deny, "A site's grant cannot transfer to a different top-level origin")
        service.systemStatus = { _ in .denied }
        var notices = 0
        service.requestSystemAccess = { _, _ in XCTFail("Do not ask TCC again when macOS has already denied access") }
        service.presentAlert = { alert, _, reply in
            notices += 1
            XCTAssertEqual(alert.buttons.first?.title, L("Open System Settings…"))
            reply(.alertSecondButtonReturn)
        }
        service.request(in: page.view, context: context, devices: [.camera]) { result = $0 }
        XCTAssertEqual(result, .deny)
        service.request(in: page.view, context: context, devices: [.camera]) { result = $0 }
        XCTAssertEqual(notices, 1)
        service.remove(forDomain: "camera.example")
        XCTAssertTrue(service.rules.isEmpty)
        XCTAssertTrue(SiteMediaPermissions(defaults: defaults, persists: true).rules.isEmpty)
        service.setPersistence(false)
        XCTAssertNil(defaults.data(forKey: SiteMediaPermissions.storageKey))
        XCTAssertNil(MediaSiteOrigin(url: URL(string: "file:///tmp/site")!))
        XCTAssertFalse(MediaSiteOrigin(url: URL(string: "http://localhost.evil.example")!)!.isSecure)
        XCTAssertFalse(MediaSiteOrigin(url: URL(string: "http://127.evil.0.0.1")!)!.isSecure)
        XCTAssertFalse(MediaSiteOrigin(url: URL(string: "http://example.com")!)!.isSecure)
        XCTAssertEqual(MediaSiteOrigin(url: URL(string: "https://EXAMPLE.com:443/path?token=hidden")!)?.address, "https://example.com")
    }

    func testWebKitMockCaptureUsesRealDelegateAndRevokesDevicesIndependently() async throws {
        let server = try PopupHTTPFixture(); let port = try await server.start()
        defer { server.stop() }
        // Guarded WebKit test preferences select synthetic devices. Never fall
        // back to physical capture or real OS authorization in automated tests.
        let setter = NSSelectorFromString("_setMockCaptureDevicesEnabled:")
        let getter = NSSelectorFromString("_mockCaptureDevicesEnabled")
        let probe = WKPreferences()
        guard probe.responds(to: setter), probe.responds(to: getter) else { throw XCTSkip("This WebKit lacks synthetic capture devices") }
        typealias SetFlag = @convention(c) (AnyObject, Selector, Bool) -> Void
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/site")!) { configuration in
            let preferences = configuration.preferences
            unsafeBitCast(preferences.method(for: setter), to: SetFlag.self)(preferences, setter, true)
            XCTAssertEqual(preferences.value(forKey: "_mockCaptureDevicesEnabled") as? Bool, true)
            let focus = NSSelectorFromString("_setGetUserMediaRequiresFocus:")
            if preferences.responds(to: focus) {
                unsafeBitCast(preferences.method(for: focus), to: SetFlag.self)(preferences, focus, false)
            }
        }
        defer { page.close() }
        let service = page.session.siteData.mediaPermissions
        service.systemStatus = { _ in .authorized }
        service.requestSystemAccess = { _, _ in XCTFail("Synthetic capture must not request physical-device permission") }
        var prompts = 0
        service.presentAlert = { alert, _, reply in
            prompts += 1
            alert.suppressionButton?.state = .on
            reply(.alertFirstButtonReturn)
        }
        try await waitUntil { page.session.pageTitle == "Original site" && !page.session.isLoading }
        NSApp.activate(ignoringOtherApps: true)
        page.window.makeKeyAndOrderFront(nil)
        page.window.makeFirstResponder(page.view)
        _ = try await page.view.evaluateJavaScript("window.captureResult='pending';navigator.mediaDevices.getUserMedia({video:true,audio:true}).then(s=>{window.testStream=s;window.captureResult='granted'},e=>window.captureResult=e.name);true")
        try await waitUntil { ((try? await page.view.evaluateJavaScript("window.captureResult")) as? String) != "pending" }
        let result = try await page.view.evaluateJavaScript("window.captureResult") as? String
        XCTAssertEqual(result, "granted")
        XCTAssertEqual(prompts, 1, "The actual WKUIDelegate must issue one combined site consent")
        guard result == "granted" else { return }
        try await waitUntil { page.view.cameraCaptureState == .active && page.view.microphoneCaptureState == .active }
        XCTAssertTrue(service.hasPendingOrActiveCapture)
        let rule = try XCTUnwrap(service.rules.first)
        service.setChoice(.deny, device: .camera, ruleID: rule.id)
        try await waitUntil { page.view.cameraCaptureState == .none }
        XCTAssertEqual(page.view.microphoneCaptureState, .active)
        let videoState = try await page.view.evaluateJavaScript("testStream.getVideoTracks()[0].readyState") as? String
        XCTAssertEqual(videoState, "ended")
        service.reset(rule)
        try await waitUntil { page.view.microphoneCaptureState == .none }
        let audioState = try await page.view.evaluateJavaScript("testStream.getAudioTracks()[0].readyState") as? String
        XCTAssertEqual(audioState, "ended")
        XCTAssertEqual(service.rules.first?.microphone, .ask)
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription"))
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription"))
    }

    func testNativeSiteConsentSheetAppearanceWithoutStartingCapture() async throws {
        let server = try PopupHTTPFixture(); let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/site")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Original site" && !page.session.isLoading }
        let service = page.session.siteData.mediaPermissions
        service.systemStatus = { _ in .authorized }
        let origin = try XCTUnwrap(MediaSiteOrigin(url: page.view.url!))
        var alert: NSAlert?
        service.presentAlert = { shown, window, reply in alert = shown; shown.beginSheetModal(for: window, completionHandler: reply) }
        var decision: WKPermissionDecision?
        NSApp.activate(ignoringOtherApps: true); page.window.makeKeyAndOrderFront(nil)
        service.request(in: page.view, context: SiteMediaRule(top: origin, requester: origin), devices: [.camera, .microphone]) { decision = $0 }
        try await waitUntil { page.window.attachedSheet != nil }
        let sheet = try XCTUnwrap(alert?.window)
        try await Task.sleep(for: .milliseconds(350))
        sheet.contentView?.layoutSubtreeIfNeeded()
        if let content = sheet.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/linklet-native-media-permission.png"))
        }
        page.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        sheet.orderOut(nil)
        try await waitUntil { decision != nil }
        XCTAssertEqual(decision, .deny)
        XCTAssertEqual(page.view.cameraCaptureState, .none)
        XCTAssertEqual(page.view.microphoneCaptureState, .none)
    }

    private func waitUntil(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(100)) }
        XCTFail("Media permission fixture timed out", file: file, line: line)
    }
}

@MainActor
final class PageFindTests: XCTestCase {
    func testReloadAndZoomShortcutsInMainAndPopupWithoutChangingChrome() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "PageCommands.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "keepsPreviewVisibleWhenInactive")
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.siteData.selectModeForPreview(false)
        defer { model.closeAllWindows(); defaults.removePersistentDomain(forName: suite) }
        model.showPreview(url: URL(string: "http://127.0.0.1:\(port)/find")!)
        try await waitUntil { model.previewSession.pageTitle == "Find fixture" && !model.previewSession.isLoading }
        let main = model.previewSession
        let source = try XCTUnwrap(main.webView)
        _ = try await source.evaluateJavaScript("window.open('/find','commands-child');true")
        try await waitUntil { model.windowRegistry.webWindows(openedBy: main.windowID).values.first?.session.pageTitle == "Find fixture" }
        let child = try XCTUnwrap(model.windowRegistry.webWindows(openedBy: main.windowID).values.first?.session)
        for session in [main, child] {
            let view = try XCTUnwrap(session.webView)
            let window = try XCTUnwrap(view.window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await waitUntil { window.isKeyWindow && NSApp.isActive }
            window.makeFirstResponder(view)
            _ = try await view.evaluateJavaScript("document.getElementById('draft').focus();window.reloadMarker='before';true")
            let original = session.originalURL
            let current = view.url
            let navigation = session.navigationID
            let historyCount = view.backForwardList.backList.count
            let frame = view.frame
            let textWidth = (try await view.evaluateJavaScript("document.getElementById('draft').getBoundingClientRect().width") as! NSNumber).doubleValue
            try sendKey(to: window, code: 24, characters: "+", modifiers: [.command, .shift])
            XCTAssertEqual(view.pageZoom, 1.1, accuracy: 0.001)
            XCTAssertEqual((session === main ? child : main).webView?.pageZoom, 1)
            // A DOM measurement verifies that WebKit actually scales content.
            try await Task.sleep(for: .milliseconds(100))
            let scaledWidth = (try await view.evaluateJavaScript("document.getElementById('draft').getBoundingClientRect().width * window.devicePixelRatio") as! NSNumber).doubleValue
            let baselineWidth = textWidth * (window.backingScaleFactor)
            XCTAssertGreaterThan(scaledWidth, baselineWidth * 1.05)
            XCTAssertEqual(view.frame, frame, "Page zoom must not resize the chrome or viewport")
            try sendKey(to: window, code: 27, characters: "-", modifiers: .command)
            XCTAssertEqual(view.pageZoom, 1, accuracy: 0.001)
            try sendKey(to: window, code: 24, characters: "=", modifiers: .command)
            try sendKey(to: window, code: 15, characters: "к", modifiers: .command)
            for _ in 0..<100 {
                if try await view.evaluateJavaScript("typeof window.reloadMarker") as? String == "undefined", !view.isLoading { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let marker = try await view.evaluateJavaScript("typeof window.reloadMarker") as? String
            XCTAssertEqual(marker, "undefined", "Cmd-R must really reload the document, even from a page input")
            XCTAssertTrue(session.webView === view)
            XCTAssertEqual(session.navigationID, navigation)
            XCTAssertEqual(session.originalURL, original)
            XCTAssertEqual(view.url, current)
            XCTAssertEqual(view.backForwardList.backList.count, historyCount)
            XCTAssertEqual(view.pageZoom, 1.1, accuracy: 0.001)
            try sendKey(to: window, code: 29, characters: "0", modifiers: .command)
            XCTAssertEqual(view.pageZoom, 1)
            XCTAssertEqual(session.pageZoom, 1)
            try sendKey(to: window, code: 3, characters: "f", modifiers: .command)
            let findPanel = try panel(in: window)
            try await waitUntil { findPanel.searchField.currentEditor() != nil }
            try sendKey(to: window, code: 69, characters: "+", modifiers: .command)
            XCTAssertEqual(view.pageZoom, 1.1, accuracy: 0.001, "Commands also work from native find editor")
            try sendKey(to: window, code: 37, characters: "l", modifiers: .command)
            let addressControl = try address(in: window)
            try await waitUntil { addressControl.addressField.currentEditor() != nil }
            try sendKey(to: window, code: 82, characters: "0", modifiers: .command)
            XCTAssertEqual(view.pageZoom, 1, "Reset also works from native address editor")
            session.pageFind.close()
        }
    }

    func testPageZoomBoundsNavigationAndSessionReset() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/find")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Find fixture" && !page.session.isLoading }
        for _ in 0..<40 { page.session.changePageZoom(increase: true) }
        XCTAssertEqual(page.view.pageZoom, 3)
        for _ in 0..<40 { page.session.changePageZoom(increase: false) }
        XCTAssertEqual(page.view.pageZoom, 0.5)
        XCTAssertTrue(page.session.submitAddress("http://127.0.0.1:\(port)/find-highlight", engine: .google))
        try await waitUntil { page.view.url?.path == "/find-highlight" && !page.view.isLoading }
        XCTAssertEqual(page.view.pageZoom, 0.5)
        page.session.goBack()
        try await waitUntil { page.view.url?.path == "/find" && !page.view.isLoading }
        XCTAssertEqual(page.view.pageZoom, 0.5)
        page.view.magnification = 1.2
        page.session.resetPageZoom()
        XCTAssertEqual(page.view.pageZoom, 1)
        XCTAssertEqual(page.view.magnification, 1)
        page.session.changePageZoom(increase: true)
        page.session.endSession()
        XCTAssertEqual(page.session.pageZoom, 1)
    }

    func testHTMLFindCountsInlineAndCrossOriginMatchesWithoutChangingDOM() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string: "http://127.0.0.1:\(port)/find")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Find fixture" && !page.session.isLoading }
        let html = try await page.view.evaluateJavaScript("document.body.innerHTML") as? String
        let original = page.session.originalURL
        let find = page.session.pageFind
        XCTAssertTrue(find.usesNativeMatchCounts, "The tested WebKit must exercise native counts, not the fallback")
        find.show()
        find.setQuery("needle")
        try await waitUntil { find.matchCount == 5 && !find.isSearching }
        let initial = try XCTUnwrap(find.matchIndex)
        find.navigate()
        try await waitUntil { find.matchIndex == (initial + 1) % 5 && !find.isSearching }
        find.navigate(backwards: true)
        try await waitUntil { find.matchIndex == initial && !find.isSearching }
        for _ in 0..<5 {
            let previous = find.matchIndex
            find.navigate()
            try await waitUntil { find.matchIndex != previous && !find.isSearching }
        }
        XCTAssertEqual(find.matchIndex, initial, "Next wraps after the last match")
        let after = try await page.view.evaluateJavaScript("document.body.innerHTML") as? String
        XCTAssertEqual(html, after, "Native highlights must not insert spans or rewrite page HTML")
        let draft = try await page.view.evaluateJavaScript("document.getElementById('draft').value") as? String
        XCTAssertEqual(draft, "unchanged")
        XCTAssertEqual(page.session.originalURL, original)
        XCTAssertEqual(page.session.currentURL, original)
        find.setQuery("not-present-in-this-document")
        try await waitUntil { find.matchCount == 0 && !find.isSearching }
        find.setQuery("'"); find.setQuery("\\"); find.setQuery("needle")
        try await waitUntil { find.matchCount == 5 && !find.isSearching }
        find.setQuery("")
        XCTAssertFalse(find.isSearching)
        XCTAssertEqual(find.counterText, "")
        find.close()
        XCTAssertFalse(find.isPresented)
        _ = try await page.view.evaluateJavaScript("document.body.innerHTML='<p>'+('manyneedle '.repeat(10050))+'</p>';true")
        find.show()
        find.setQuery("manyneedle")
        try await waitUntil { find.matchCount == 10000 && !find.isSearching }
        XCTAssertEqual(find.counterText,L("%d+ matches",10000),"Large results display a lower bound instead of an invented exact total")
    }

    func testFloatingPanelKeyboardFocusGeometryAndIndependentPopupState() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let suite = "PageFindKeyboard.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "keepsPreviewVisibleWhenInactive")
        let model = AppModel(defaults: defaults, discoverTargets: { [] })
        model.siteData.selectModeForPreview(false)
        defer { model.closeAllWindows(); defaults.removePersistentDomain(forName: suite) }
        model.showPreview(url: URL(string: "http://127.0.0.1:\(port)/find")!)
        try await waitUntil { model.previewSession.pageTitle == "Find fixture" && !model.previewSession.isLoading }
        let mainWindow = try XCTUnwrap(NSApp.windows.first {
            ($0.contentViewController as? NSHostingController<PreviewRootView>)?.rootView.session === model.previewSession
        })
        let source = try XCTUnwrap(model.previewSession.webView)
        _ = try await source.evaluateJavaScript("window.open('/find','find-child');true")
        try await waitUntil { model.windowRegistry.webWindows(openedBy: model.previewSession.windowID).values.first?.session.pageTitle == "Find fixture" }
        let popup = try XCTUnwrap(model.windowRegistry.webWindows(openedBy: model.previewSession.windowID).values.first)
        let popupWindow = try XCTUnwrap(popup.window)
        for (window, session, name) in [(mainWindow,model.previewSession,"main"),(popupWindow,popup.session,"popup")] {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await waitUntil { window.isKeyWindow && NSApp.isActive }
            window.setContentSize(NSSize(width:640,height:500))
            window.contentView?.layoutSubtreeIfNeeded()
            let view = try XCTUnwrap(session.webView)
            let webFrame = view.frame
            let windowFrame = window.frame
            let panel = try panel(in:window)
            try sendKey(to:window,code:3,characters:"а",modifiers:.command)
            try await waitUntil { session.pageFind.isPresented && panel.searchField.currentEditor() != nil }
            let editor = try XCTUnwrap(panel.searchField.currentEditor() as? NSTextView)
            editor.insertText("needle",replacementRange:editor.selectedRange())
            try await waitUntil { session.pageFind.matchCount == 5 && !session.pageFind.isSearching }
            XCTAssertEqual(view.frame,webFrame,"Floating search must not resize the viewport")
            XCTAssertEqual(window.frame,windowFrame)
            let oldIndex = try XCTUnwrap(session.pageFind.matchIndex)
            try sendKey(to:window,code:36,characters:"\r")
            try await waitUntil { session.pageFind.matchIndex == (oldIndex+1)%5 && !session.pageFind.isSearching }
            try sendKey(to:window,code:36,characters:"\r",modifiers:.shift)
            try await waitUntil { session.pageFind.matchIndex == oldIndex && !session.pageFind.isSearching }
            window.contentView?.layoutSubtreeIfNeeded()
            let content = try XCTUnwrap(window.contentView)
            XCTAssertTrue(content.bounds.contains(panel.convert(panel.bounds,to:content)))
            if let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                content.cacheDisplay(in:content.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/linklet-find-\(name).png"))
            }
            // Escape from the web content must dismiss search without closing it.
            window.makeFirstResponder(view)
            try sendKey(to:window,code:53,characters:"\u{1b}")
            XCTAssertFalse(session.pageFind.isPresented)
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(session.isActive)
            try sendKey(to:window,code:3,characters:"f",modifiers:.command)
            try await waitUntil { panel.searchField.currentEditor() != nil }
            let other = session === model.previewSession ? popup.session : model.previewSession
            let otherQuery = other.pageFind.query
            let newEditor = try XCTUnwrap(panel.searchField.currentEditor() as? NSTextView)
            newEditor.insertText("missing",replacementRange:newEditor.selectedRange())
            try await waitUntil { session.pageFind.matchCount == 0 && !session.pageFind.isSearching }
            XCTAssertEqual(other.pageFind.query,otherQuery)
            try sendKey(to:window,code:37,characters:"l",modifiers:.command)
            let address = try address(in:window)
            try await waitUntil { address.isExpanded && address.addressField.currentEditor() != nil }
            try sendKey(to:window,code:53,characters:"\u{1b}")
            XCTAssertFalse(address.isExpanded)
            XCTAssertTrue(session.pageFind.isPresented,"Escape first belongs to the address editor")
            try sendKey(to:window,code:3,characters:"f",modifiers:.command)
            try await waitUntil { panel.searchField.currentEditor() != nil }
            try sendKey(to:window,code:53,characters:"\u{1b}")
            XCTAssertFalse(session.pageFind.isPresented,"Escape in the search editor closes only the search")
            XCTAssertTrue(window.isVisible)
            session.pageFind.show()
            if name == "popup" {
                panel.closeButton.performClick(nil)
                XCTAssertFalse(session.pageFind.isPresented)
                XCTAssertTrue(model.previewSession.pageFind.isPresented,"Another window retains its open search")
            }
        }
    }

    func testNavigationAndCloseCancelPendingResultsAndRetainQueryOnlyWithinWindow() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url:URL(string:"http://127.0.0.1:\(port)/find")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Find fixture" && !page.session.isLoading }
        let find = page.session.pageFind
        find.show(); find.setQuery("needle")
        try await waitUntil { find.matchCount == 5 && !find.isSearching }
        XCTAssertTrue(page.session.submitAddress("http://127.0.0.1:\(port)/destination",engine:.google))
        try await waitUntil { page.session.pageTitle == "Destination" && find.matchCount == 0 && !find.isSearching }
        XCTAssertTrue(find.isPresented)
        XCTAssertEqual(find.query,"needle")
        page.session.goBack()
        try await waitUntil { page.session.pageTitle == "Find fixture" && find.matchCount == 5 && !find.isSearching }
        find.setQuery("pending-close")
        page.session.endSession()
        XCTAssertFalse(find.isPresented)
        XCTAssertEqual(find.query,"")
        XCTAssertNil(find.matchCount)
        try await Task.sleep(for:.milliseconds(250))
        XCTAssertFalse(find.isPresented)
        XCTAssertNil(find.matchCount,"A cancelled debounce or native callback must not resurrect closed state")
    }

    func testPublicFindFallbackCanSearchAndNavigateWithoutInventingMatchCounts() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url:URL(string:"http://127.0.0.1:\(port)/find")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Find fixture" && !page.session.isLoading }
        page.session.pageFind.detach()
        let find=PageFindController(allowsNativeMatchCounts:false,allowsHTMLSearch:false)
        find.attach(page.view)
        defer { find.detach() }
        XCTAssertFalse(find.usesNativeMatchCounts)
        find.show(); find.setQuery("needle")
        try await waitUntil { !find.isSearching }
        XCTAssertNil(find.matchCount)
        XCTAssertEqual(find.counterText,L("Found"))
        find.navigate(backwards:true)
        try await waitUntil { !find.isSearching }
        XCTAssertNil(find.matchCount)
        find.setQuery("absent-on-this-page")
        try await waitUntil { find.matchCount == 0 && !find.isSearching }
        find.close()
        XCTAssertFalse(find.isPresented)
    }

    func testAccentHighlightAnimatesOnlyTheMovingBoundaryAndTracksThePage() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url: URL(string:"http://127.0.0.1:\(port)/find-highlight")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Выделение текста" && !page.session.isLoading }
        let before = try await page.view.evaluateJavaScript("document.body.innerHTML") as? String
        let find = page.session.pageFind
        find.show(); find.setQuery("выд")
        try await waitUntil { find.matchCount == 2 && !find.isSearching }
        let initial = try await waitForHighlight(in:page.view,query:"выд")
        let firstStart = try XCTUnwrap(initial["start"] as? [String:Double])
        let firstEnd = try XCTUnwrap(initial["end"] as? [String:Double])
        XCTAssertEqual(initial["pointerEvents"] as? String,"none")
        XCTAssertEqual(initial["ariaHidden"] as? String,"true")
        find.setQuery("выделители")
        try await waitUntil { find.matchCount == 2 && !find.isSearching }
        let grown = try await waitForHighlight(in:page.view,query:"выделители")
        let start = try XCTUnwrap(grown["start"] as? [String:Double])
        let end = try XCTUnwrap(grown["end"] as? [String:Double])
        XCTAssertEqual(start["x"]!,firstStart["x"]!,accuracy:1)
        XCTAssertEqual(start["y"]!,firstStart["y"]!,accuracy:1)
        XCTAssertGreaterThan(end["x"]!,firstEnd["x"]!+80)
        XCTAssertEqual(grown["animated"] as? Bool,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        var accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
        page.view.effectiveAppearance.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
        }
        let expectedColor = "rgb(\(Int((accent.redComponent*255).rounded())), \(Int((accent.greenComponent*255).rounded())), \(Int((accent.blueComponent*255).rounded())))"
        XCTAssertEqual(grown["color"] as? String,expectedColor)
        let hit = try await page.view.evaluateJavaScript("(()=>{const r=document.getElementById('word').getBoundingClientRect();return document.elementFromPoint(r.x+8,r.y+30)?.id})()") as? String
        XCTAssertEqual(hit,"word","The decoration must not intercept clicks on the page")
        try await Task.sleep(for:.milliseconds(230))
        if let content = page.window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
            content.cacheDisplay(in:content.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/linklet-find-ios-style.png"))
        }
        let reducedValue: Any = try await withCheckedThrowingContinuation { continuation in
            page.view.callAsyncJavaScript("globalThis.__linkletFindHighlight.appearance(color,true);return globalThis.__linkletFindHighlight.diagnostics()",
                arguments:["color":expectedColor],in:nil,in:PageFindHighlighter.world) { continuation.resume(with:$0) }
        }
        let reduced=try XCTUnwrap(reducedValue as? [String:Any])
        XCTAssertEqual(reduced["reduced"] as? Bool,true)
        XCTAssertEqual(reduced["endTransition"] as? String,"none")
        page.window.appearance=NSAppearance(named:.aqua)
        for _ in 0..<40 {
            if (try await page.view.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches")) as? Bool == false { break }
            try await Task.sleep(for:.milliseconds(25))
        }
        if let content = page.window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
            content.cacheDisplay(in:content.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/linklet-find-ios-light.png"))
        }
        _ = try await page.view.evaluateJavaScript("scrollTo(0,50);true")
        var scrolled = grown
        for _ in 0..<40 {
            scrolled = try await highlightState(in:page.view)
            if let p=scrolled["start"] as? [String:Double], p["y"]! < start["y"]!-30 { break }
            try await Task.sleep(for:.milliseconds(25))
        }
        let scrollStart = try XCTUnwrap(scrolled["start"] as? [String:Double])
        XCTAssertEqual(scrollStart["y"]!,start["y"]!-50,accuracy:2)
        let after = try await page.view.evaluateJavaScript("document.body.innerHTML") as? String
        XCTAssertEqual(before,after,"No search spans may be inserted into the page content")
        find.close()
        for _ in 0..<40 {
            if (try await highlightState(in:page.view))["active"] as? Bool == false { break }
            try await Task.sleep(for:.milliseconds(25))
        }
        let hidden = try await highlightState(in:page.view)
        XCTAssertEqual(hidden["active"] as? Bool,false)
        XCTAssertEqual(hidden["display"] as? String,"none")
    }

    func testHighlightFollowsTheNativeResultIntoACrossOriginFrame() async throws {
        let server = try PopupHTTPFixture()
        let port = try await server.start()
        defer { server.stop() }
        let page = UploadTestPage(url:URL(string:"http://127.0.0.1:\(port)/find")!)
        defer { page.close() }
        try await waitUntil { page.session.pageTitle == "Find fixture" && !page.session.isLoading }
        let find = page.session.pageFind
        find.show(); find.setQuery("needle")
        try await waitUntil { find.matchCount == 5 && !find.isSearching }
        var reachedFrame = false
        for _ in 0..<5 {
            _ = try await waitForHighlight(in:page.view,query:"needle",selectedFrame:true)
            if let frame=PageFindHighlighter.shared.selectedFrame(in:page.view), !frame.isMainFrame {
                let state=try await highlightState(in:page.view,frame:frame)
                XCTAssertEqual(state["active"] as? Bool,true)
                XCTAssertEqual((state["rangeText"] as? String)?.lowercased(),"needle")
                let rects=try XCTUnwrap(state["rects"] as? [[String:Double]])
                XCTAssertEqual(rects.first?["x"] ?? 0,8,accuracy:2,"The iframe paints in its own coordinate space")
                reachedFrame=true; break
            }
            let previous=find.matchIndex
            find.navigate()
            try await waitUntil { !find.isSearching && find.matchIndex != previous }
        }
        XCTAssertTrue(reachedFrame,"Native result traversal must retain custom styling inside another origin")
    }

    func testBlankClickAndUserSelectionDoNotDismissTheSearchResultOrInvokeNativePaint() async throws {
        let server=try PopupHTTPFixture()
        let port=try await server.start()
        defer {server.stop()}
        let page=UploadTestPage(url:URL(string:"http://127.0.0.1:\(port)/find-highlight")!)
        defer {page.close()}
        try await waitUntil {page.session.pageTitle=="Выделение текста" && !page.session.isLoading}
        let find=page.session.pageFind
        find.show();find.setQuery("выд")
        try await waitUntil {!find.isSearching && find.matchCount==2}
        _=try await waitForHighlight(in:page.view,query:"выд")
        XCTAssertEqual(find.nativeFindRequestCount,0,"HTML search must never create an ActiveTextMatch to remove later")
        NSApp.activate(ignoringOtherApps:true)
        page.window.makeKeyAndOrderFront(nil)
        page.window.makeFirstResponder(page.view)
        let location=page.view.convert(NSPoint(x:500,y:400),to:nil)
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            let event=try XCTUnwrap(NSEvent.mouseEvent(with:type,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:page.window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1 : 0))
            page.window.sendEvent(event)
        }
        _=try await page.view.evaluateJavaScript("getSelection().removeAllRanges();true")
        let afterClick=try await waitForHighlight(in:page.view,query:"выд")
        XCTAssertTrue(find.isPresented)
        XCTAssertEqual(afterClick["display"] as? String,"block")
        XCTAssertEqual(afterClick["selected"] as? String,"")
        let findPanel=try panel(in:page.window)
        findPanel.searchField.selectText(nil)
        try await waitUntil {findPanel.searchField.currentEditor() != nil}
        _=try await page.view.evaluateJavaScript("(()=>{const r=document.createRange();r.selectNodeContents(document.querySelector('p'));getSelection().addRange(r);return true})()")
        let userSelection=try await page.view.evaluateJavaScript("String(getSelection())") as? String
        let editor=try XCTUnwrap(findPanel.searchField.currentEditor() as? NSTextView)
        editor.insertText("выделители",replacementRange:editor.selectedRange())
        try await waitUntil {!find.isSearching && find.matchCount==2}
        let grown=try await waitForHighlight(in:page.view,query:"выделители")
        XCTAssertEqual(grown["selected"] as? String,userSelection,"Find must leave the user's selection alone")
        XCTAssertEqual(find.nativeFindRequestCount,0)
        find.close()
        for _ in 0..<40 {
            if (try await highlightState(in:page.view))["display"] as? String == "none" {break}
            try await Task.sleep(for:.milliseconds(25))
        }
        let finalState=try await highlightState(in:page.view)
        XCTAssertEqual(finalState["display"] as? String,"none")
    }

    func testShadowDOMHighlightTracksLayoutAnimationAndRepairsHydrationWithoutGhosts() async throws {
        let server=try PopupHTTPFixture()
        let port=try await server.start()
        defer {server.stop()}
        let page=UploadTestPage(url:URL(string:"http://127.0.0.1:\(port)/find")!)
        defer {page.close()}
        try await waitUntil {page.session.pageTitle=="Find fixture" && !page.session.isLoading}
        _=try await page.view.evaluateJavaScript("""
            document.body.innerHTML='<article id="post"></article>';
            document.body.style.cssText='height:1600px;margin:0;padding:40px';
            window.testRoot=document.getElementById('post').attachShadow({mode:'open'});
            window.testMarkup='<style>h2{font:40px -apple-system;margin:0}#move{transition:transform 180ms linear}</style><div id="move"><h2 id="label">What is this title?</h2></div>';
            testRoot.innerHTML=testMarkup;true
            """)
        let find=page.session.pageFind
        find.show();find.setQuery("what")
        try await waitUntil {!find.isSearching && find.matchCount==1}
        _=try await waitForHighlight(in:page.view,query:"what")
        _=try await page.view.evaluateJavaScript("testRoot.getElementById('move').style.transform='translateY(140px)';true")
        for _ in 0..<9 {
            let sample:Any=try await withCheckedThrowingContinuation { continuation in
                page.view.callAsyncJavaScript("""
                    return await new Promise(resolve=>requestAnimationFrame(()=>{
                        const node=document.getElementById('post').shadowRoot.getElementById('label').firstChild;
                        const r=document.createRange();r.setStart(node,0);r.setEnd(node,4);
                        resolve({actual:r.getBoundingClientRect().y,highlight:globalThis.__linkletFindHighlight.diagnostics().rects[0]?.y});
                    }));
                    """,arguments:[:],in:nil,in:PageFindHighlighter.world) { continuation.resume(with:$0) }
            }
            let values=try XCTUnwrap(sample as? [String:Double])
            XCTAssertEqual(try XCTUnwrap(values["highlight"]),try XCTUnwrap(values["actual"]),accuracy:2,"The highlight must follow every frame of a layout animation")
            try await Task.sleep(for:.milliseconds(25))
        }
        _=try await page.view.evaluateJavaScript("testRoot.innerHTML=testMarkup;true")
        var repaired:[String:Any]=[:]
        for _ in 0..<80 {
            repaired=try await highlightState(in:page.view)
            if repaired["rangeText"] as? String == "What", repaired["display"] as? String == "block" {break}
            try await Task.sleep(for:.milliseconds(25))
        }
        XCTAssertEqual(repaired["rangeText"] as? String,"What")
        XCTAssertEqual(repaired["display"] as? String,"block")
        _=try await page.view.evaluateJavaScript("testRoot.getElementById('label').textContent='Gone';true")
        for _ in 0..<80 {
            if (try await highlightState(in:page.view))["display"] as? String == "none" {break}
            try await Task.sleep(for:.milliseconds(25))
        }
        let removedState=try await highlightState(in:page.view)
        XCTAssertEqual(removedState["display"] as? String,"none","Removed text must never leave a floating highlight")
        _=try await page.view.evaluateJavaScript("testRoot.getElementById('label').textContent='What is this title?';true")
        _=try await waitForHighlight(in:page.view,query:"what")
        XCTAssertEqual(find.nativeFindRequestCount,0)
    }

    private func highlightState(in view:WKWebView,frame:WKFrameInfo?=nil) async throws -> [String:Any] {
        let value: Any = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript("return globalThis.__linkletFindHighlight?.diagnostics() ?? {}",arguments:[:],in:frame,in:PageFindHighlighter.world) { result in
                continuation.resume(with: result)
            }
        }
        return value as? [String:Any] ?? [:]
    }

    private func waitForHighlight(in view:WKWebView,query:String,selectedFrame:Bool=false) async throws -> [String:Any] {
        for _ in 0..<80 {
            let frame=selectedFrame ? PageFindHighlighter.shared.selectedFrame(in:view) : nil
            let state=try await highlightState(in:view,frame:frame)
            if state["active"] as? Bool == true, state["query"] as? String == query { return state }
            try await Task.sleep(for:.milliseconds(25))
        }
        XCTFail("Custom highlight did not appear for the native result")
        return [:]
    }

    private func address(in window:NSWindow) throws -> PreviewAddressControlView {
        func search(_ view:NSView)->PreviewAddressControlView? {
            if let address=view as? PreviewAddressControlView { return address }
            return view.subviews.lazy.compactMap(search).first
        }
        return try XCTUnwrap(window.contentView.flatMap(search))
    }

    private func panel(in window:NSWindow) throws -> PreviewFindControlView {
        func search(_ view:NSView)->PreviewFindControlView? {
            if let panel=view as? PreviewFindControlView { return panel }
            return view.subviews.lazy.compactMap(search).first
        }
        return try XCTUnwrap(window.contentView.flatMap(search))
    }

    private func sendKey(to window:NSWindow,code:UInt16,characters:String,modifiers:NSEvent.ModifierFlags=[]) throws {
        let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,
            timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,
            characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code))
        NSApp.postEvent(event,atStart:true)
        if let next=NSApp.nextEvent(matching:.keyDown,until:Date().addingTimeInterval(0.1),inMode:.default,dequeue:true) {
            NSApp.sendEvent(next)
        }
    }

    private func waitUntil(_ predicate:()->Bool,file:StaticString=#filePath,line:UInt=#line) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTFail("Find fixture did not reach its expected state",file:file,line:line)
    }
}

import AppKit
import Combine

struct BrowserWindowInfo: Identifiable, Equatable {
    let id: UUID
    /// The logical WebKit opener, never an AppKit parent/child attachment.
    let parentID: UUID?
    let title: String
    let url: URL?
    let isLoading: Bool
    let isKey: Bool
    let isMiniaturized: Bool
}

/// An in-memory index of live pages. Controllers retain their windows; this index
/// never reloads a URL to activate a page and never persists browsing information.
@MainActor
final class BrowserWindowRegistry: ObservableObject {
    @Published private(set) var windows: [BrowserWindowInfo] = []
    private(set) var lastActiveWindowID: UUID?
    let downloads: DownloadManager

    init(downloads: DownloadManager? = nil) { self.downloads = downloads ?? DownloadManager() }

    private final class Entry {
        weak var window: NSWindow?
        weak var session: PreviewSession?
        let parentID: UUID?
        var observations = Set<AnyCancellable>()

        init(window: NSWindow, session: PreviewSession, parentID: UUID?) {
            self.window = window
            self.session = session
            self.parentID = parentID
        }
    }

    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var refreshIsScheduled = false
    private(set) var isClosingFromSidebar = false
    // Site-created windows outlive the coordinator/page that opened them.
    private var webWindows: [UUID: WebPopupWindowController] = [:]

    var hasWindows: Bool { entries.values.contains { $0.window != nil } }
    var activeSessions: [PreviewSession] { entries.values.compactMap(\.session) }
    var hasVisibleWindows: Bool { entries.values.contains { $0.window?.isVisible == true } }
    var lastVisibleFrame: NSRect? {
        order.reversed().compactMap { id -> NSRect? in
            guard let window = entries[id]?.window, window.isVisible else { return nil }
            return window.frame
        }.first
    }

    func retain(_ controller: WebPopupWindowController) {
        webWindows[controller.session.windowID] = controller
    }

    func webWindows(openedBy id: UUID) -> [UUID: WebPopupWindowController] {
        webWindows.filter { $0.value.openerID == id && $0.value.session.isActive }
    }

    func register(_ window: NSWindow, session: PreviewSession, parentID: UUID? = nil) {
        let id = session.windowID
        if entries[id]?.window === window { refresh(); return }
        if entries[id] == nil { order.append(id) }
        let entry = Entry(window: window, session: session, parentID: parentID)
        entries[id] = entry
        // ObservableObject announces before its properties change. Read them on
        // the next run-loop turn and coalesce WebKit's frequent progress events.
        session.objectWillChange.sink { [weak self] _ in self?.refreshSoon() }
            .store(in: &entry.observations)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.publisher(for: name, object: window)
                .sink { [weak self] _ in self?.refresh() }.store(in: &entry.observations)
        }
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak self] _ in self?.unregister(id) }.store(in: &entry.observations)
        refresh()
    }

    func unregister(_ id: UUID) {
        if lastActiveWindowID == id { lastActiveWindowID = nil }
        entries.removeValue(forKey: id)
        order.removeAll { $0 == id }
        // Keep the controller alive until all willClose observers and its delegate
        // finish detaching the page. Notification delivery order is unspecified.
        if webWindows[id] != nil {
            DispatchQueue.main.async { [weak self] in self?.webWindows.removeValue(forKey: id) }
        }
        refresh()
    }

    func activate(_ id: UUID) {
        guard let window = entries[id]?.window else { return }
        lastActiveWindowID = id
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refresh()
    }

    func close(_ id: UUID) {
        entries[id]?.window?.performClose(nil)
    }

    func closeFromSidebar(_ id: UUID) {
        isClosingFromSidebar = true
        defer { isClosingFromSidebar = false }
        close(id)
    }

    func closeAll() {
        let windows = entries.values.compactMap(\.window)
        // Used before changing/deleting website data as well as by Close All.
        // Preserve the previous unconditional close semantics for that operation.
        windows.forEach { $0.close() }
    }

    func activateLastWindow() {
        guard let id = order.reversed().first(where: { entries[$0]?.window?.isVisible == true }) else { return }
        activate(id)
    }

    func refresh() {
        let orphanIDs = order.filter { entries[$0]?.window == nil || entries[$0]?.session == nil }
        for id in orphanIDs { entries.removeValue(forKey: id) }
        order.removeAll { orphanIDs.contains($0) }
        let next = order.compactMap { id -> BrowserWindowInfo? in
            guard let entry = entries[id], let session = entry.session, let window = entry.window,
                  session.isActive, !session.isWelcome else { return nil }
            let title = session.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return BrowserWindowInfo(id: id, parentID: entry.parentID,
                title: title.isEmpty ? (session.currentURL?.host ?? L("Website window")) : title,
                url: session.currentURL, isLoading: session.isLoading,
                isKey: window.isKeyWindow, isMiniaturized: window.isMiniaturized)
        }
        if let active = next.first(where: \.isKey) { lastActiveWindowID = active.id }
        if next != windows { windows = next }
    }

    private func refreshSoon() {
        guard !refreshIsScheduled else { return }
        refreshIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshIsScheduled = false
            self?.refresh()
        }
    }
}

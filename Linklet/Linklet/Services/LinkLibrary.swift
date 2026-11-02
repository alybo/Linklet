import Foundation

struct BookmarkFolder: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
}

struct PagePosition: Codable, Equatable {
    let x: Double
    let y: Double
    static let top = PagePosition(x: 0, y: 0)
    var isValid: Bool { x.isFinite && y.isFinite && abs(x) < 100_000_000 && y >= 0 && y < 100_000_000 }
}

struct RecentLink: Codable, Equatable, Identifiable {
    let id: UUID
    let address: String
    var title: String
    var openedAt: Date
    var position: PagePosition? = nil
    var url: URL? { URL(string: address).flatMap { URLPolicy.canPreview($0) ? $0 : nil } }
}

enum SidebarSection: String, Codable, CaseIterable, Identifiable {
    case open, bookmarks, recent, downloads
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: return L("Open windows")
        case .bookmarks: return L("Favorites")
        case .recent: return L("Recent links")
        case .downloads: return L("Downloads")
        }
    }
    var symbol: String {
        switch self {
        case .open: return "rectangle.on.rectangle"
        case .bookmarks: return "star"
        case .recent: return "clock.arrow.circlepath"
        case .downloads: return "arrow.down.circle"
        }
    }
}

enum SidebarAppearance: String, CaseIterable, Identifiable {
    case black, glass
    var id: String { rawValue }
    var title: String { self == .black ? L("Black") : L("Glass (test)") }
    static var supportsGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// Explicit bookmarks persist. Visited pages stay in memory unless saving is enabled.
@MainActor
final class LinkLibrary: ObservableObject {
    static let recentLimit = 200
    @Published private(set) var isEnabled: Bool
    @Published private(set) var savesHistory: Bool
    @Published private(set) var showsRevealIndicator: Bool
    @Published private(set) var hidesInFullScreen: Bool
    @Published private(set) var separatesSections: Bool
    @Published private(set) var showsSidebarSearch: Bool
    @Published private(set) var sectionWidths: [String: Double]
    @Published private(set) var sidebarWidth: Double
    @Published private(set) var edgeOpenDelay: TimeInterval
    @Published private(set) var sidebarAppearance: SidebarAppearance
    @Published private(set) var isHistoryClearPending = false
    @Published private(set) var folders: [BookmarkFolder]
    @Published private(set) var folderAssignments: [String: UUID]
    @Published private(set) var recentLinks: [RecentLink]
    @Published private(set) var expandedFolderIDs: Set<UUID> {
        didSet {
            guard expandedFolderIDs != oldValue else { return }
            defaults.set(expandedFolderIDs.map(\.uuidString).sorted(), forKey: "bookmarkExpandedFolderIDs")
        }
    }
    @Published private(set) var sectionOrder: [SidebarSection]
    @Published private(set) var expandedSections: Set<SidebarSection>
    @Published private(set) var recentDisplayLimit = 10
    var visibleRecentLinks: [RecentLink] { Array(recentLinks.prefix(recentDisplayLimit)) }
    var hasMoreRecentLinks: Bool { recentLinks.count > recentDisplayLimit }
    @Published var shortcutError: String?
    @Published private(set) var rootOrder: [UUID]
    private weak var settings: SearchSettings?
    private let defaults: UserDefaults
    private var positionSave: Task<Void, Never>?
    private(set) var historyRevision = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
        var savedOrder = Self.read([SidebarSection].self, key: "sidebarSectionOrder", defaults: defaults) ?? SidebarSection.allCases
        // Add the live section above existing sections without resetting their order.
        if !savedOrder.contains(.open) { savedOrder.insert(.open, at: 0) }
        var seen = Set<SidebarSection>()
        sectionOrder = (savedOrder + SidebarSection.allCases).filter { seen.insert($0).inserted }
        expandedSections = Set(SidebarSection.allCases.filter { defaults.object(forKey: "sidebarExpanded.\($0.rawValue)") as? Bool ?? true })
        let savedWidth = defaults.object(forKey: "sidebarWidth") as? Double ?? 300
        sidebarWidth = savedWidth.isFinite && savedWidth > 0 ? savedWidth : 300
        separatesSections = defaults.bool(forKey: "sidebarSeparatesSections")
        showsSidebarSearch = defaults.bool(forKey: "sidebarShowsSearch")
        sectionWidths = (defaults.dictionary(forKey: "sidebarSectionWidths") as? [String: Double] ?? [:])
            .filter { $0.value.isFinite && $0.value > 0 }
        isEnabled = defaults.bool(forKey: "sidebarEnabled")
        sidebarAppearance = defaults.string(forKey: "sidebarAppearance").flatMap(SidebarAppearance.init(rawValue:)) ?? .black
        showsRevealIndicator = defaults.object(forKey: "sidebarShowsRevealIndicator") as? Bool ?? false
        hidesInFullScreen = defaults.bool(forKey: "sidebarHidesInFullScreen")
        let delay = defaults.object(forKey: "sidebarEdgeOpenDelay") as? Double ?? 0.4
        edgeOpenDelay = Self.clampedEdgeDelay(delay)
        let saves = defaults.bool(forKey: "sidebarSavesHistory")
        savesHistory = saves
        let savedFolders = Self.read([BookmarkFolder].self, key: "bookmarkFolders", defaults: defaults) ?? []
        rootOrder = Self.read([UUID].self, key: "bookmarkRootOrder", defaults: defaults) ?? []
        folders = savedFolders
        folderAssignments = Self.read([String: UUID].self, key: "bookmarkFolderAssignments", defaults: defaults) ?? [:]
        let folderIDs = Set(savedFolders.map(\.id))
        if let saved = defaults.stringArray(forKey: "bookmarkExpandedFolderIDs") {
            expandedFolderIDs = Set(saved.compactMap(UUID.init(uuidString:))).intersection(folderIDs)
        } else {
            // Older profiles had no saved disclosure state and showed every folder.
            expandedFolderIDs = folderIDs
        }
        recentLinks = saves ? Array((Self.read([RecentLink].self, key: "recentLinks", defaults: defaults) ?? [])
            .filter { $0.url != nil }.prefix(Self.recentLimit)) : []
        if !saves { defaults.removeObject(forKey: "recentLinks") }
    }

    func toggleSection(_ section: SidebarSection) {
        if expandedSections.contains(section) { expandedSections.remove(section) }
        else { expandedSections.insert(section) }
        defaults.set(expandedSections.contains(section), forKey: "sidebarExpanded.\(section.rawValue)")
    }

    func toggleFolder(_ id: UUID) {
        guard folders.contains(where: { $0.id == id }) else { return }
        if expandedFolderIDs.contains(id) { expandedFolderIDs.remove(id) }
        else { expandedFolderIDs.insert(id) }
    }

    func moveSection(_ section: SidebarSection, before destination: SidebarSection?) {
        guard section != destination else { return }
        sectionOrder.removeAll { $0 == section }
        let index = destination.flatMap { sectionOrder.firstIndex(of: $0) } ?? sectionOrder.endIndex
        sectionOrder.insert(section, at: index)
        defaults.set(try? JSONEncoder().encode(sectionOrder), forKey: "sidebarSectionOrder")
    }

    func showMoreRecentLinks() { recentDisplayLimit = min(Self.recentLimit, recentDisplayLimit + 10) }
    func resetRecentDisplayLimit() { recentDisplayLimit = 10 }

    static func clampedEdgeDelay(_ delay: TimeInterval) -> TimeInterval {
        delay.isFinite ? min(2, max(0.1, delay)) : 0.4
    }

    func setSeparatesSections(_ enabled: Bool) {
        separatesSections = enabled
        defaults.set(enabled, forKey: "sidebarSeparatesSections")
    }

    func setShowsSidebarSearch(_ enabled: Bool) {
        showsSidebarSearch = enabled
        defaults.set(enabled, forKey: "sidebarShowsSearch")
    }

    func width(for section: SidebarSection?) -> Double {
        guard let section else { return sidebarWidth }
        return sectionWidths[section.rawValue] ?? 260
    }

    func setWidth(_ width: Double, for section: SidebarSection?) {
        guard let section else { setSidebarWidth(width); return }
        guard width.isFinite, width > 0 else { return }
        sectionWidths[section.rawValue] = width
        defaults.set(sectionWidths, forKey: "sidebarSectionWidths")
    }

    static func matches(_ query: String, in values: String...) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace })
        return terms.allSatisfy { term in values.contains { $0.localizedStandardContains(String(term)) } }
    }

    func setSidebarWidth(_ width: Double) {
        guard width.isFinite, width > 0 else { return }
        sidebarWidth = width
        defaults.set(width, forKey: "sidebarWidth")
    }

    func setSidebarAppearance(_ appearance: SidebarAppearance) {
        sidebarAppearance = appearance
        defaults.set(appearance.rawValue, forKey: "sidebarAppearance")
    }

    func setShowsRevealIndicator(_ enabled: Bool) {
        showsRevealIndicator = enabled
        defaults.set(enabled, forKey: "sidebarShowsRevealIndicator")
    }

    func setHidesInFullScreen(_ enabled: Bool) {
        hidesInFullScreen = enabled
        defaults.set(enabled, forKey: "sidebarHidesInFullScreen")
    }

    func setEdgeOpenDelay(_ delay: TimeInterval) {
        edgeOpenDelay = Self.clampedEdgeDelay(delay)
        defaults.set(edgeOpenDelay, forKey: "sidebarEdgeOpenDelay")
    }

    func requestHistoryClear() { isHistoryClearPending = !recentLinks.isEmpty }
    func cancelHistoryClear() { isHistoryClearPending = false }
    func confirmHistoryClear() {
        guard isHistoryClearPending else { return }
        clearHistory()
    }

    func reorderSection(_ source: SidebarSection, onto destination: SidebarSection) {
        guard source != destination,
              let sourceIndex = sectionOrder.firstIndex(of: source),
              let targetIndex = sectionOrder.firstIndex(of: destination) else { return }
        sectionOrder.swapAt(sourceIndex, targetIndex)
        defaults.set(try? JSONEncoder().encode(sectionOrder), forKey: "sidebarSectionOrder")
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: "sidebarEnabled")
    }

    func setSavesHistory(_ enabled: Bool) {
        positionSave?.cancel()
        savesHistory = enabled
        defaults.set(enabled, forKey: "sidebarSavesHistory")
        persistHistory()
    }

    func recordOpening(_ url: URL, now: Date = Date()) {
        recordVisit(url, title: "", now: now)
    }

    func recordVisit(_ url: URL, title: String, now: Date = Date()) {
        guard URLPolicy.canPreview(url), url.host?.isEmpty == false else { return }
        let previous = recentLinks.first { $0.address == url.absoluteString }
        recentLinks.removeAll { $0.address == url.absoluteString }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        recentLinks.insert(RecentLink(id: previous?.id ?? UUID(), address: url.absoluteString,
            title: title.isEmpty ? (previous?.title ?? url.host ?? url.absoluteString) : title,
            openedAt: now, position: previous?.position), at: 0)
        recentLinks = Array(recentLinks.prefix(Self.recentLimit))
        persistHistory()
    }

    func updatePosition(_ position: PagePosition, for url: URL) {
        guard position.isValid, let index = recentLinks.firstIndex(where: { $0.address == url.absoluteString }),
              recentLinks[index].position != position else { return }
        recentLinks[index].position = position
        // Scroll events update memory immediately; disk writes are coalesced.
        positionSave?.cancel()
        guard savesHistory else { return }
        positionSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.persistHistory()
        }
    }

    func recordClosing(_ url: URL, title: String, position: PagePosition?, revision: Int? = nil) {
        guard URLPolicy.canPreview(url), url.host?.isEmpty == false else { return }
        // Clearing/removing history must not be undone by a later close/scroll.
        // A still-open page evicted by the 200-item limit may rejoin on close.
        guard recentLinks.contains(where: { $0.address == url.absoluteString })
                || revision == historyRevision else { return }
        recordVisit(url, title: title)
        if let position, position.isValid { recentLinks[0].position = position }
        positionSave?.cancel()
        persistHistory()
    }

    func flushHistory() {
        positionSave?.cancel()
        persistHistory()
    }

    func updateTitle(_ title: String, for url: URL) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = recentLinks.firstIndex(where: { $0.address == url.absoluteString }),
              recentLinks[index].title != title else { return }
        recentLinks[index].title = title
        persistHistory()
    }

    func removeRecent(_ link: RecentLink) {
        historyRevision += 1
        recentLinks.removeAll { $0.id == link.id }
        persistHistory()
    }

    func clearHistory() {
        historyRevision += 1
        positionSave?.cancel()
        isHistoryClearPending = false
        recentLinks = []
        resetRecentDisplayLimit()
        defaults.removeObject(forKey: "recentLinks")
    }

    @discardableResult
    func addFolder(name: String) -> BookmarkFolder? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let folder = BookmarkFolder(id: UUID(), name: name)
        folders.append(folder)
        rootOrder.append(folder.id)
        expandedFolderIDs.insert(folder.id)
        persistFolders()
        return folder
    }

    func renameFolder(_ folder: BookmarkFolder, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].name = name
        persistFolders()
    }

    func removeFolder(_ folder: BookmarkFolder) {
        let children = settings?.favoriteSites.filter { folderID(for: $0) == folder.id }.map(\.id) ?? []
        if let index = rootOrder.firstIndex(of: folder.id) {
            rootOrder.replaceSubrange(index...index, with: children)
        }
        folders.removeAll { $0.id == folder.id }
        folderAssignments = folderAssignments.filter { $0.value != folder.id }
        expandedFolderIDs.remove(folder.id)
        persistFolders()
    }

    func folderID(for site: FavoriteSite) -> UUID? {
        guard let id = folderAssignments[site.id.uuidString], folders.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func moveBookmark(_ site: FavoriteSite, to folderID: UUID?) {
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else { return }
        guard self.folderID(for: site) != folderID else { return }
        folderAssignments[site.id.uuidString] = folderID
        if let folderID { expandedFolderIDs.insert(folderID) }
        rootOrder.removeAll { $0 == site.id }
        if folderID == nil { rootOrder.append(site.id) }
        persistFolders()
    }

    /// The root mixes folder and bookmark IDs. Quick Search uses its depth-first, folder-free order.
    func bind(to settings: SearchSettings) {
        guard self.settings !== settings else { return }
        self.settings = settings
        settings.bookmarksChanged = { [weak self] in self?.reconcileBookmarks() }
        settings.moveOrganizedBookmark = { [weak self, weak settings] id, destination in
            let folder = destination.flatMap { target in settings?.favoriteSites.first(where: { $0.id == target }) }.flatMap { self?.folderID(for: $0) }
            self?.moveItem(id, before: destination, into: folder)
        }
        reconcileBookmarks()
    }

    private func reconcileBookmarks() {
        guard let settings else { return }
        let sites = settings.favoriteSites
        let validSites = Set(sites.map { $0.id.uuidString })
        folderAssignments = folderAssignments.filter { entry in validSites.contains(entry.key) && folders.contains(where: { $0.id == entry.value }) }
        let roots = sites.filter { folderID(for: $0) == nil }.map(\.id)
        let validRoots = Set(roots + folders.map(\.id))
        var seen = Set<UUID>()
        rootOrder = rootOrder.filter { validRoots.contains($0) && seen.insert($0).inserted }
        rootOrder.append(contentsOf: roots.filter { !rootOrder.contains($0) })
        rootOrder.append(contentsOf: folders.map(\.id).filter { !rootOrder.contains($0) })
        persistFolders()
    }

    func moveItem(_ id: UUID, before destination: UUID?, into folder: UUID? = nil) {
        guard id != destination, let settings,
              folder == nil || folders.contains(where: { $0.id == folder }) else { return }
        if let site = settings.favoriteSites.first(where: { $0.id == id }) {
            folderAssignments[site.id.uuidString] = folder
            if let folder { expandedFolderIDs.insert(folder) }
            rootOrder.removeAll { $0 == id }
            if folder == nil {
                let index = destination.flatMap { rootOrder.firstIndex(of: $0) } ?? rootOrder.endIndex
                rootOrder.insert(id, at: index)
            } else {
                settings.reorderBookmark(id, before: destination)
            }
        } else if folders.contains(where: { $0.id == id }), folder == nil {
            rootOrder.removeAll { $0 == id }
            let index = destination.flatMap { rootOrder.firstIndex(of: $0) } ?? rootOrder.endIndex
            rootOrder.insert(id, at: index)
        } else { return }
        persistFolders()
    }

    func moveItem(_ id: UUID, offset: Int) {
        if let index = rootOrder.firstIndex(of: id), rootOrder.indices.contains(index + offset) {
            rootOrder.swapAt(index, index + offset)
            persistFolders()
        } else if let settings, let site = settings.favoriteSites.first(where: { $0.id == id }), let folder = folderID(for: site) {
            let children = settings.favoriteSites.filter { folderID(for: $0) == folder }.map(\.id)
            guard let index = children.firstIndex(of: id), children.indices.contains(index + offset) else { return }
            let target = offset < 0 ? children[index + offset] : (children.indices.contains(index + 2) ? children[index + 2] : nil)
            moveItem(id, before: target, into: folder)
        }
    }

    private func persistFolders() {
        defaults.set(try? JSONEncoder().encode(rootOrder), forKey: "bookmarkRootOrder")
        if let settings {
            let sites = settings.favoriteSites
            let ordered = rootOrder.flatMap { id -> [UUID] in
                if folders.contains(where: { $0.id == id }) { return sites.filter { folderID(for: $0) == id }.map(\.id) }
                return [id]
            }
            settings.setBookmarkOrder(ordered)
        }
        defaults.set(try? JSONEncoder().encode(folders), forKey: "bookmarkFolders")
        defaults.set(try? JSONEncoder().encode(folderAssignments), forKey: "bookmarkFolderAssignments")
    }

    private func persistHistory() {
        if savesHistory { defaults.set(try? JSONEncoder().encode(recentLinks), forKey: "recentLinks") }
        else { defaults.removeObject(forKey: "recentLinks") }
    }

    private static func read<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

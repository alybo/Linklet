import Foundation

struct BookmarkFolder: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
}

struct RecentLink: Codable, Equatable, Identifiable {
    let id: UUID
    let address: String
    var title: String
    var openedAt: Date
    var url: URL? { URL(string: address).flatMap { URLPolicy.canPreview($0) ? $0 : nil } }
}

/// Explicit bookmarks persist. Recent incoming links stay in memory unless saving is enabled.
@MainActor
final class LinkLibrary: ObservableObject {
    static let recentLimit = 200
    @Published private(set) var isEnabled: Bool
    @Published private(set) var savesHistory: Bool
    @Published private(set) var folders: [BookmarkFolder]
    @Published private(set) var folderAssignments: [String: UUID]
    @Published private(set) var recentLinks: [RecentLink]
    @Published var expandedFolderIDs: Set<UUID>
    @Published var showsRecentLinks = true
    @Published var shortcutError: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: "sidebarEnabled")
        let saves = defaults.bool(forKey: "sidebarSavesHistory")
        savesHistory = saves
        let savedFolders = Self.read([BookmarkFolder].self, key: "bookmarkFolders", defaults: defaults) ?? []
        folders = savedFolders
        folderAssignments = Self.read([String: UUID].self, key: "bookmarkFolderAssignments", defaults: defaults) ?? [:]
        expandedFolderIDs = Set(savedFolders.map(\.id))
        recentLinks = saves ? Array((Self.read([RecentLink].self, key: "recentLinks", defaults: defaults) ?? [])
            .filter { $0.url != nil }.prefix(Self.recentLimit)) : []
        if !saves { defaults.removeObject(forKey: "recentLinks") }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: "sidebarEnabled")
    }

    func setSavesHistory(_ enabled: Bool) {
        savesHistory = enabled
        defaults.set(enabled, forKey: "sidebarSavesHistory")
        persistHistory()
    }

    func recordOpening(_ url: URL, now: Date = Date()) {
        guard isEnabled, URLPolicy.canPreview(url) else { return }
        recentLinks.removeAll { $0.address == url.absoluteString }
        recentLinks.insert(RecentLink(id: UUID(), address: url.absoluteString,
                                     title: url.host ?? url.absoluteString, openedAt: now), at: 0)
        recentLinks = Array(recentLinks.prefix(Self.recentLimit))
        persistHistory()
    }

    func updateTitle(_ title: String, for url: URL) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = recentLinks.firstIndex(where: { $0.address == url.absoluteString }) else { return }
        recentLinks[index].title = title
        persistHistory()
    }

    func removeRecent(_ link: RecentLink) {
        recentLinks.removeAll { $0.id == link.id }
        persistHistory()
    }

    func clearHistory() {
        recentLinks = []
        defaults.removeObject(forKey: "recentLinks")
    }

    @discardableResult
    func addFolder(name: String) -> BookmarkFolder? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let folder = BookmarkFolder(id: UUID(), name: name)
        folders.append(folder)
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
        folderAssignments[site.id.uuidString] = folderID
        persistFolders()
    }

    private func persistFolders() {
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

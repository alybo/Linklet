import AppKit
import Carbon

struct FavoriteSite: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let address: String
    let faviconData: Data?

    var url: URL { URL(string: address)! }

    static func make(id: UUID = UUID(), name: String, address: String, faviconData: Data? = nil) -> FavoriteSite? {
        guard let url = URLPolicy.normalizedURL(from: address),
              let host = url.host, !host.isEmpty else { return nil }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return FavoriteSite(id: id, name: title.isEmpty ? host : title, address: url.absoluteString, faviconData: faviconData)
    }
}

enum FavoriteSiteError: LocalizedError, Equatable {
    case invalidURL
    case duplicateURL

    var errorDescription: String? {
        switch self {
        case .invalidURL: return L("Enter a valid HTTP or HTTPS address.")
        case .duplicateURL: return L("This website is already in Favorites.")
        }
    }
}

struct SearchShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let initial = SearchShortcut(keyCode: 49, modifiers: UInt32(controlKey | optionKey), keyLabel: "Space")
    var title: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + (keyLabel == "Space" ? L("Space") : keyLabel)
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              ![36, 48, 51, 53, 76, 117].contains(event.keyCode) else { return nil }
        var modifiers: UInt32 = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.command, cmdKey), (.control, controlKey), (.option, optionKey), (.shift, shiftKey)] {
            if flags.contains(flag) { modifiers |= UInt32(carbon) }
        }
        let label = event.keyCode == 49 ? "Space" : event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        guard !label.isEmpty, label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
    }
}

/// Registers a single system hotkey without monitoring other apps' keystrokes.
@MainActor
final class SearchHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    private var isPressed = false
    private let identifier: UInt32

    init(identifier: UInt32 = 1) { self.identifier = identifier }

    func register(_ shortcut: SearchShortcut?) -> Bool {
        unregister()
        guard let shortcut else { return true }
        var systemKeys: Unmanaged<CFArray>?
        if CopySymbolicHotKeys(&systemKeys) == noErr,
           let keys = systemKeys?.takeRetainedValue() as? [[String: Any]],
           keys.contains(where: {
               ($0[kHISymbolicHotKeyEnabled as String] as? Bool) == true &&
               ($0[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == shortcut.keyCode &&
               ($0[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == shortcut.modifiers
           }) { return false }
        if handler == nil {
            var events = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                      identifier.signature == 0x4C4E4B53 else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let hotKey = Unmanaged<SearchHotKey>.fromOpaque(context).takeUnretainedValue()
                    guard identifier.id == hotKey.identifier else { return OSStatus(eventNotHandledErr) }
                    hotKey.handle(pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
                    return noErr
                }
            }, 2, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return false }
        }
        let identifier = EventHotKeyID(signature: 0x4C4E4B53, id: self.identifier)
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                   GetApplicationEventTarget(), 0, &reference) == noErr
    }

    private func handle(pressed: Bool) {
        guard pressed else { isPressed = false; return }
        guard !isPressed else { return }
        isPressed = true
        action?()
    }

    func unregister() {
        isPressed = false
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor
final class SearchSettings: ObservableObject {
    private enum PreferenceKey {
        static let favoriteSites = "favoriteSites"
        static let showsFavoriteSites = "showsFavoriteSites"
    }

    @Published private(set) var engine: SearchEngine
    @Published private(set) var shortcut: SearchShortcut?
    @Published private(set) var favoriteSites: [FavoriteSite]
    @Published private(set) var showsFavoriteSites: Bool
    @Published private(set) var loadingFavoriteIconIDs = Set<UUID>()
    @Published var shortcutError: String?
    @Published private(set) var siteIcons: [String: Data] = [:]
    var bookmarksChanged: (() -> Void)?
    var moveOrganizedBookmark: ((UUID, UUID?) -> Void)?
    private var iconRequests: [String: Task<Void, Never>] = [:]
    private var attemptedIcons = Set<String>()
    private let fetchIcon: (URL) async throws -> Data
    private let defaults: UserDefaults
    private let hotKey = SearchHotKey()
    private var isStarted = false

    init(defaults: UserDefaults, fetchIcon: @escaping (URL) async throws -> Data = FavoriteSiteIconService.fetch) {
        self.fetchIcon = fetchIcon
        self.defaults = defaults
        engine = SearchEngine(rawValue: defaults.string(forKey: "searchEngine") ?? "") ?? .google
        if defaults.bool(forKey: "searchShortcutDisabled") {
            shortcut = nil
        } else {
            shortcut = defaults.data(forKey: "searchShortcut").flatMap { try? JSONDecoder().decode(SearchShortcut.self, from: $0) } ?? .initial
        }
        favoriteSites = (defaults.data(forKey: PreferenceKey.favoriteSites)
            .flatMap { try? JSONDecoder().decode([FavoriteSite].self, from: $0) } ?? [])
            .compactMap { FavoriteSite.make(id: $0.id, name: $0.name, address: $0.address, faviconData: $0.faviconData) }
        showsFavoriteSites = defaults.object(forKey: PreferenceKey.showsFavoriteSites) as? Bool ?? true
        for site in favoriteSites {
            if let data = site.faviconData, let origin = Self.iconOrigin(site.url) { siteIcons[origin] = data }
        }
    }

    func start(action: @escaping () -> Void) {
        hotKey.action = action
        isStarted = true
        resumeShortcut()
    }

    func setEngine(_ engine: SearchEngine) {
        self.engine = engine
        defaults.set(engine.rawValue, forKey: "searchEngine")
    }

    var shouldShowFavoriteSites: Bool { showsFavoriteSites && !favoriteSites.isEmpty }

    func setShowsFavoriteSites(_ visible: Bool) {
        showsFavoriteSites = visible
        defaults.set(visible, forKey: PreferenceKey.showsFavoriteSites)
    }

    @discardableResult
    func addFavoriteSite(name: String, address: String) throws -> FavoriteSite {
        let site = try validatedFavoriteSite(id: UUID(), name: name, address: address, excluding: nil)
        favoriteSites.append(site)
        persistFavoriteSites()
        return site
    }

    func updateFavoriteSite(_ site: FavoriteSite, name: String, address: String) throws {
        let replacement = try validatedFavoriteSite(id: site.id, name: name, address: address, excluding: site.id)
        guard let index = favoriteSites.firstIndex(where: { $0.id == site.id }) else { return }
        favoriteSites[index] = FavoriteSite(id: replacement.id, name: replacement.name, address: replacement.address, faviconData: iconData(for: replacement.url))
        persistFavoriteSites()
    }

    static func iconOrigin(_ url: URL) -> String? {
        guard URLPolicy.canPreview(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = ""; parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        return parts.url?.absoluteString
    }

    func iconData(for url: URL) -> Data? {
        guard let origin = Self.iconOrigin(url) else { return nil }
        return siteIcons[origin] ?? favoriteSites.first(where: { Self.iconOrigin($0.url) == origin && $0.faviconData != nil })?.faviconData
    }

    func ensureIcon(for url: URL, refresh: Bool = false) async {
        guard let origin = Self.iconOrigin(url), let originURL = URL(string: origin) else { return }
        if let request = iconRequests[origin] { await request.value; return }
        guard refresh || (iconData(for: url) == nil && !attemptedIcons.contains(origin)) else { return }
        attemptedIcons.insert(origin)
        // History-only icons live in this bounded memory cache. Only saved bookmark icons go to disk.
        if attemptedIcons.count > 512 { attemptedIcons = [origin] }
        let ids = favoriteSites.filter { Self.iconOrigin($0.url) == origin }.map(\.id)
        loadingFavoriteIconIDs.formUnion(ids)
        let request = Task { [weak self, fetchIcon] in
            guard let data = try? await fetchIcon(originURL), let self else { return }
            if self.siteIcons.count >= 256, let key = self.siteIcons.keys.first {
                self.siteIcons.removeValue(forKey: key)
                self.attemptedIcons.remove(key)
            }
            self.siteIcons[origin] = data
            self.favoriteSites = self.favoriteSites.map { site in
                guard Self.iconOrigin(site.url) == origin else { return site }
                return FavoriteSite(id: site.id, name: site.name, address: site.address, faviconData: data)
            }
            self.persistFavoriteSites()
        }
        iconRequests[origin] = request
        await request.value
        iconRequests.removeValue(forKey: origin)
        loadingFavoriteIconIDs.subtract(ids)
    }

    func loadFavoriteIcon(for site: FavoriteSite) {
        Task { await ensureIcon(for: site.url, refresh: true) }
    }

    func setBookmarkOrder(_ ids: [UUID]) {
        let byID = Dictionary(uniqueKeysWithValues: favoriteSites.map { ($0.id, $0) })
        let ordered = ids.compactMap { byID[$0] }
        guard ordered.count == favoriteSites.count, Set(ids).count == ids.count, ordered != favoriteSites else { return }
        favoriteSites = ordered
        defaults.set(try? JSONEncoder().encode(favoriteSites), forKey: PreferenceKey.favoriteSites)
    }

    func reorderBookmark(_ id: UUID, before destination: UUID?) {
        guard let index = favoriteSites.firstIndex(where: { $0.id == id }) else { return }
        let site = favoriteSites.remove(at: index)
        let position = destination.flatMap { target in favoriteSites.firstIndex(where: { $0.id == target }) } ?? favoriteSites.endIndex
        favoriteSites.insert(site, at: position)
    }

    func removeFavoriteSite(_ site: FavoriteSite) {
        favoriteSites.removeAll { $0.id == site.id }
        persistFavoriteSites()
    }

    func moveFavoriteSite(_ id: UUID, before destination: UUID?) {
        if let moveOrganizedBookmark { moveOrganizedBookmark(id, destination); return }
        guard id != destination, let source = favoriteSites.firstIndex(where: { $0.id == id }) else { return }
        let site = favoriteSites.remove(at: source)
        let position = destination.flatMap { target in favoriteSites.firstIndex(where: { $0.id == target }) } ?? favoriteSites.endIndex
        favoriteSites.insert(site, at: position)
        persistFavoriteSites()
    }

    func moveFavoriteSite(_ id: UUID, offset: Int) {
        guard let index = favoriteSites.firstIndex(where: { $0.id == id }),
              favoriteSites.indices.contains(index + offset) else { return }
        if let moveOrganizedBookmark {
            let targetIndex = offset < 0 ? index + offset : index + offset + 1
            let destination = favoriteSites.indices.contains(targetIndex) ? favoriteSites[targetIndex].id : nil
            moveOrganizedBookmark(id, destination)
            return
        }
        favoriteSites.swapAt(index, index + offset)
        persistFavoriteSites()
    }

    private func validatedFavoriteSite(id: UUID, name: String, address: String, excluding excludedID: UUID?) throws -> FavoriteSite {
        guard let site = FavoriteSite.make(id: id, name: name, address: address) else { throw FavoriteSiteError.invalidURL }
        guard !favoriteSites.contains(where: { $0.id != excludedID && $0.address == site.address }) else {
            throw FavoriteSiteError.duplicateURL
        }
        return FavoriteSite(id: site.id, name: site.name, address: site.address, faviconData: iconData(for: site.url))
    }

    private func persistFavoriteSites() {
        bookmarksChanged?()
        defaults.set(try? JSONEncoder().encode(favoriteSites), forKey: PreferenceKey.favoriteSites)
    }

    @discardableResult
    func setShortcut(_ value: SearchShortcut?) -> Bool {
        if isStarted && !hotKey.register(value) {
            _ = hotKey.register(shortcut)
            shortcutError = L("This shortcut is unavailable. Choose another combination.")
            return false
        }
        shortcut = value
        defaults.set(value == nil, forKey: "searchShortcutDisabled")
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: "searchShortcut")
        shortcutError = nil
        return true
    }

    func suspendShortcut() { hotKey.unregister() }
    func resumeShortcut() {
        guard isStarted else { return }
        shortcutError = hotKey.register(shortcut) ? nil : L("This shortcut is unavailable. Choose another combination.")
    }
}

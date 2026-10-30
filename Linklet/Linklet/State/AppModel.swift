import AppKit
import Combine
import ServiceManagement
import WebKit

enum PreviewWindowBehavior: String, CaseIterable, Identifiable {
    case hide
    case keepOpen
    case stayOnTop

    var id: Self { self }

    var title: String {
        switch self {
        case .hide: return L("Hide preview")
        case .keepOpen: return L("Keep open")
        case .stayOnTop: return L("Keep on top")
        }
    }

    var detail: String {
        switch self {
        case .hide: return L("The preview hides when you switch to another app.")
        case .keepOpen: return L("The preview stays open; other windows can appear in front of it.")
        case .stayOnTop: return L("The preview stays visible above other applications.")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    private enum PreferenceKey {
        static let showsFullURL = "showsFullURL"
        static let sortsTargetsByUsage = "sortsTargetsByUsage"
        static let hiddenTargetIDs = "hiddenTargetIDs"
        static let targetUsageCounts = "targetUsageCounts"
        static let keepsPreviewVisibleWhenInactive = "keepsPreviewVisibleWhenInactive"
        static let keepsPreviewAboveOtherWindows = "keepsPreviewAboveOtherWindows"
        static let opensLinksInNewWindows = "opensLinksInNewWindows"
    }

    @Published var settingsPage: SettingsPage {
        didSet { defaults.set(settingsPage.rawValue, forKey: "settingsPage") }
    }
    @Published var isChoosingDataMode = false
    private var pendingPreviewURL: URL?
    private var pendingPreviewPosition: PagePosition?
    private var resumeAfterSettingsURL: URL?
    private var previewRequestID = UUID()
    @Published private var manualTargetOrder: [String]
    let searchSettings: SearchSettings
    let linkLibrary: LinkLibrary
    let siteData: SiteDataService
    let windowGeometry: WindowGeometryService
    let windowRegistry: BrowserWindowRegistry

    @Published private(set) var targets: [BrowserTarget] = []
    @Published private(set) var isDefaultBrowser = false
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var showsFullURL: Bool
    @Published private(set) var sortsTargetsByUsage: Bool
    @Published private(set) var keepsPreviewVisibleWhenInactive: Bool
    @Published private(set) var keepsPreviewAboveOtherWindows: Bool
    @Published private(set) var opensLinksInNewWindows: Bool
    @Published var statusMessage: String?

    @Published private var hiddenTargetIDs: Set<String>
    @Published private var targetUsageCounts: [String: Int]

    let previewSession: PreviewSession
    let appUpdates = AppUpdateService()
    let adBlockService: AdBlockService
    @Published private(set) var isAdBlockingEnabled: Bool

    private let defaults: UserDefaults
    private let discoverTargets: () -> [BrowserTarget]
    private let launchService = BrowserLaunchService()
    private let defaultBrowserService = DefaultBrowserService()
    private lazy var previewWindowController = PreviewWindowController(model: self)
    private lazy var searchWindowController = SearchWindowController(settings: searchSettings) { [weak self] url in
        self?.showPreview(url: url)
    }
    private lazy var sidebarWindowController = SidebarWindowController(model: self)
    private lazy var settingsWindowController = SettingsWindowController(model: self)
    private var childPreviewModels: [AppModel] = []
    private var onPreviewClosed: (() -> Void)?
    // Child preview models report Dock state to the coordinator that owns all windows.
    private var dockVisibilityHandler: (() -> Void)?
    private var sidebarActionHandler: (() -> Void)?
    private var windowObservations = Set<AnyCancellable>()
    var downloads: DownloadManager { windowRegistry.downloads }

    init(
        defaults: UserDefaults = .standard,
        siteData: SiteDataService? = nil,
        windowGeometry: WindowGeometryService? = nil,
        searchSettings: SearchSettings? = nil,
        linkLibrary: LinkLibrary? = nil,
        windowRegistry: BrowserWindowRegistry? = nil,
        discoverTargets: (() -> [BrowserTarget])? = nil
    ) {
        self.defaults = defaults
        self.searchSettings = searchSettings ?? SearchSettings(defaults: defaults)
        self.linkLibrary = linkLibrary ?? LinkLibrary(defaults: defaults)
        self.discoverTargets = discoverTargets ?? { BrowserDiscoveryService().discoverTargets() }
        settingsPage = SettingsPage(rawValue: defaults.string(forKey: "settingsPage") ?? "") ?? .general
        manualTargetOrder = defaults.stringArray(forKey: "manualTargetOrder") ?? []
        let data = siteData ?? SiteDataService(defaults: defaults)
        self.siteData = data
        self.windowGeometry = windowGeometry ?? WindowGeometryService(defaults: defaults)
        let registry = windowRegistry ?? BrowserWindowRegistry()
        self.windowRegistry = registry
        let blocker = AdBlockService(defaults: defaults)
        adBlockService = blocker
        previewSession = PreviewSession(adBlockService: blocker, siteData: data, windowRegistry: registry)
        isAdBlockingEnabled = blocker.isEnabled
        showsFullURL = defaults.bool(forKey: PreferenceKey.showsFullURL)
        sortsTargetsByUsage = Self.bool(
            in: defaults,
            forKey: PreferenceKey.sortsTargetsByUsage,
            defaultValue: true
        )
        keepsPreviewVisibleWhenInactive = Self.bool(
            in: defaults,
            forKey: PreferenceKey.keepsPreviewVisibleWhenInactive,
            defaultValue: false
        )
        keepsPreviewAboveOtherWindows = Self.bool(
            in: defaults,
            forKey: PreferenceKey.keepsPreviewAboveOtherWindows,
            defaultValue: false
        )
        opensLinksInNewWindows = defaults.bool(forKey: PreferenceKey.opensLinksInNewWindows)
        hiddenTargetIDs = Set(defaults.stringArray(forKey: PreferenceKey.hiddenTargetIDs) ?? [])
        targetUsageCounts = (defaults.dictionary(forKey: PreferenceKey.targetUsageCounts) ?? [:])
            .reduce(into: [:]) { result, item in
                if let count = item.value as? NSNumber {
                    result[item.key] = count.intValue
                }
            }
        self.linkLibrary.bind(to: self.searchSettings)
        previewSession.onContinueInBrowser = { [weak self] in
            guard let self, let target = self.preferredTarget else { return }
            self.openOriginalURL(in: target)
        }
        previewSession.onSiteLoaded = { [weak self] url in
            guard let settings = self?.searchSettings else { return }
            Task { await settings.ensureIcon(for: url, refresh: true) }
        }
        previewSession.history = self.linkLibrary
        previewSession.makePopup = { [weak self] configuration, parent, features in
            WebPopupWindowController(configuration: configuration, parent: parent, features: features, model: self)
        }
        registry.$windows.map { !$0.isEmpty }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.updateDockVisibilitySoon() }.store(in: &windowObservations)
        registry.downloads.$activeCount.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.updateDockVisibilitySoon() }.store(in: &windowObservations)
    }

    var manuallyOrderedTargets: [BrowserTarget] {
        targets.sorted { lhs, rhs in
            let left = manualTargetOrder.firstIndex(of: lhs.id) ?? Int.max
            let right = manualTargetOrder.firstIndex(of: rhs.id) ?? Int.max
            if left != right { return left < right }
            return (targets.firstIndex(of: lhs) ?? 0) < (targets.firstIndex(of: rhs) ?? 0)
        }
    }

    var orderedTargets: [BrowserTarget] {
        let manual = manuallyOrderedTargets
        guard sortsTargetsByUsage else { return manual }
        return manual.enumerated().sorted {
            let left = targetUsageCount($0.element), right = targetUsageCount($1.element)
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
    }

    var visibleTargets: [BrowserTarget] { orderedTargets.filter { isTargetVisible($0) } }

    func moveTarget(_ id: String, before destination: String?) {
        guard !sortsTargetsByUsage, id != destination else { return }
        var ids = manuallyOrderedTargets.map(\.id)
        guard ids.contains(id) else { return }
        ids.removeAll { $0 == id }
        let position = destination.flatMap { ids.firstIndex(of: $0) } ?? ids.endIndex
        ids.insert(id, at: position)
        manualTargetOrder = ids
        defaults.set(ids, forKey: "manualTargetOrder")
    }

    func moveTarget(_ id: String, offset: Int) {
        var ids = manuallyOrderedTargets.map(\.id)
        guard !sortsTargetsByUsage, let index = ids.firstIndex(of: id),
              ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        manualTargetOrder = ids
        defaults.set(ids, forKey: "manualTargetOrder")
    }

    var preferredTarget: BrowserTarget? {
        visibleTargets.first
    }

    var previewWindowBehavior: PreviewWindowBehavior {
        if !keepsPreviewVisibleWhenInactive { return .hide }
        return keepsPreviewAboveOtherWindows ? .stayOnTop : .keepOpen
    }

    func setPreviewWindowBehavior(_ behavior: PreviewWindowBehavior) {
        // Retain the existing preference keys so previous settings migrate naturally.
        setKeepsPreviewAboveOtherWindows(behavior == .stayOnTop)
        setKeepsPreviewVisibleWhenInactive(behavior != .hide)
    }

    var previewOpenTargets: [BrowserTarget] {
        guard let preferredTarget else { return [] }
        return [preferredTarget] + visibleTargets.filter { $0.id != preferredTarget.id }
    }

    func refreshTargets() {
        targets = discoverTargets()
        let newIDs = targets.map(\.id).filter { !manualTargetOrder.contains($0) }
        if !newIDs.isEmpty {
            manualTargetOrder.append(contentsOf: newIDs)
            defaults.set(manualTargetOrder, forKey: "manualTargetOrder")
        }
        refreshDefaultBrowserStatus()
        isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func startSearchShortcut() {
        // Prepare the panel once; the hotkey path performs no asynchronous work.
        _ = searchWindowController
        searchSettings.start { [weak self] in self?.toggleSearch() }
    }

    func startSidebar() { _ = sidebarWindowController }
    func toggleSidebar() {
        if let sidebarActionHandler { sidebarActionHandler() }
        else { sidebarWindowController.toggle() }
    }

    func showDownloads() { sidebarWindowController.showDownloads() }

    func toggleSearch() { searchWindowController.toggle() }

    func handleIncoming(urls: [URL]) {
        if let query = urls.compactMap(SearchRequest.query).first {
            showPreview(url: searchSettings.engine.searchURL(for: query))
            return
        }
        guard let url = urls.first(where: URLPolicy.canPreview) else {
            statusMessage = L("Linklet received no previewable web links.")
            return
        }

        showPreview(url: url)
    }

    func showPreview(url: URL, restoring position: PagePosition? = nil) {
        if opensLinksInNewWindows, siteData.hasChosenMode, hasVisiblePreviewWindow {
            showPreviewInNewWindow(url: url, restoring: position)
            return
        }
        searchWindowController.close()
        previewRequestID = UUID()
        pendingPreviewURL = url
        pendingPreviewPosition = position
        resumeAfterSettingsURL = nil
        previewSession.endSession(resetTemporaryData: false)
        if !siteData.hasChosenMode {
            isChoosingDataMode = true
            previewWindowController.showDataChoice(for: url)
        } else {
            isChoosingDataMode = false
            pendingPreviewURL = nil
            pendingPreviewPosition = nil
            previewWindowController.show(url: url, restoring: position)
        }
    }

    func completeDataChoice(save: Bool) {
        guard let url = pendingPreviewURL else { return }
        isChoosingDataMode = false
        siteData.selectModeForPreview(save)
        pendingPreviewURL = nil
        let position = pendingPreviewPosition
        pendingPreviewPosition = nil
        previewWindowController.show(url: url, restoring: position)
    }

    func showRecentLink(_ link: RecentLink) {
        guard let url = link.url else { return }
        showPreview(url: url, restoring: link.position)
    }

    func openDataSettingsFromChoice() {
        let url = pendingPreviewURL
        isChoosingDataMode = false
        previewWindowController.close()
        resumeAfterSettingsURL = url
        showSettings(page: .sites)
    }

    func settingsDidClose() {
        guard let url = resumeAfterSettingsURL else { return }
        resumeAfterSettingsURL = nil
        siteData.markModeChosen()
        showPreview(url: url)
    }

    func previewDidEnd() {
        previewRequestID = UUID()
        pendingPreviewURL = nil
        pendingPreviewPosition = nil
        isChoosingDataMode = false
        previewSession.endSession()
        if siteData.isEnabled { Task { await siteData.refresh() } }
        onPreviewClosed?()
        updateDockVisibilitySoon()
        if onPreviewClosed == nil { focusRemainingPreviewWindowSoon() }
    }

    func startSiteDataMaintenance() {
        siteData.startBackgroundMaintenance()
    }

    func previewApplicationDidHide() {
        if !keepsPreviewVisibleWhenInactive || NSApp.isHidden {
            closeAllPreviewWindows()
        }
    }

    func setSavesSiteData(_ enabled: Bool) async {
        closeAllPreviewWindows()
        await siteData.setEnabled(enabled)
    }

    func deleteSiteData(_ record: WKWebsiteDataRecord?) async {
        closeAllPreviewWindows()
        await siteData.delete(record)
    }

    func openOriginalURL(in target: BrowserTarget, session: PreviewSession? = nil) {
        let source = session ?? previewSession
        guard let url = source.originalURL else { return }
        let navigationID = source.navigationID

        launchService.open(url, in: target) { [weak self, weak source] error in
            guard let self, let source, source.isActive, source.navigationID == navigationID else { return }
            if let error {
                self.statusMessage = error.localizedDescription
                source.errorMessage = error.localizedDescription
            } else {
                self.recordUsage(of: target)
                self.windowRegistry.close(source.windowID)
            }
        }
    }

    func makeDefaultBrowser() {
        Task {
            do {
                try await defaultBrowserService.makeLinkletDefault()
                refreshDefaultBrowserStatus()
                statusMessage = isDefaultBrowser
                    ? L("Linklet is now your default link handler.")
                    : L("macOS has not confirmed the default browser change yet.")
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func setLaunchAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            statusMessage = isLaunchAtLoginEnabled
                ? L("Linklet will stay ready after you sign in.")
                : L("Launch at login is turned off.")
        } catch {
            isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            statusMessage = error.localizedDescription
        }
    }

    func setAdBlockingEnabled(_ enabled: Bool) {
        isAdBlockingEnabled = enabled
        adBlockService.setEnabled(enabled)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await adBlockService.waitForPolicyUpdate()
            if let error = adBlockService.errorMessage { statusMessage = error; return }
            // Keep the WKWebView, back/forward list, popup opener and original URL.
            windowRegistry.activeSessions.forEach { $0.reload() }
        }
    }

    func setShowsFullURL(_ enabled: Bool) {
        showsFullURL = enabled
        defaults.set(enabled, forKey: PreferenceKey.showsFullURL)
    }

    func setOpensLinksInNewWindows(_ enabled: Bool) {
        opensLinksInNewWindows = enabled
        defaults.set(enabled, forKey: PreferenceKey.opensLinksInNewWindows)
    }

    func setSortTargetsByUsage(_ enabled: Bool) {
        sortsTargetsByUsage = enabled
        defaults.set(enabled, forKey: PreferenceKey.sortsTargetsByUsage)
    }

    func isTargetVisible(_ target: BrowserTarget) -> Bool {
        !hiddenTargetIDs.contains(target.id)
    }

    func setTargetVisible(_ target: BrowserTarget, isVisible: Bool) {
        if isVisible {
            hiddenTargetIDs.remove(target.id)
        } else {
            hiddenTargetIDs.insert(target.id)
        }
        defaults.set(hiddenTargetIDs.sorted(), forKey: PreferenceKey.hiddenTargetIDs)
    }

    func targetUsageCount(_ target: BrowserTarget) -> Int {
        targetUsageCounts[target.id, default: 0]
    }

    func resetTargetUsage() {
        targetUsageCounts = [:]
        defaults.removeObject(forKey: PreferenceKey.targetUsageCounts)
    }

    func setKeepsPreviewVisibleWhenInactive(_ enabled: Bool) {
        keepsPreviewVisibleWhenInactive = enabled
        defaults.set(enabled, forKey: PreferenceKey.keepsPreviewVisibleWhenInactive)
    }

    func setKeepsPreviewAboveOtherWindows(_ enabled: Bool) {
        keepsPreviewAboveOtherWindows = enabled
        defaults.set(enabled, forKey: PreferenceKey.keepsPreviewAboveOtherWindows)
    }

    func showWelcomeIfNeeded() {
        guard !defaults.bool(forKey: "hasShownWelcome") else { return }
        // A link delivered during launch takes priority over onboarding.
        guard previewSession.currentURL == nil, pendingPreviewURL == nil, resumeAfterSettingsURL == nil else { return }
        showWelcome()
    }

    func showWelcome() {
        closeAllPreviewWindows()
        resumeAfterSettingsURL = nil
        refreshTargets()
        previewSession.onOpenSettings = { [weak self] in self?.showSettings() }
        previewWindowController.showWelcome()
        defaults.set(true, forKey: "hasShownWelcome")
    }

    func refreshDefaultBrowserStatus() {
        isDefaultBrowser = defaultBrowserService.isLinkletDefault()
        allPreviewModels.forEach { $0.previewSession.updateWelcomeStatus(isDefault: isDefaultBrowser) }
    }

    func setLanguage(_ selection: String) {
        AppLanguage.shared.set(selection)
        statusMessage = nil
        allPreviewModels.forEach { $0.previewSession.errorMessage = nil }
        settingsWindowController.window?.title = settingsPage.title
        for preview in allPreviewModels where preview.previewSession.isWelcome {
            preview.previewSession.showWelcome(isDefault: isDefaultBrowser)
        }
        objectWillChange.send()
    }

    func showSettings(page: SettingsPage? = nil) {
        searchWindowController.close()
        if let page { settingsPage = page }
        makeAppVisibleInDock()
        settingsWindowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
        updateDockVisibilitySoon()
    }

    func openDeveloperLink(_ address: String) {
        guard let url = URL(string: address) else { return }
        // Avoid routing our own links back through Linklet when it is the default browser.
        guard let target = preferredTarget ?? targets.first else { return }
        launchService.open(url, in: target) { [weak self] error in
            if let error { self?.statusMessage = error.localizedDescription }
        }
    }

    func savedWindowFrame(for url: URL) -> NSRect? {
        windowGeometry.frame(for: url)
    }

    func saveWindowFrame(_ frame: NSRect) {
        guard let url = previewSession.currentURL else { return }
        windowGeometry.save(frame, for: url)
    }

    func closeAllWindows() {
        // Do not resume the privacy setup flow after its Settings window closes.
        resumeAfterSettingsURL = nil
        closeAllPreviewWindows()
        settingsWindowController.close()
        if sidebarActionHandler == nil { sidebarWindowController.hide() }
        updateDockVisibilitySoon()
    }

    var hasOpenWindows: Bool {
        windowRegistry.hasWindows || settingsWindowController.window?.isVisible == true
    }

    private func recordUsage(of target: BrowserTarget) {
        targetUsageCounts[target.id, default: 0] += 1
        defaults.set(targetUsageCounts, forKey: PreferenceKey.targetUsageCounts)
    }

    private var allPreviewModels: [AppModel] { [self] + childPreviewModels }

    private var hasVisiblePreviewWindow: Bool {
        windowRegistry.hasVisibleWindows
    }

    private func showPreviewInNewWindow(url: URL, restoring position: PagePosition? = nil) {
        let referenceFrame = windowRegistry.lastVisibleFrame
        let child = AppModel(
            defaults: defaults,
            siteData: siteData,
            windowGeometry: windowGeometry,
            searchSettings: searchSettings,
            linkLibrary: linkLibrary,
            windowRegistry: windowRegistry,
            discoverTargets: discoverTargets
        )
        child.refreshTargets()
        if let referenceFrame {
            child.previewWindowController.positionInitially(after: referenceFrame)
        }
        child.sidebarActionHandler = { [weak self] in self?.toggleSidebar() }
        child.dockVisibilityHandler = { [weak self] in self?.updateDockVisibilitySoon() }
        child.onPreviewClosed = { [weak self, weak child] in
            guard let self, let child else { return }
            self.childPreviewModels.removeAll { $0 === child }
            self.updateDockVisibilitySoon()
            self.focusRemainingPreviewWindowSoon()
        }
        childPreviewModels.append(child)
        // This destination shares the registry with already visible pages. Present
        // it directly instead of routing it through the new-window decision again.
        child.previewWindowController.show(url: url, restoring: position)
    }

    private func closeAllPreviewWindows() {
        windowRegistry.closeAll()
    }

    func updateDockVisibilitySoon() {
        if let dockVisibilityHandler {
            dockVisibilityHandler()
            return
        }
        DispatchQueue.main.async { [weak self] in self?.updateDockVisibility() }
    }

    func makeAppVisibleInDock() {
        NSApp.setActivationPolicy(.regular)
    }

    private func focusRemainingPreviewWindowSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.isActive else { return }
            self.windowRegistry.activateLastWindow()
        }
    }

    private func updateDockVisibility() {
        NSApp.setActivationPolicy(hasOpenWindows || downloads.hasActiveDownloads ? .regular : .accessory)
    }

    private static func bool(
        in defaults: UserDefaults,
        forKey key: String,
        defaultValue: Bool
    ) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }
}

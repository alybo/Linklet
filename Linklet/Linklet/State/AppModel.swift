import AppKit
import ServiceManagement

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
    }

    @Published private(set) var targets: [BrowserTarget] = []
    @Published private(set) var isDefaultBrowser = false
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published private(set) var showsFullURL: Bool
    @Published private(set) var sortsTargetsByUsage: Bool
    @Published private(set) var keepsPreviewVisibleWhenInactive: Bool
    @Published private(set) var keepsPreviewAboveOtherWindows: Bool
    @Published var statusMessage: String?

    @Published private var hiddenTargetIDs: Set<String>
    @Published private var targetUsageCounts: [String: Int]

    let previewSession: PreviewSession
    let appUpdates = AppUpdateService()
    let adBlockService: AdBlockService
    @Published private(set) var isAdBlockingEnabled: Bool

    private let defaults: UserDefaults
    private let discoveryService = BrowserDiscoveryService()
    private let launchService = BrowserLaunchService()
    private let defaultBrowserService = DefaultBrowserService()
    private lazy var previewWindowController = PreviewWindowController(model: self)
    private lazy var settingsWindowController = SettingsWindowController(model: self)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let blocker = AdBlockService(defaults: defaults)
        adBlockService = blocker
        previewSession = PreviewSession(adBlockService: blocker)
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
        hiddenTargetIDs = Set(defaults.stringArray(forKey: PreferenceKey.hiddenTargetIDs) ?? [])
        targetUsageCounts = (defaults.dictionary(forKey: PreferenceKey.targetUsageCounts) ?? [:])
            .reduce(into: [:]) { result, item in
                if let count = item.value as? NSNumber {
                    result[item.key] = count.intValue
                }
            }
    }

    var visibleTargets: [BrowserTarget] {
        let visible = targets.filter { !hiddenTargetIDs.contains($0.id) }
        guard sortsTargetsByUsage else { return visible }

        return visible.enumerated()
            .sorted { lhs, rhs in
                let leftCount = targetUsageCounts[lhs.element.id, default: 0]
                let rightCount = targetUsageCounts[rhs.element.id, default: 0]
                return leftCount == rightCount ? lhs.offset < rhs.offset : leftCount > rightCount
            }
            .map { $0.element }
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
        targets = discoveryService.discoverTargets()
        refreshDefaultBrowserStatus()
        isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func handleIncoming(urls: [URL]) {
        guard let url = urls.first(where: URLPolicy.canPreview) else {
            statusMessage = L("Linklet received no previewable web links.")
            return
        }

        showPreview(url: url)
    }

    func showPreview(url: URL) {
        previewWindowController.show(url: url)
    }

    func openOriginalURL(in target: BrowserTarget) {
        guard let url = previewSession.originalURL else { return }

        launchService.open(url, in: target) { [weak self] error in
            if let error {
                self?.statusMessage = error.localizedDescription
                self?.previewSession.errorMessage = error.localizedDescription
            } else {
                self?.recordUsage(of: target)
                self?.previewWindowController.close()
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
        if !previewSession.isWelcome, let url = previewSession.currentURL {
            previewSession.load(url, preservingOriginalURL: true)
        }
    }

    func setShowsFullURL(_ enabled: Bool) {
        showsFullURL = enabled
        defaults.set(enabled, forKey: PreferenceKey.showsFullURL)
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
        guard previewSession.currentURL == nil else { return }
        showWelcome()
    }

    func showWelcome() {
        refreshTargets()
        previewSession.onOpenSettings = { [weak self] in self?.showSettings() }
        previewWindowController.showWelcome()
        defaults.set(true, forKey: "hasShownWelcome")
    }

    func refreshDefaultBrowserStatus() {
        isDefaultBrowser = defaultBrowserService.isLinkletDefault()
        previewSession.updateWelcomeStatus(isDefault: isDefaultBrowser)
    }

    func setLanguage(_ selection: String) {
        AppLanguage.shared.set(selection)
        statusMessage = nil
        previewSession.errorMessage = nil
        settingsWindowController.window?.title = L("Linklet Settings")
        if previewSession.isWelcome {
            previewSession.showWelcome(isDefault: isDefaultBrowser)
        }
        objectWillChange.send()
    }

    func showSettings() {
        settingsWindowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
    }

    private func recordUsage(of target: BrowserTarget) {
        targetUsageCounts[target.id, default: 0] += 1
        defaults.set(targetUsageCounts, forKey: PreferenceKey.targetUsageCounts)
    }

    private static func bool(
        in defaults: UserDefaults,
        forKey key: String,
        defaultValue: Bool
    ) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }
}

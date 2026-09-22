import Foundation
import WebKit

/// Owns only Linklet's website data. Browser profiles are never accessed.
@MainActor
final class SiteDataService: ObservableObject {
    static let enabledKey = "savesSiteData"
    static let choiceKey = "hasChosenSiteDataMode"
    static let daysKey = "siteDataInactiveDays"
    static let visitsKey = "siteDataLastVisits"
    static let firstSeenKey = "siteDataFirstSeen"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var inactiveDays: Int
    @Published private(set) var records: [WKWebsiteDataRecord] = []
    @Published private(set) var isBusy = false
    private let defaults: UserDefaults
    private let persistentStore: WKWebsiteDataStore
    private var temporaryStore = WKWebsiteDataStore.nonPersistent()
    private var operation: Task<Void, Never>?
    private var maintenanceTimer: Timer?
    private var scheduledMaintenance: Task<Void, Never>?
    private var activePreviewCount = 0
    private var visits: [String: Date]
    private var firstSeen: [String: Date]

    private static let maintenanceCheckInterval: TimeInterval = 60 * 60
    private static let maintenanceIdleDelay: TimeInterval = 3

    init(defaults: UserDefaults = .standard, persistentStore: WKWebsiteDataStore? = nil) {
        self.defaults = defaults
        self.persistentStore = persistentStore ?? .default()
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        let days = defaults.integer(forKey: Self.daysKey)
        inactiveDays = [7, 30, 90].contains(days) ? days : 0
        visits = defaults.dictionary(forKey: Self.visitsKey) as? [String: Date] ?? [:]
        firstSeen = defaults.dictionary(forKey: Self.firstSeenKey) as? [String: Date] ?? [:]
    }

    var hasChosenMode: Bool { defaults.bool(forKey: Self.choiceKey) }
    var dataStore: WKWebsiteDataStore { isEnabled ? persistentStore : temporaryStore }

    func markModeChosen() { defaults.set(true, forKey: Self.choiceKey) }

    func setEnabled(_ enabled: Bool) async {
        markModeChosen()
        await serialize {
            self.isEnabled = enabled
            self.defaults.set(enabled, forKey: Self.enabledKey)
            self.rotateTemporaryStore()
            if !enabled { await self.removeAllStoredData() }
            await self.fetchRecords()
        }
        scheduleMaintenanceIfIdle()
    }

    /// Chooses the storage mode for the first preview without making that preview
    /// wait for cleanup of data from an earlier session.
    func selectModeForPreview(_ enabled: Bool) {
        markModeChosen()
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        rotateTemporaryStore()
        scheduleMaintenanceIfIdle()
    }

    func setInactiveDays(_ days: Int) {
        guard [0, 7, 30, 90].contains(days) else { return }
        inactiveDays = days
        defaults.set(days, forKey: Self.daysKey)
        scheduleMaintenanceIfIdle()
    }

    func rotateTemporaryStore() {
        let old = temporaryStore
        temporaryStore = .nonPersistent()
        // The old view is detached before rotating. New pages can never reuse this store.
        old.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    func recordVisit(_ url: URL, now: Date = Date()) {
        guard isEnabled, let host = url.host?.lowercased(), !host.isEmpty else { return }
        visits[host] = now
        defaults.set(visits, forKey: Self.visitsKey)
    }

    static func host(_ host: String, belongsTo domain: String) -> Bool {
        let domain = domain.lowercased()
        let host = host.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }

    func lastVisit(for domain: String) -> Date? {
        visits.filter { Self.host($0.key, belongsTo: domain) }.values.max()
    }

    static func isExpired(lastActivity: Date, days: Int, now: Date) -> Bool {
        days > 0 && now.timeIntervalSince(lastActivity) >= Double(days) * 86_400
    }

    /// Starts idle maintenance after launch. It never holds up a preview load.
    func startBackgroundMaintenance() {
        guard maintenanceTimer == nil else { return }
        maintenanceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.maintenanceCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleMaintenanceIfIdle() }
        }
        scheduleMaintenanceIfIdle(includePrivateStoreCleanup: true)
    }

    /// Called by a preview just before it starts using a website data store.
    func previewSessionDidStart() {
        activePreviewCount += 1
        scheduledMaintenance?.cancel()
        scheduledMaintenance = nil
    }

    /// Called after a preview has detached from its website data store.
    func previewSessionDidEnd() {
        activePreviewCount = max(0, activePreviewCount - 1)
        scheduleMaintenanceIfIdle(includePrivateStoreCleanup: true)
    }

    /// Performs one maintenance pass when no preview is using persistent data.
    /// Kept internal so tests can verify expiry rules without relying on timers.
    func performIdleMaintenance(now: Date = Date()) async {
        guard activePreviewCount == 0 else { return }
        await serialize {
            guard self.activePreviewCount == 0 else { return }
            if !self.isEnabled {
                // Finish cleanup left behind by a crash or an earlier saved session.
                await self.removeAllStoredData()
                self.records = []
            } else {
                guard self.inactiveDays > 0 else { return }
                await self.fetchRecords(now: now)
                guard self.activePreviewCount == 0 else { return }
                let expired = self.records.filter { record in
                    let activity = self.lastVisit(for: record.displayName)
                        ?? self.firstSeen[record.displayName] ?? now
                    return Self.isExpired(lastActivity: activity, days: self.inactiveDays, now: now)
                }
                if !expired.isEmpty { await self.removeRecords(expired) }
                guard self.activePreviewCount == 0 else { return }
                await self.fetchRecords(now: now)
            }
        }
    }

    func refresh() async { await serialize { await self.fetchRecords() } }

    func delete(_ record: WKWebsiteDataRecord?) async {
        await serialize {
            if let record { await self.removeRecords([record]) }
            else { await self.removeAllStoredData() }
            await self.fetchRecords()
        }
    }

    private func serialize(_ body: @escaping @MainActor () async -> Void) async {
        let previous = operation
        let next = Task { @MainActor in
            await previous?.value
            self.isBusy = true
            await body()
            self.isBusy = false
        }
        operation = next
        await next.value
    }

    private func scheduleMaintenanceIfIdle(includePrivateStoreCleanup: Bool = false) {
        scheduledMaintenance?.cancel()
        scheduledMaintenance = nil
        guard maintenanceTimer != nil,
              activePreviewCount == 0,
              inactiveDays > 0 || (!isEnabled && includePrivateStoreCleanup)
        else { return }

        scheduledMaintenance = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.maintenanceIdleDelay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.activePreviewCount == 0 else { return }
            await self.performIdleMaintenance()
        }
    }

    private func fetchRecords(now: Date = Date()) async {
        records = await persistentStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        for record in records where firstSeen[record.displayName] == nil {
            // Third-party data ages from first discovery; background requests never refresh it.
            firstSeen[record.displayName] = now
        }
        let domains = Set(records.map(\.displayName))
        firstSeen = firstSeen.filter { domains.contains($0.key) }
        defaults.set(firstSeen, forKey: Self.firstSeenKey)
    }

    private func removeRecords(_ records: [WKWebsiteDataRecord]) async {
        await persistentStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        for record in records {
            visits = visits.filter { !Self.host($0.key, belongsTo: record.displayName) }
            firstSeen.removeValue(forKey: record.displayName)
        }
        saveDates()
    }

    private func removeAllStoredData() async {
        await persistentStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        visits = [:]
        firstSeen = [:]
        saveDates()
    }

    private func saveDates() {
        defaults.set(visits, forKey: Self.visitsKey)
        defaults.set(firstSeen, forKey: Self.firstSeenKey)
    }

    deinit {
        maintenanceTimer?.invalidate()
        scheduledMaintenance?.cancel()
    }
}

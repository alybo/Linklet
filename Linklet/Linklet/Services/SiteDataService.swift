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
    private var visits: [String: Date]
    private var firstSeen: [String: Date]

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
    }

    func setInactiveDays(_ days: Int) {
        guard [0, 7, 30, 90].contains(days) else { return }
        inactiveDays = days
        defaults.set(days, forKey: Self.daysKey)
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

    /// Call only at session boundaries, before loading any new website.
    func prepareForPreview(now: Date = Date()) async {
        await serialize {
            if !self.isEnabled {
                // Also finishes an interrupted deletion after an app crash/relaunch.
                await self.removeAllStoredData()
            } else {
                await self.fetchRecords(now: now)
                let expired = self.records.filter { record in
                    let activity = self.lastVisit(for: record.displayName)
                        ?? self.firstSeen[record.displayName] ?? now
                    return Self.isExpired(lastActivity: activity, days: self.inactiveDays, now: now)
                }
                if !expired.isEmpty { await self.removeRecords(expired) }
            }
            await self.fetchRecords(now: now)
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
}

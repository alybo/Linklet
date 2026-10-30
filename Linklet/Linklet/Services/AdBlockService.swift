import Foundation
import Combine
import WebKit
import CryptoKit
import ContentBlockerConverter
import OSLog

/// Owns only Linklet's rule list; website cookies remain in the ephemeral data store.
@MainActor
final class AdBlockService: ObservableObject {
    static let updateInterval: TimeInterval = 24 * 60 * 60
    static let enabledKey = "adGuardBlockingEnabled"
    static let siteOverridesKey = "adGuardSiteOverrides"
    private static let attemptKey = "adGuardLastUpdateAttempt"
    private let defaults: UserDefaults
    private let fetchFilters: @Sendable () async throws -> [String]
    private let cacheURL: URL
    private let store: WKContentRuleListStore
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let logger = Logger(subsystem: "Linklet", category: "AdGuard")
    private var ruleList: WKContentRuleList?
    private var preparation: Task<Void, Never>?
    private var update: Task<Void, Never>?
    private var timer: Timer?
    @Published private(set) var isEnabled: Bool
    @Published private(set) var siteOverrides: [String: Bool]
    @Published private(set) var errorMessage: String?
    private var sourceJSON: String?
    private var policyRevision = 0
    private var policyUpdate: Task<Void, Never>?
    var hasActiveRules: Bool { isEnabled || siteOverrides.values.contains(true) }

    init(defaults: UserDefaults = .standard, cacheDirectory: URL? = nil,
         automaticUpdates: Bool = true,
         fetchFilters: @escaping @Sendable () async throws -> [String] = { try await AdBlockService.downloadFilters() }) {
        self.fetchFilters = fetchFilters
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        siteOverrides = (defaults.dictionary(forKey: Self.siteOverridesKey) ?? [:]).reduce(into: [:]) { result, entry in
            if let host = Self.siteHost(entry.key), host == entry.key, let enabled = entry.value as? Bool {
                result[host] = enabled
            }
        }
        let directory = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Linklet/AdGuard", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cacheURL = directory.appendingPathComponent("rules-v1.json")
        store = WKContentRuleListStore(url: directory)!
        // An hourly wake-up checks the persisted 24-hour deadline, including after sleep.
        if automaticUpdates {
            timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkForUpdates() }
            }
            checkForUpdates()
        }
    }

    deinit { timer?.invalidate() }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        policyChanged()
    }

    /// Rules are scoped by top-level hostname inside the rule list, rather than
    /// removing rules from a shared controller (OAuth popups can share one).
    func isEnabled(for url: URL) -> Bool {
        guard let host = Self.siteHost(url.absoluteString) else { return false }
        return siteOverrides[host] ?? isEnabled
    }

    @discardableResult
    func setSiteEnabled(_ enabled: Bool, host input: String) -> Bool {
        guard let host = Self.siteHost(input) else { return false }
        guard siteOverrides[host] != enabled else { return true }
        siteOverrides[host] = enabled
        defaults.set(siteOverrides, forKey: Self.siteOverridesKey)
        policyChanged()
        return true
    }

    func removeSiteOverride(_ host: String) {
        guard siteOverrides.removeValue(forKey: host) != nil else { return }
        defaults.set(siteOverrides, forKey: Self.siteOverridesKey)
        policyChanged()
    }

    nonisolated static func siteHost(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value.contains("://") ? value : "https://" + value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, let host = url.host?.lowercased(),
              !host.isEmpty, !host.contains("*"), !host.contains(" ") else { return nil }
        let normalized = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !normalized.isEmpty, normalized.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45,46,58,91,93].contains($0) }) else { return nil }
        return normalized
    }

    private func policyChanged() {
        policyRevision += 1
        errorMessage = nil
        // Disabling the default with no positive override takes effect at once.
        if !hasActiveRules, let ruleList {
            for controller in controllers.allObjects { controller.remove(ruleList) }
        }
        policyUpdate?.cancel()
        policyUpdate = Task { @MainActor [weak self] in
            guard let self else { return }
            await prepareIfEnabled()
            if let sourceJSON {
                do { try await compileAndInstall(sourceJSON) }
                catch is CancellationError { }
                catch { errorMessage = L("Could not apply AdGuard settings. Try again.") }
            }
        }
        if hasActiveRules { checkForUpdates() }
        else { update?.cancel() }
    }

    func waitForPolicyUpdate() async {
        while true {
            let revision = policyRevision
            await policyUpdate?.value
            if revision == policyRevision { return }
        }
    }

    func attach(to controller: WKUserContentController) {
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        if hasActiveRules, let ruleList { controller.add(ruleList) }
    }

    /// Never waits for the network. The first navigation waits only for local rules.
    func prepareIfEnabled() async {
        guard hasActiveRules, ruleList == nil else { return }
        if let preparation { await preparation.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let cache = cacheURL
                if let json = try? await Task.detached(priority: .utility, operation: { try String(contentsOf: cache, encoding: .utf8) }).value {
                    do { try await compileAndInstall(json); return } catch { /* Rebuild damaged cache from bundled filters. */ }
                }
                let bundle = Bundle.main
                let urls = ["base", "russian"].compactMap {
                    bundle.url(forResource: $0, withExtension: "txt", subdirectory: "AdGuard")
                }
                guard urls.count == 2 else { throw BlockerError.missingBundledFilters }
                let json = try await Task.detached(priority: .utility) {
                    let texts = try urls.map { try String(contentsOf: $0, encoding: .utf8) }
                    return try Self.convert(texts)
                }.value
                try await compileAndInstall(json)
                try? await Task.detached(priority: .utility) { try Data(json.utf8).write(to: cache, options: .atomic) }.value
            } catch {
                errorMessage = L("Could not apply AdGuard settings. Try again.")
                logger.error("Cannot prepare local filters: \(error.localizedDescription, privacy: .public)")
            }
        }
        preparation = task
        await task.value
        preparation = nil
    }

    static func isUpdateDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= updateInterval || lastAttempt > now
    }

    func checkForUpdates() {
        guard hasActiveRules, update == nil else { return }
        let now = Date()
        guard Self.isUpdateDue(lastAttempt: defaults.object(forKey: Self.attemptKey) as? Date, now: now) else { return }
        update = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { update = nil }
            await prepareIfEnabled()
            guard hasActiveRules, !Task.isCancelled else { return }
            // Failed attempts also observe the daily limit; local filters stay active.
            defaults.set(Date(), forKey: Self.attemptKey)
            do {
                let texts = try await fetchFilters()
                try Task.checkCancellation()
                let json = try await Task.detached(priority: .utility) {
                    try Self.convert(texts)
                }.value
                try Task.checkCancellation()
                try await compileAndInstall(json)
                try Task.checkCancellation()
                guard hasActiveRules else { return }
                // Persist only a set successfully compiled by the installed WebKit.
                let cache = cacheURL
                try await Task.detached(priority: .utility) { try Data(json.utf8).write(to: cache, options: .atomic) }.value
                logger.info("AdGuard filters updated")
            } catch is CancellationError {
                // The user switched blocking off while the refresh was running.
            } catch {
                logger.error("Keeping previous filters: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func waitForUpdate() async { await update?.value }

    private func install(_ candidate: WKContentRuleList) {
        let previous = ruleList
        ruleList = candidate
        for controller in controllers.allObjects {
            if let previous { controller.remove(previous) }
            if hasActiveRules { controller.add(candidate) }
        }
        // A content hash avoids overwriting the last working compilation on failure.
        // Remove obsolete compiled versions, keeping the active list and JSON fallback.
        if let previous, previous.identifier != candidate.identifier {
            store.removeContentRuleList(forIdentifier: previous.identifier) { _ in }
        }
    }

    private func compileAndInstall(_ json: String) async throws {
        try Task.checkCancellation()
        sourceJSON = json
        while true {
            try Task.checkCancellation()
            let revision = policyRevision
            let enabled = isEnabled
            let overrides = siteOverrides
            let source = sourceJSON ?? json
            let combined = try await Task.detached(priority: .utility) {
                try Self.applyingPolicy(to: source, enabled: enabled, overrides: overrides)
            }.value
            let candidate = try await compile(combined)
            try Task.checkCancellation()
            guard revision == policyRevision, source == sourceJSON else { continue }
            install(candidate)
            errorMessage = nil
            return
        }
    }

    nonisolated static func applyingPolicy(to json: String, enabled: Bool, overrides: [String: Bool]) throws -> String {
        guard var rules = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
            throw BlockerError.invalidFilters
        }
        let hosts = overrides.filter { $0.value != enabled }.keys.sorted()
        if !enabled || !hosts.isEmpty {
            let expressions = hosts.flatMap { host in
                let prefix = "^https?://([^/@]*@)?" + NSRegularExpression.escapedPattern(for: host) + "\\.?"
                // WebKit's restricted regex dialect has no disjunctions or
                // noncapturing groups. Keep end-of-string as a separate pattern.
                return [prefix + "[/:?#]", prefix + "$"]
            }
            var trigger: [String: Any] = ["url-filter": ".*"]
            if expressions.isEmpty {
                // Default off with no overrides: ignore this complete list.
            } else {
                trigger[enabled ? "if-top-url" : "unless-top-url"] = expressions
            }
            rules.append(["trigger": trigger, "action": ["type": "ignore-previous-rules"]])
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]), as: UTF8.self)
    }

    private func compile(_ json: String) async throws -> WKContentRuleList {
        let identifier = await Task.detached(priority: .utility) {
            let digest = SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
            return "linklet-adguard-v1-" + digest
        }.value
        if let cached = try? await store.contentRuleList(forIdentifier: identifier) { return cached }
        guard let compiled = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
            throw BlockerError.invalidFilters
        }
        return compiled
    }

    nonisolated static func convert(_ texts: [String]) throws -> String {
        for text in texts { try validateFilter(text) }
        let lines = texts.flatMap { $0.components(separatedBy: .newlines) }
        // macOS 14's WebKit supports Safari 16.4 syntax; use it across all supported OS versions.
        let result = ContentBlockerConverter().convertArray(rules: lines, safariVersion: .safari16_4)
        guard result.safariRulesCount > 100, result.discardedSafariRules == 0 else {
            throw BlockerError.invalidFilters
        }
        return result.safariRulesJSON
    }

    nonisolated static func validateFilter(_ text: String) throws {
        guard text.utf8.count <= 15_000_000,
              text.hasPrefix("!"), text.contains("! Title: AdGuard"),
              text.contains("! Version:"), text.components(separatedBy: .newlines).count > 100 else {
            throw BlockerError.invalidFilters
        }
    }

    nonisolated static func downloadFilters() async throws -> [String] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var texts: [String] = []
        for id in [2, 1] {
            let url = URL(string: "https://filters.adtidy.org/extension/safari/filters/\(id)_optimized.txt")!
            let (data, response) = try await session.data(from: url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https", data.count <= 15_000_000,
                  let text = String(data: data, encoding: .utf8) else { throw BlockerError.invalidFilters }
            try validateFilter(text)
            texts.append(text)
        }
        return texts
    }

    enum BlockerError: Error {
        case invalidFilters
        case missingBundledFilters
    }
}

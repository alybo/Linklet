import Foundation
import WebKit
import CryptoKit
import ContentBlockerConverter
import OSLog

/// Owns only Linklet's rule list; website cookies remain in the ephemeral data store.
@MainActor
final class AdBlockService {
    static let updateInterval: TimeInterval = 24 * 60 * 60
    static let enabledKey = "adGuardBlockingEnabled"
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
    private(set) var isEnabled: Bool

    init(defaults: UserDefaults = .standard, cacheDirectory: URL? = nil,
         automaticUpdates: Bool = true,
         fetchFilters: @escaping @Sendable () async throws -> [String] = { try await AdBlockService.downloadFilters() }) {
        self.fetchFilters = fetchFilters
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
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
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        for controller in controllers.allObjects {
            if let ruleList {
                controller.remove(ruleList)
                if enabled { controller.add(ruleList) }
            }
        }
        if enabled {
            checkForUpdates()
        } else {
            update?.cancel()
        }
    }

    func attach(to controller: WKUserContentController) {
        controllers.add(controller)
        if isEnabled, let ruleList { controller.add(ruleList) }
    }

    /// Never waits for the network. The first navigation waits only for local rules.
    func prepareIfEnabled() async {
        guard isEnabled, ruleList == nil else { return }
        if let preparation { await preparation.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let json = try? String(contentsOf: cacheURL, encoding: .utf8),
                   let cached = try? await compile(json) {
                    install(cached)
                    return
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
                install(try await compile(json))
                try? Data(json.utf8).write(to: cacheURL, options: .atomic)
            } catch {
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
        guard isEnabled, update == nil else { return }
        let now = Date()
        guard Self.isUpdateDue(lastAttempt: defaults.object(forKey: Self.attemptKey) as? Date, now: now) else { return }
        update = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { update = nil }
            await prepareIfEnabled()
            guard isEnabled, !Task.isCancelled else { return }
            // Failed attempts also observe the daily limit; local filters stay active.
            defaults.set(Date(), forKey: Self.attemptKey)
            do {
                let texts = try await fetchFilters()
                try Task.checkCancellation()
                let json = try await Task.detached(priority: .utility) {
                    try Self.convert(texts)
                }.value
                try Task.checkCancellation()
                let candidate = try await compile(json)
                try Task.checkCancellation()
                guard isEnabled else { return }
                // Persist only a set successfully compiled by the installed WebKit.
                try Data(json.utf8).write(to: cacheURL, options: .atomic)
                install(candidate)
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
            if isEnabled { controller.add(candidate) }
        }
        // A content hash avoids overwriting the last working compilation on failure.
        // Remove obsolete compiled versions, keeping the active list and JSON fallback.
        if let previous, previous.identifier != candidate.identifier {
            store.removeContentRuleList(forIdentifier: previous.identifier) { _ in }
        }
    }

    private func compile(_ json: String) async throws -> WKContentRuleList {
        let digest = SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
        let identifier = "linklet-adguard-v1-" + digest
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

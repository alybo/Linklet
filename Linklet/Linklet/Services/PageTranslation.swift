import AppKit
import NaturalLanguage
import Translation
import WebKit

@MainActor
final class PageTranslationPreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var target: String? {
        get { defaults.string(forKey: "pageTranslationTarget") }
        set { defaults.set(newValue, forKey: "pageTranslationTarget") }
    }
}

@MainActor
final class PageTranslationController: ObservableObject {
    let preferences: PageTranslationPreferences
    @Published private(set) var isPresented = false
    @Published private(set) var isTranslated = false
    @Published private(set) var isEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var languages: [String] = []
    @Published private(set) var standardLanguages: Set<String>?
    @Published private(set) var source = "auto"
    @Published private(set) var target = ""
    @Published private(set) var detectedSource: String?
    @Published private(set) var error: String?
    @Published private(set) var translatedCount = 0
    @Published private(set) var request: UUID?
    private(set) var requestedSource = ""
    private(set) var requestedTarget = ""
    private(set) var appliedTarget: String?
    private(set) var appliedSource: String?
    private weak var webView: WKWebView?
    private var generation = UUID()
    private var preparing: Task<Void, Never>?
    private var checking: Task<Void, Never>?
    private var pendingSnapshot: PageTranslationDOM.Snapshot?
    private var needsDynamicPass = false
    private var automaticUpdatesEnabled = false
    private var enabledSite: String?
    private var isNavigating = false
    private let languageProvider: () async -> [String]
    private let standardLanguageProvider: () async -> [String]?
    private let translator: (([String]) async throws -> [String])?
    var usesAppleEngine: Bool { translator == nil }

    init(preferences: PageTranslationPreferences? = nil,
         languageProvider: (() async -> [String])? = nil,
         standardLanguageProvider: (() async -> [String]?)? = nil,
         translator: (([String]) async throws -> [String])? = nil) {
        self.preferences = preferences ?? PageTranslationPreferences()
        self.translator = translator
        self.standardLanguageProvider = standardLanguageProvider ?? {
            if #available(macOS 26.4, *) {
                return await LanguageAvailability(preferredStrategy: .lowLatency).supportedLanguages.map(\.minimalIdentifier)
            }
            return nil
        }
        self.languageProvider = languageProvider ?? {
            if #available(macOS 15, *) {
                return await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
            }
            return []
        }
    }
    var isSupported: Bool { if !usesAppleEngine { return true }; if #available(macOS 15, *) { return true }; return false }
    var showsOriginalAction: Bool {
        isTranslated && target == appliedTarget && (source == "auto" ? detectedSource : source) == appliedSource
    }
    var requiresAppleIntelligence: Bool {
        guard usesAppleEngine, let standardLanguages else { return false }
        let selected = [source == "auto" ? detectedSource : source, target].compactMap { $0 }
        return selected.contains { code in
            guard languages.contains(code) else { return false }
            return !standardLanguages.contains(code)
        }
    }
    func attach(_ view: WKWebView) {
        if webView === view { return }
        detach()
        webView = view
        PageTranslationDOM.shared.attach(view, owner: self)
    }
    func detach() {
        cancel()
        if let webView { PageTranslationDOM.shared.detach(webView) }
        webView = nil
        isPresented = false; isTranslated = false; detectedSource = nil
        appliedSource = nil; appliedTarget = nil; source = "auto"; error = nil
        isEnabled = false; enabledSite = nil; isNavigating = false
    }
    func navigationStarted() {
        cancel()
        // A provisional navigation may become a download or be cancelled.
        // Keep the displayed document translated until another one commits.
        isPresented = false; error = nil
        isNavigating = true
        if !isEnabled { source = "auto" }
    }
    func navigationCommitted(to url: URL?) {
        isTranslated = false; detectedSource = nil
        appliedTarget = nil; appliedSource = nil; translatedCount = 0
        guard isEnabled else { return }
        if url.flatMap(WindowGeometryService.siteKey(for:)) != enabledSite {
            isEnabled = false; enabledSite = nil; source = "auto"
        }
    }
    func navigationFinished() {
        isNavigating = false
        if isEnabled { requestTranslation() }
    }
    func navigationInterrupted() {
        isNavigating = false
        if isEnabled { requestTranslation(dynamic: isTranslated) }
    }
    func enable() {
        guard let webView else { return }
        isEnabled = true
        enabledSite = webView.url.flatMap(WindowGeometryService.siteKey(for:))
        isPresented = true
        if isBusy { return }
        requestTranslation()
    }
    func show() {
        guard webView != nil else { return }
        isPresented = true
        checking?.cancel()
        checking = Task { @MainActor [weak self] in
            guard let self else { return }
            await loadLanguages()
            await detectLanguage()
        }
    }
    func close() { isPresented = false }
    func toggle() { if isPresented { close() } else { show() } }
    func setSource(_ value: String) {
        guard value != source else { return }
        if isBusy { cancel() }; source = value; error = nil
        if isEnabled, !isNavigating { requestTranslation() }
    }
    func setTarget(_ value: String) {
        guard value != target else { return }
        if isBusy { cancel() }; target = value; preferences.target = value; error = nil
        if isEnabled, !isNavigating { requestTranslation() }
    }
    func languageName(_ code: String) -> String {
        let name = Locale(identifier: AppLanguage.shared.code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
    func loadLanguages() async {
        if languages.isEmpty { languages = Array(Set(await languageProvider())).sorted { languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending } }
        if usesAppleEngine, standardLanguages == nil, let standard = await standardLanguageProvider() {
            standardLanguages = Set(standard)
        }
        guard !Task.isCancelled else { return }
        if !isTranslated, !isBusy, let saved = preferences.target.flatMap(match) { target = saved }
        if target.isEmpty || !languages.contains(target) {
            let preferred = [preferences.target].compactMap { $0 } + Locale.preferredLanguages + ["en"]
            target = preferred.compactMap { match($0) }.first ?? languages.first ?? ""
        }
    }
    private func match(_ code: String) -> String? {
        if languages.contains(code) { return code }
        let base = Locale.Language(identifier: code).languageCode?.identifier
        return languages.first { Locale.Language(identifier: $0).languageCode?.identifier == base }
    }
    private func identify(_ snapshot: PageTranslationDOM.Snapshot) async -> String? {
        let text = snapshot.sample
        let detected = await Task.detached(priority: .utility) {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            return recognizer.dominantLanguage?.rawValue
        }.value
        if let detected { return match(detected) ?? detected }
        return match(snapshot.languageHint)
    }
    private func detectLanguage() async {
        guard !isTranslated, let view = webView else { return }
        let token = generation
        let snapshot = await PageTranslationDOM.shared.snapshot(view)
        let code = await identify(snapshot)
        guard generation == token, webView === view, !Task.isCancelled else { return }
        detectedSource = code
    }
    func pageChanged() {
        guard isEnabled, !isNavigating, automaticUpdatesEnabled,
              !isTranslated || showsOriginalAction else { return }
        if isBusy { needsDynamicPass = true; return }
        requestTranslation(dynamic: isTranslated)
    }
    private func cancel() {
        generation = UUID(); preparing?.cancel(); preparing = nil
        checking?.cancel(); checking = nil
        request = nil; isBusy = false; pendingSnapshot = nil; needsDynamicPass = false; automaticUpdatesEnabled = false
    }
    func restoreOriginal() {
        isEnabled = false; enabledSite = nil
        cancel()
        guard let view = webView else { return }
        let token = generation
        preparing = Task { @MainActor [weak self, weak view] in
            guard let self, let view else { return }
            await PageTranslationDOM.shared.restoreAndWait(view)
            guard generation == token, webView === view else { return }
            isTranslated = false; appliedTarget = nil; appliedSource = nil
            translatedCount = 0; error = nil
        }
    }
    func requestTranslation(dynamic: Bool = false) {
        guard let view = webView, !isBusy, !isNavigating else { return }
        if !dynamic {
            isEnabled = true
            enabledSite = view.url.flatMap(WindowGeometryService.siteKey(for:))
        }
        cancel(); error = nil; isBusy = true
        let token = generation
        preparing = Task { @MainActor [weak self, weak view] in
            guard let self, let view else { return }
            await loadLanguages()
            guard generation == token, webView === view else { return }
            if !dynamic {
                await PageTranslationDOM.shared.restoreAndWait(view)
                guard generation == token, webView === view else { return }
                isTranslated = false; appliedSource = nil; appliedTarget = nil; translatedCount = 0
                await PageTranslationDOM.shared.watch(view)
                guard generation == token, webView === view else { return }
            }
            let snapshot = await PageTranslationDOM.shared.snapshot(view)
            let identified = dynamic ? appliedSource : await identify(snapshot)
            guard generation == token, webView === view else { return }
            detectedSource = identified
            guard !snapshot.entries.isEmpty else {
                isBusy = false
                automaticUpdatesEnabled = true
                if !dynamic { isTranslated = false; error = L("No translatable text was found on this page.") }
                return
            }
            let selected = source == "auto" ? identified : source
            guard let selected, !target.isEmpty else { fail(L("Choose a supported source and target language.")); return }
            guard languages.contains(selected) else { fail(L("This page language is not supported by macOS on this Mac.")); return }
            guard Locale.Language(identifier: selected).languageCode != Locale.Language(identifier: target).languageCode else {
                isBusy = false
                automaticUpdatesEnabled = true
                return
            }
            requestedSource = selected; requestedTarget = target
            pendingSnapshot = snapshot
            if let translator { await performTranslation(using: translator) }
            else { request = UUID() }
        }
    }
    func translationFailed(_ failure: Error, request id: UUID) {
        guard request == id else { return }
        isBusy = false
        automaticUpdatesEnabled = false
        if !(failure is CancellationError) { error = failure.localizedDescription }
    }
    private func fail(_ message: String) { error = message; isBusy = false; request = nil }

    /// The adapter supplies Apple Translation in production; deterministic tests
    /// exercise the same extraction, batching, stale-result and restore path.
    func performTranslation(using translate: @escaping ([String]) async throws -> [String]) async {
        guard let view = webView, var snapshot = pendingSnapshot else { return }
        let token = generation
        pendingSnapshot = nil
        do {
            while !snapshot.entries.isEmpty {
                try Task.checkCancellation()
                let entries = snapshot.entries
                let results = try await translate(entries.map(\.text))
                guard generation == token, webView === view else { return }
                guard results.count == entries.count else { throw TranslationFailure.invalidResponse }
                let count = await PageTranslationDOM.shared.apply(entries, translations: results, in: view)
                guard generation == token, webView === view else { return }
                translatedCount += count
                if count > 0 { automaticUpdatesEnabled = true; isTranslated = true; appliedSource = requestedSource; appliedTarget = requestedTarget }
                snapshot = await PageTranslationDOM.shared.snapshot(view)
                guard generation == token, webView === view else { return }
                // A document that is continuously rebuilding should yield to its
                // mutation observer rather than spin or monopolise the translator.
                if count == 0 { break }
            }
            guard generation == token else { return }
            isBusy = false
            if needsDynamicPass { needsDynamicPass = false; pageChanged() }
        } catch {
            guard generation == token else { return }
            isBusy = false
            automaticUpdatesEnabled = false
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    private enum TranslationFailure: LocalizedError {
        case invalidResponse
        var errorDescription: String? { L("The translator returned an incomplete result. Try again.") }
    }
}

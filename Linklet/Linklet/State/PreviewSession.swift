import AppKit
import Foundation
import WebKit

struct PageLoadFailure: Equatable {
    enum Kind { case offline, timeout, unavailable, certificate, crashed, other }
    let kind: Kind
    let url: URL?
    let detail: String
    let resubmitsForm: Bool
    let allowsRetry: Bool
    var title: String { kind == .crashed ? L("The page stopped responding") : L("Couldn't open the page") }
    var explanation: String {
        switch kind {
        case .offline: return L("Check your internet connection and try again.")
        case .timeout: return L("The website took too long to respond. Try again.")
        case .unavailable: return L("The website could not be reached. Check the address or try again later.")
        case .certificate: return L("A secure connection to this website could not be established.")
        case .crashed: return L("Restore this page to continue. Other windows are unaffected.")
        case .other: return detail
        }
    }
}

/// Related private pages share cookies until the last page closes. Closing the
/// opener must not erase the store still in use by another independent window.
@MainActor
private final class TemporaryWebsiteData {
    let store = WKWebsiteDataStore.nonPersistent()
    private var sessions = Set<UUID>()

    func start(_ id: UUID) { sessions.insert(id) }
    func finish(_ id: UUID, clearWhenUnused: Bool) {
        sessions.remove(id)
        if clearWhenUnused && sessions.isEmpty {
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
    }
}

@MainActor
final class PreviewSession: ObservableObject {
    let windowID = UUID()
    let pageFind = PageFindController()
    let windowRegistry: BrowserWindowRegistry
    @Published private(set) var navigationID = UUID()
    // Browser handoff keeps the incoming link even after redirects and navigation.
    @Published private(set) var originalURL: URL?
    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle = ""
    @Published private(set) var isLoading = false
    @Published private(set) var estimatedProgress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isPreparingNewPage = false
    @Published var addressText = ""
    @Published var errorMessage: String?
    @Published private(set) var pageFailure: PageLoadFailure?
    weak var history: LinkLibrary?

    @Published private(set) var isWelcome = false
    var onOpenSettings: (() -> Void)?
    var onContinueInBrowser: (() -> Void)?
    var onPageFinished: ((URL, String) -> Void)?
    var onSiteLoaded: ((URL) -> Void)?
    var onWindowDocumentFinished: ((URL) -> Void)?
    var onWindowURLResolved: ((URL) -> Void)?
    var onWindowURLCommitted: ((URL) -> Void)?
    var closedWindowPosition: PagePosition? { restoration?.position ?? lastPosition }
    var makePopup: ((WKWebViewConfiguration, PreviewSession, WKWindowFeatures) -> WebPopupWindowController)?
    private var welcomeIsDefault = false

    weak var webView: WKWebView?
    private(set) var pageZoom = 1.0
    private static let zoomLevels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    let siteData: SiteDataService
    // Separate incoming windows are isolated; pages opened by a website share
    // their browsing context's store, including after the opener closes.
    private var temporaryStore = TemporaryWebsiteData()
    var websiteDataStore: WKWebsiteDataStore {
        siteData.isEnabled ? siteData.dataStore : temporaryStore.store
    }
    @Published private(set) var isActive = false
    private var pendingURL: URL?
    private var requestedURL: URL?
    private var requestGeneration = UUID()
    private var shouldRecordInitialTitle = false
    private(set) var lastCommittedURL: URL?
    private var lastCommittedTitle = ""
    private var lastPosition: PagePosition?
    private var navigationIsPending = false
    private var attemptedRequest: URLRequest?
    private var committedWasPOST = false
    private var restoration: (url: URL, position: PagePosition)?
    private var restorationStarted = false
    private var restorationAcknowledged = false
    private var historyRevision: Int?

    let adBlockService: AdBlockService

    convenience init() {
        self.init(adBlockService: AdBlockService())
    }

    init(adBlockService: AdBlockService, siteData: SiteDataService? = nil,
         windowRegistry: BrowserWindowRegistry? = nil) {
        self.adBlockService = adBlockService
        self.siteData = siteData ?? SiteDataService()
        self.windowRegistry = windowRegistry ?? BrowserWindowRegistry()
    }

    func endSession(resetTemporaryData: Bool = true) {
        finishHistoryEntry()
        if let webView { PreviewPageStateBridge.shared.detach(webView) }
        if let webView { siteData.mediaPermissions.detach(webView) }
        pageFind.detach()
        requestGeneration = UUID()
        let wasActive = isActive
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
        pageZoom = 1
        pendingURL = nil
        requestedURL = nil
        isActive = false
        isWelcome = false
        originalURL = nil
        currentURL = nil
        pageTitle = ""
        addressText = ""
        isLoading = false
        canGoBack = false
        canGoForward = false
        isPreparingNewPage = false
        errorMessage = nil
        pageFailure = nil
        lastCommittedURL = nil
        lastCommittedTitle = ""
        lastPosition = nil
        historyRevision = nil
        navigationIsPending = false
        attemptedRequest = nil
        restoration = nil
        restorationStarted = false
        restorationAcknowledged = false
        navigationID = UUID()
        let oldStore = temporaryStore
        let clearsPrivateData = resetTemporaryData && !siteData.isEnabled
        if clearsPrivateData { temporaryStore = TemporaryWebsiteData() }
        if wasActive {
            oldStore.finish(windowID, clearWhenUnused: clearsPrivateData)
            siteData.previewSessionDidEnd()
        }
    }

    func retainWebsiteDataForDownload() -> () -> Void {
        let token = UUID()
        let store = temporaryStore
        let data = siteData
        store.start(token)
        data.previewSessionDidStart()
        return {
            store.finish(token, clearWhenUnused: true)
            data.previewSessionDidEnd()
        }
    }

    func navigationBecameDownload(in view: WKWebView) {
        guard webView === view else { return }
        pageFind.navigationFinished()
        requestedURL = nil
        shouldRecordInitialTitle = false
        isPreparingNewPage = false
        synchronize(from: view)
        isLoading = false
        navigationIsPending = false
        pageFailure = nil
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        adBlockService.attach(to: webView.configuration.userContentController)
        siteData.mediaPermissions.attach(webView, session: self)
        PreviewPageStateBridge.shared.attach(webView, session: self)
        webView.pageZoom = pageZoom
        pageFind.attach(webView)
        if isWelcome {
            webView.loadHTMLString(Self.welcomeHTML, baseURL: nil)
        } else if let pendingURL {
            self.pendingURL = nil
            navigate(to: pendingURL, in: webView)
        }
    }

    private func navigate(to url: URL, in webView: WKWebView) {
        #if LINKLET_TCP_UPLOAD_DIAGNOSTICS
        let generation = requestGeneration
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            await DiagnosticUploadTransport.shared.prepare(webView.configuration.websiteDataStore)
            guard self.webView === webView, !isWelcome, requestGeneration == generation, requestedURL == url else { return }
            loadPreparedPage(url, in: webView)
        }
        #else
        loadPreparedPage(url, in: webView)
        #endif
    }

    private func loadPreparedPage(_ url: URL, in webView: WKWebView) {
        if !adBlockService.hasActiveRules {
            webView.load(URLRequest(url: url))
            return
        }
        let generation = requestGeneration
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            await adBlockService.prepareIfEnabled()
            guard self.webView === webView, !isWelcome, requestGeneration == generation, requestedURL == url else { return }
            adBlockService.attach(to: webView.configuration.userContentController)
            webView.load(URLRequest(url: url))
        }
    }

    func adoptPopup(_ view: WKWebView, from parent: PreviewSession) {
        temporaryStore = parent.temporaryStore
        startSessionIfNeeded()
        originalURL = parent.originalURL
        webView = view
        adBlockService.attach(to: view.configuration.userContentController)
        siteData.mediaPermissions.attach(view, session: self)
        PreviewPageStateBridge.shared.attach(view, session: self)
        view.pageZoom = pageZoom
        pageFind.attach(view)
        synchronize(from: view)
    }

    func load(_ url: URL, preservingOriginalURL: Bool = false, restoring position: PagePosition? = nil) {
        guard URLPolicy.canPreview(url) else {
            errorMessage = L("Only HTTP and HTTPS links can be previewed.")
            return
        }
        requestGeneration = UUID()
        finishHistoryEntry()
        if let webView { siteData.mediaPermissions.detach(webView) }
        if let webView { PreviewPageStateBridge.shared.detach(webView) }
        lastCommittedURL = nil
        lastCommittedTitle = ""
        lastPosition = nil
        restoration = position.flatMap { $0.isValid ? (url, $0) : nil }
        restorationStarted = false
        restorationAcknowledged = false
        navigationIsPending = true
        attemptedRequest = URLRequest(url: url)
        committedWasPOST = false
        pageFailure = nil
        startSessionIfNeeded()
        isWelcome = false
        errorMessage = nil
        pageFind.detach()
        webView?.stopLoading()
        webView = nil
        requestedURL = url
        shouldRecordInitialTitle = true
        pendingURL = url
        isPreparingNewPage = true
        if !preservingOriginalURL { originalURL = url }
        currentURL = url
        addressText = url.absoluteString
        pageTitle = ""
        canGoBack = false
        canGoForward = false
        isLoading = true
        estimatedProgress = 0
        navigationID = UUID()
    }

    func showWelcome(isDefault: Bool) {
        finishHistoryEntry()
        if let webView { siteData.mediaPermissions.detach(webView) }
        if let webView { PreviewPageStateBridge.shared.detach(webView) }
        lastCommittedURL = nil
        restoration = nil
        pageFailure = nil
        pageFind.detach()
        requestGeneration = UUID()
        startSessionIfNeeded()
        webView?.stopLoading()
        webView = nil
        pendingURL = nil
        requestedURL = nil
        originalURL = nil
        currentURL = nil
        addressText = ""
        errorMessage = nil
        pageFailure = nil
        pageTitle = "Linklet"
        canGoBack = false
        canGoForward = false
        isLoading = true
        estimatedProgress = 0
        isPreparingNewPage = true
        welcomeIsDefault = isDefault
        isWelcome = true
        navigationID = UUID()
    }

    func updateWelcomeStatus(isDefault: Bool) {
        welcomeIsDefault = isDefault
        guard isWelcome else { return }
        webView?.evaluateJavaScript("window.updateStatus(\(isDefault ? "true" : "false"))", completionHandler: nil)
    }

    private func startSessionIfNeeded() {
        guard !isActive else { return }
        temporaryStore.start(windowID)
        siteData.previewSessionDidStart()
        isActive = true
    }

    func welcomeDidFinish() {
        updateWelcomeStatus(isDefault: welcomeIsDefault)
    }

    func canOpenWelcomeSettings(from view: WKWebView, isMainFrame: Bool) -> Bool {
        isWelcome && webView === view && isMainFrame && view.url?.absoluteString == "about:blank"
    }

    @discardableResult
    func submitAddress(_ input: String, engine: SearchEngine) -> Bool {
        guard isActive, !isWelcome, let webView,
              let url = SearchInput.destination(for: input, engine: engine) else { return false }
        requestGeneration = UUID()
        errorMessage = nil
        pageFailure = nil
        restoration = nil
        pendingURL = nil
        requestedURL = url
        currentURL = url
        addressText = url.absoluteString
        isPreparingNewPage = false
        isLoading = true
        estimatedProgress = 0
        shouldRecordInitialTitle = false
        // A URL-bar navigation belongs to this live page. Retain its WebKit
        // configuration, cookies, history, opener and original incoming URL.
        navigate(to: url, in: webView)
        return true
    }

    func goBack() {
        guard canGoBack else { return }
        webView?.goBack()
    }
    func goForward() {
        guard canGoForward else { return }
        webView?.goForward()
    }
    func reload() {
        guard isActive, !isWelcome else { return }
        if pageFailure != nil { retryPageLoad(); return }
        errorMessage = nil
        webView?.reload()
    }

    func toggleAdGuard() {
        guard isActive, !isWelcome, let view = webView, let url = view.url,
              let host = AdBlockService.siteHost(url.absoluteString) else { return }
        let generation = requestGeneration
        let enabled = !adBlockService.isEnabled(for: url)
        if enabled == adBlockService.isEnabled { adBlockService.removeSiteOverride(host) }
        else { adBlockService.setSiteEnabled(enabled, host: host) }
        Task { @MainActor [weak self, weak view] in
            guard let self, let view else { return }
            await adBlockService.waitForPolicyUpdate()
            guard webView === view, isActive, requestGeneration == generation, view.url == url else { return }
            if let error = adBlockService.errorMessage { errorMessage = error; return }
            reload()
        }
    }

    func changePageZoom(increase: Bool) {
        guard isActive, !isWelcome, let webView else { return }
        let current = webView.pageZoom
        pageZoom = increase
            ? Self.zoomLevels.first(where: { $0 > current + 0.001 }) ?? Self.zoomLevels.last!
            : Self.zoomLevels.last(where: { $0 < current - 0.001 }) ?? Self.zoomLevels.first!
        webView.pageZoom = pageZoom
    }

    func resetPageZoom() {
        guard isActive, !isWelcome, let webView else { return }
        pageZoom = 1
        webView.pageZoom = 1
        webView.magnification = 1
    }
    func stopLoading() {
        requestGeneration = UUID()
        webView?.stopLoading()
        pendingURL = nil
        requestedURL = nil
        isPreparingNewPage = false
        pageFind.navigationFinished()
        navigationIsPending = false
        synchronizeFromLoadedPage()
    }

    func pageDidFinish(in view: WKWebView) {
        guard webView === view else { return }
        navigationIsPending = false
        requestedURL = nil
        if !isWelcome, lastCommittedURL != view.url { navigationDidCommit(in: view) }
        synchronize(from: view)
        if let restoration, restoration.url == view.url, !restorationStarted {
            restorationStarted = true
            PreviewPageStateBridge.shared.restore(restoration.position, in: view)
        } else { PreviewPageStateBridge.shared.capture(in: view) }
        pageFind.navigationFinished()
        welcomeDidFinish()
        if !isWelcome, let url = view.url, URLPolicy.canPreview(url) {
            onWindowDocumentFinished?(url)
            onSiteLoaded?(url)
        }
        guard !isWelcome, shouldRecordInitialTitle, let originalURL else { return }
        shouldRecordInitialTitle = false
        onPageFinished?(originalURL, view.title ?? "")
    }

    func navigationDidCommit(in webView: WKWebView) {
        guard self.webView === webView else { return }
        requestedURL = nil
        pageFailure = nil
        lastCommittedURL = webView.url
        if !isWelcome, let url = webView.url { onWindowURLCommitted?(url) }
        lastCommittedTitle = ""
        lastPosition = .top
        committedWasPOST = attemptedRequest?.httpMethod?.uppercased() == "POST"
        if restoration?.url != webView.url { restoration = nil }
        if !isWelcome, let url = webView.url {
            history?.recordVisit(url, title: "")
            historyRevision = history?.historyRevision
        }
        isPreparingNewPage = false
        if !isWelcome, let url = webView.url { siteData.recordVisit(url) }
        synchronize(from: webView)
    }

    func navigationDidFail(in webView: WKWebView) {
        guard self.webView === webView else { return }
        pageFind.navigationFinished()
        requestedURL = nil
        isPreparingNewPage = false
        synchronize(from: webView)
    }

    func prepareNavigation(_ request: URLRequest, in view: WKWebView) {
        guard webView === view else { return }
        attemptedRequest = request
    }

    func navigationDidStart(in view: WKWebView) {
        guard webView === view else { return }
        siteData.mediaPermissions.navigationChanged(in: view)
        navigationIsPending = true
        pageFailure = nil
        pageFind.navigationStarted()
        if let url = attemptedRequest?.url, URLPolicy.canPreview(url) {
            requestedURL = url
            currentURL = url
            addressText = url.absoluteString
        }
        synchronize(from: view)
    }

    func navigationDidFail(in view: WKWebView, error: NSError) {
        guard webView === view, isActive, !isWelcome else { return }
        let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
            ?? (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
            ?? requestedURL ?? attemptedRequest?.url ?? view.url ?? currentURL
        let kind: PageLoadFailure.Kind
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: kind = .offline
            case NSURLErrorTimedOut: kind = .timeout
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed: kind = .unavailable
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired: kind = .certificate
            default: kind = .other
            }
        } else if error.domain == WKErrorDomain && error.code == WKError.Code.webContentProcessTerminated.rawValue {
            kind = .crashed
        } else { kind = .other }
        showPageFailure(kind: kind, url: url, detail: error.localizedDescription,
                        wasPOST: attemptedRequest?.httpMethod?.uppercased() == "POST")
    }

    func webContentProcessDidTerminate(in view: WKWebView) {
        guard webView === view, isActive, !isWelcome else { return }
        siteData.mediaPermissions.navigationChanged(in: view)
        showPageFailure(kind: .crashed, url: lastCommittedURL ?? requestedURL ?? currentURL,
                        detail: "", wasPOST: lastCommittedURL == nil ? false : committedWasPOST)
    }

    private func showPageFailure(kind: PageLoadFailure.Kind, url: URL?, detail: String, wasPOST: Bool) {
        requestedURL = nil
        navigationIsPending = false
        isPreparingNewPage = false
        isLoading = false
        pageFind.navigationStarted()
        if let url, URLPolicy.canPreview(url) {
            currentURL = url
            addressText = url.absoluteString
            if url != lastCommittedURL { pageTitle = "" }
        }
        pageFailure = PageLoadFailure(kind: kind, url: url, detail: detail, resubmitsForm: wasPOST,
            allowsRetry: url.map(URLPolicy.canPreview) == true && (!wasPOST || url == lastCommittedURL))
        if let window = webView?.window,
           (window.firstResponder as? NSTextView)?.isFieldEditor != true {
            window.makeFirstResponder(window.contentView)
        }
    }

    var canReturnToLoadedPage: Bool {
        pageFailure != nil && pageFailure?.kind != .crashed && lastCommittedURL != nil
            && lastCommittedURL != pageFailure?.url
    }

    func returnToLoadedPage() {
        guard canReturnToLoadedPage else { return }
        pageFailure = nil
        synchronizeFromLoadedPage()
        pageFind.navigationFinished()
    }

    private func synchronizeFromLoadedPage() {
        guard let webView else { return }
        currentURL = webView.url
        addressText = webView.url?.absoluteString ?? ""
        synchronize(from: webView)
    }

    func retryPageLoad() {
        guard let failure = pageFailure, failure.allowsRetry, let url = failure.url, let webView else { return }
        let reloadsCurrent = url == webView.url && url == lastCommittedURL
        pageFailure = nil
        errorMessage = nil
        isLoading = true
        if reloadsCurrent { webView.reload() }
        else {
            requestedURL = url
            attemptedRequest = URLRequest(url: url)
            navigate(to: url, in: webView)
        }
    }

    func receivePosition(_ position: PagePosition, for url: URL, in view: WKWebView, restoring: Bool) {
        guard webView === view, position.isValid, url == lastCommittedURL, pageFailure == nil else { return }
        if restoration != nil {
            guard restorationStarted else { return }
            if restoring { restorationAcknowledged = true; return }
            guard restorationAcknowledged else { return }
            restoration = nil
        }
        lastPosition = position
        history?.updatePosition(position, for: url)
    }

    private func finishHistoryEntry() {
        guard !isWelcome, let url = lastCommittedURL else { return }
        history?.recordClosing(url, title: lastCommittedTitle, position: restoration?.position ?? lastPosition,
                               revision: historyRevision)
    }

    func synchronize(from webView: WKWebView) {
        guard self.webView === webView else { return }
        if pageFailure != nil { return }
        if isWelcome {
            isLoading = webView.isLoading
            estimatedProgress = webView.estimatedProgress
            return
        }
        let nextURL = webView.url
        let nextTitle = webView.title ?? ""
        let nextIsLoading = webView.isLoading
        let nextProgress = webView.estimatedProgress
        let nextCanGoBack = webView.canGoBack
        let nextCanGoForward = webView.canGoForward

        let canAdoptWebViewURL = requestedURL == nil || nextURL == requestedURL
        if canAdoptWebViewURL, currentURL != nextURL { currentURL = nextURL }
        if pageTitle != nextTitle { pageTitle = nextTitle }
        if isLoading != nextIsLoading { isLoading = nextIsLoading }
        if abs(estimatedProgress - nextProgress) > 0.001 { estimatedProgress = nextProgress }
        if canGoBack != nextCanGoBack { canGoBack = nextCanGoBack }
        if canGoForward != nextCanGoForward { canGoForward = nextCanGoForward }

        if canAdoptWebViewURL, let nextURL {
            let nextAddress = nextURL.absoluteString
            if addressText != nextAddress { addressText = nextAddress }
        }
        if !isWelcome, !navigationIsPending, !nextIsLoading, requestedURL == nil,
           let nextURL, URLPolicy.canPreview(nextURL), lastCommittedURL != nil, nextURL != lastCommittedURL {
            lastCommittedURL = nextURL
            lastPosition = nil
            history?.recordVisit(nextURL, title: nextTitle)
            historyRevision = history?.historyRevision
            PreviewPageStateBridge.shared.capture(in: webView)
        }
        if let url = lastCommittedURL, url == nextURL, !isWelcome {
            lastCommittedTitle = nextTitle
            history?.updateTitle(nextTitle, for: url)
        }
    }
}

private extension PreviewSession {
    static var welcomeHTML: String {
        let html = #"""
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:">
<title>Linklet</title><style>
:root{color-scheme:light dark;--bg:#fafafa;--fg:#20242a;--muted:#717780;--line:#e3e5e8;--card:#f1f3f5;--accent:#2868ce}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px -apple-system,BlinkMacSystemFont,sans-serif}
main{max-width:760px;margin:auto;padding:42px 42px 30px;text-align:center}.brand{display:flex;gap:10px;align-items:center;justify-content:center;font-size:18px;font-weight:600;margin-bottom:24px}.brand svg{width:32px;height:32px}
h1{font-size:clamp(25px,4.1vw,34px);line-height:1.18;letter-spacing:-1px;margin:0 0 15px;font-weight:650}p{color:var(--muted);line-height:1.55;margin:0}.subtitle{max-width:490px;margin:auto;font-size:16px}
.features{display:flex;margin:30px 0;gap:20px;text-align:left}.feature{flex:1;font-size:12px;line-height:1.5}.feature strong{display:block;font-size:14px;margin-bottom:6px;font-weight:600}.feature p{font-size:12px}.symbol{font-size:19px;color:var(--accent);margin-bottom:9px;display:block}
.setup{border:1px solid var(--line);border-radius:15px;padding:20px 22px;text-align:left;display:flex;gap:18px;align-items:center;background:var(--card)}.setup-copy{flex:1}.status{font-size:14px;font-weight:600;display:flex;align-items:center;gap:8px;margin-bottom:5px}.dot{width:7px;height:7px;flex-shrink:0;background:#969ca4;border-radius:50%}.ready .dot{background:#329764}.setup p{font-size:12px}a{display:inline-block;border-radius:8px;background:var(--accent);color:white;padding:11px 15px;text-decoration:none;font-size:13px;font-weight:500;white-space:nowrap}a:hover{filter:brightness(1.08)}a:focus-visible{outline:3px solid #77aaff;outline-offset:3px}.footer{font-size:11px;margin-top:17px}
@media(prefers-color-scheme:dark){:root{--bg:#202124;--fg:#f0f1f3;--muted:#a4a8b0;--line:#3b3d42;--card:#292b30;--accent:#347be4}}
@media(max-width:650px){main{padding:28px 28px 22px}.features{gap:14px;margin:24px 0}.setup{padding:16px;gap:12px}}
</style></head><body><main>
<div class="brand"><svg viewBox="0 0 32 32" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" d="M16 0a16 16 0 1 0 0 32A16 16 0 0 0 16 0ZM5 16s4-7 11-7 11 7 11 7-4 7-11 7S5 16 5 16Zm11-4a4 4 0 1 0 0 8 4 4 0 0 0 0-8Zm0 2a2 2 0 1 1 0 4 2 2 0 0 1 0-4Z"/></svg>Linklet</div>
<h1>Сначала посмотрите,<br>затем откройте в своём браузере.</h1>
<p class="subtitle">Быстрый просмотр ссылок и удобный выбор браузера.</p>
<div class="features"><div class="feature"><span class="symbol" aria-hidden="true">↗</span><strong>Быстрый просмотр</strong><p>Открывайте ссылки поверх текущей работы.</p></div><div class="feature"><span class="symbol" aria-hidden="true">◎</span><strong>Отдельная сессия</strong><p>Без аккаунтов и cookies из ваших браузеров.</p></div><div class="feature"><span class="symbol" aria-hidden="true">⇢</span><strong>Ваш браузер</strong><p>Выбирайте, где продолжить просмотр.</p></div></div>
<section class="setup" id="setup"><div class="setup-copy"><div class="status" role="status" aria-live="polite"><span class="dot"></span><span id="status">Проверяем настройки…</span></div><p id="detail">Проверяем, где открываются ссылки.</p></div><a href="linklet-welcome://settings">Открыть настройки</a></section>
<p class="footer">К этой странице можно вернуться через значок Linklet в строке меню.</p>
</main><script>window.updateStatus=function(ready){document.getElementById('setup').classList.toggle('ready',ready);document.getElementById('status').textContent=ready?'Всё готово к просмотру':'Настройте открытие ссылок';document.getElementById('detail').textContent=ready?'Linklet открывает ссылки по умолчанию.':'Выберите Linklet браузером по умолчанию в настройках.';};</script></body></html>
"""#
        guard AppLanguage.shared.code == "en" else { return html }
        let translations: [String: String] = [
            "Сначала посмотрите,": "Preview first,",
            "затем откройте в своём браузере.": "then open in your browser.",
            "Быстрый просмотр ссылок и удобный выбор браузера.": "Quick link previews. Easy browser choice.",
            "Быстрый просмотр": "Quick previews",
            "Открывайте ссылки поверх текущей работы.": "Open links without leaving your current task.",
            "Отдельная сессия": "Separate session",
            "Без аккаунтов и cookies из ваших браузеров.": "Separate from your browsers’ accounts and cookies.",
            "Ваш браузер": "Your browser",
            "Выбирайте, где продолжить просмотр.": "Choose where to keep browsing.",
            "Проверяем настройки…": "Checking settings…",
            "Проверяем, где открываются ссылки.": "Checking how links open.",
            "Открыть настройки": "Open Settings",
            "К этой странице можно вернуться через значок Linklet в строке меню.": "Return to this page from the Linklet icon in the menu bar.",
            "Всё готово к просмотру": "Ready to preview",
            "Настройте открытие ссылок": "Set up link previews",
            "Linklet открывает ссылки по умолчанию.": "Linklet opens links by default.",
            "Выберите Linklet браузером по умолчанию в настройках.": "Choose Linklet as your default browser in Settings."
        ]
        return translations.keys.sorted { $0.count > $1.count }.reduce(html.replacingOccurrences(of: "lang=\"ru\"", with: "lang=\"en\"")) { result, key in
            result.replacingOccurrences(of: key, with: translations[key]!)
        }
    }
}

import AppKit
import Foundation
import WebKit

@MainActor
final class PreviewSession: ObservableObject {
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

    @Published private(set) var isWelcome = false
    var onOpenSettings: (() -> Void)?
    private var welcomeIsDefault = false

    weak var webView: WKWebView?
    let siteData: SiteDataService
    // A private store belongs to one preview window. Closing one private preview
    // must never clear website data used by another open preview.
    private var temporaryStore = WKWebsiteDataStore.nonPersistent()
    var websiteDataStore: WKWebsiteDataStore {
        siteData.isEnabled ? siteData.dataStore : temporaryStore
    }
    @Published private(set) var isActive = false
    private var pendingURL: URL?
    private var requestedURL: URL?

    let adBlockService: AdBlockService

    convenience init() {
        self.init(adBlockService: AdBlockService())
    }

    init(adBlockService: AdBlockService, siteData: SiteDataService? = nil) {
        self.adBlockService = adBlockService
        self.siteData = siteData ?? SiteDataService()
    }

    func endSession(resetTemporaryData: Bool = true) {
        let wasActive = isActive
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
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
        navigationID = UUID()
        if resetTemporaryData && !siteData.isEnabled {
            let oldStore = temporaryStore
            temporaryStore = WKWebsiteDataStore.nonPersistent()
            oldStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
        if wasActive { siteData.previewSessionDidEnd() }
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        if isWelcome {
            webView.loadHTMLString(Self.welcomeHTML, baseURL: nil)
        } else if let pendingURL {
            self.pendingURL = nil
            if !adBlockService.isEnabled {
                webView.load(URLRequest(url: pendingURL))
                return
            }
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                await adBlockService.prepareIfEnabled()
                guard self.webView === webView, !isWelcome else { return }
                adBlockService.attach(to: webView.configuration.userContentController)
                webView.load(URLRequest(url: pendingURL))
            }
        }
    }

    func load(_ url: URL, preservingOriginalURL: Bool = false) {
        guard URLPolicy.canPreview(url) else {
            errorMessage = L("Only HTTP and HTTPS links can be previewed.")
            return
        }
        if !isActive { siteData.previewSessionDidStart() }
        isActive = true
        isWelcome = false
        errorMessage = nil
        webView?.stopLoading()
        webView = nil
        requestedURL = url
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
        if !isActive { siteData.previewSessionDidStart() }
        isActive = true
        webView?.stopLoading()
        webView = nil
        pendingURL = nil
        requestedURL = nil
        originalURL = nil
        currentURL = nil
        addressText = ""
        errorMessage = nil
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

    func welcomeDidFinish() {
        updateWelcomeStatus(isDefault: welcomeIsDefault)
    }

    func canOpenWelcomeSettings(from view: WKWebView, isMainFrame: Bool) -> Bool {
        isWelcome && webView === view && isMainFrame && view.url?.absoluteString == "about:blank"
    }

    func submitAddress() {
        guard let url = URLPolicy.normalizedURL(from: addressText) else {
            errorMessage = L("Enter a valid web address.")
            return
        }
        load(url)
    }

    func goBack() {
        guard canGoBack else { return }
        webView?.goBack()
    }
    func goForward() {
        guard canGoForward else { return }
        webView?.goForward()
    }
    func reload() { webView?.reload() }
    func stopLoading() {
        webView?.stopLoading()
        pendingURL = nil
        requestedURL = nil
        isPreparingNewPage = false
    }

    func navigationDidCommit(in webView: WKWebView) {
        guard self.webView === webView else { return }
        requestedURL = nil
        isPreparingNewPage = false
        if !isWelcome, let url = webView.url { siteData.recordVisit(url) }
        synchronize(from: webView)
    }

    func navigationDidFail(in webView: WKWebView) {
        guard self.webView === webView else { return }
        requestedURL = nil
        isPreparingNewPage = false
        synchronize(from: webView)
    }

    func synchronize(from webView: WKWebView) {
        guard self.webView === webView else { return }
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

        let canAdoptWebViewURL = !isPreparingNewPage || nextURL == requestedURL
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

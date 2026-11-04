import AppKit
import PublicSuffixList

/// Stores only Linklet window geometry, shared by a site's subdomains.
/// It never stores website content, cookies, or browsing history.
final class WindowGeometryService {
    private struct StoredFrame: Codable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        init(_ frame: NSRect) {
            x = frame.origin.x
            y = frame.origin.y
            width = frame.width
            height = frame.height
        }

        var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }

    private static let preferenceKey = "websiteWindowFrames"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func frame(for url: URL) -> NSRect? {
        guard let key = Self.siteKey(for: url), let host = Self.host(for: url) else { return nil }
        let stored = frames
        // Prefer the previous root/www frame over a conflicting subdomain frame.
        if let frame = stored[key] ?? stored["www." + key] ?? stored[host] { return frame.rect }
        // Retain a legacy subdomain-only preference until the next explicit save.
        return stored.keys.sorted().first { Self.siteKey(host: $0) == key }.flatMap { stored[$0]?.rect }
    }

    func save(_ frame: NSRect, for url: URL) {
        guard let key = Self.siteKey(for: url), frame.width > 0, frame.height > 0 else { return }
        var next = frames
        for host in next.keys where Self.siteKey(host: host) == key { next.removeValue(forKey: host) }
        next[key] = StoredFrame(frame)
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }

    /// Decode only recognized search-result wrappers, solely for local sizing.
    /// Neither navigation nor external-browser handoff rewrites the incoming URL.
    static func searchRedirectDestination(in url: URL) -> URL? {
        guard webURL(url.absoluteString) != nil, url.absoluteString.utf8.count <= 32_768 else { return nil }
        var current = url
        var seen: Set<URL> = [url]
        for _ in 0..<4 {
            switch redirectStep(current) {
            case .plain: return current == url ? nil : current
            case .opaque: return nil
            case let .target(next):
                guard seen.insert(next).inserted else { return nil }
                current = next
            }
        }
        if case .plain = redirectStep(current) { return current }
        return nil
    }

    static func isSearchRedirect(_ url: URL) -> Bool {
        switch redirectStep(url) {
        case .plain: return false
        case .opaque, .target: return true
        }
    }

    /// Modern engines also link straight to results. In that case the known
    /// opener identifies a search result without treating arbitrary URL fields as redirects.
    static func searchResultDestination(in url: URL, from opener: URL?) -> URL? {
        if let target = searchRedirectDestination(in: url) { return target }
        guard let opener, provider(for: opener) != nil, provider(for: url) == nil else { return nil }
        return webURL(url.absoluteString)
    }

    private enum Provider { case google, bing, duckDuckGo, yandex, yahoo, brave, ecosia, startpage }
    private enum RedirectStep { case plain, opaque, target(URL) }

    private static func provider(for url: URL) -> Provider? {
        guard URLPolicy.canPreview(url), let host = url.host?.lowercased() else { return nil }
        func matches(_ domains: [String]) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }
        if matches(["google.com", "google.ru", "google.co.il", "google.co.uk", "google.de", "google.fr", "google.ca",
                    "google.es", "google.it", "google.com.au", "google.co.jp", "google.co.in"]) { return .google }
        if matches(["bing.com"]) { return .bing }
        if matches(["duckduckgo.com"]) { return .duckDuckGo }
        if matches(["yandex.ru", "yandex.com", "yandex.by", "yandex.kz", "yandex.uz", "yandex.com.tr", "ya.ru"]) { return .yandex }
        if matches(["search.yahoo.com", "search.yahoo.co.jp"]) { return .yahoo }
        if host == "search.brave.com" { return .brave }
        if matches(["ecosia.org"]) { return .ecosia }
        if matches(["startpage.com"]) { return .startpage }
        return nil
    }

    private static func redirectStep(_ url: URL) -> RedirectStep {
        guard let provider = provider(for: url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .plain }
        let items = components.queryItems ?? []
        func query(_ names: Set<String>) -> String? {
            let candidates = items.filter { names.contains($0.name) }
            return candidates.count == 1 ? candidates[0].value : nil
        }
        func target(_ value: String?) -> RedirectStep {
            value.flatMap(webURL).map(RedirectStep.target) ?? .opaque
        }
        switch provider {
        case .google:
            guard url.path == "/url" else { return .plain }
            return target(query(["url", "q"]))
        case .bing:
            guard url.path == "/ck/a" || url.path == "/ck/a/" else { return .plain }
            guard let value = query(["u"]), value.hasPrefix("a1") else { return .opaque }
            var encoded = String(value.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            guard !encoded.isEmpty else { return .opaque }
            encoded += String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
            guard let bytes = Data(base64Encoded: encoded), let decoded = String(data: bytes, encoding: .utf8) else { return .opaque }
            return target(decoded)
        case .duckDuckGo:
            guard url.path == "/l" || url.path == "/l/" else { return .plain }
            return target(query(["uddg"]))
        case .yandex:
            let clck = url.host?.lowercased().hasPrefix("clck.") == true
            guard url.path == "/clck/jsredir" || url.path == "/clck/jsredir/" || clck && url.path.hasPrefix("/redir/")
            else { return .plain }
            if items.contains(where: { ["url", "adurl"].contains($0.name) }) { return target(query(["url", "adurl"])) }
            let parts = url.absoluteString.components(separatedBy: "/*")
            guard parts.count == 2 else { return .opaque }
            let value = parts[1]
            return target(value.lowercased().hasPrefix("https://") || value.lowercased().hasPrefix("http://") ? value : value.removingPercentEncoding)
        case .yahoo:
            // RU is a fully percent-encoded path component, not a query field.
            let destinations = components.percentEncodedPath.split(separator: "/").filter { $0.hasPrefix("RU=") }
            guard !destinations.isEmpty else {
                return url.host?.lowercased().hasPrefix("r.search.") == true ? .opaque : .plain
            }
            guard destinations.count == 1 else { return .opaque }
            return target(String(destinations[0].dropFirst(3)).removingPercentEncoding)
        case .brave, .ecosia, .startpage: return .plain
        }
    }

    private static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), URLPolicy.canPreview(url), url.host?.isEmpty == false else { return nil }
        return url
    }

    static func clamped(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        let width = min(max(frame.width, 1), visibleFrame.width)
        let height = min(max(frame.height, 1), visibleFrame.height)
        return NSRect(
            x: min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }

    private var frames: [String: StoredFrame] {
        guard let data = defaults.data(forKey: Self.preferenceKey),
              let decoded = try? JSONDecoder().decode([String: StoredFrame].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func host(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    static func siteKey(for url: URL) -> String? { host(for: url).map { siteKey(host: $0) } }

    private static func siteKey(host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        // IP literals and single-label intranet hosts are never collapsed.
        guard !host.contains(":"), labels.count > 1,
              !(labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }) else { return host }
        return PublicSuffixList.effectiveTLDPlusOne(host) ?? host
    }
}

/// Shares geometry rules between incoming links and site-created WebKit windows.
/// Only committed destinations may replace the host used for future saves.
@MainActor
final class WebsiteWindowGeometry {
    private weak var window: NSWindow?
    private let service: WindowGeometryService
    private var url: URL?
    private var isApplying = false

    init(window: NSWindow, service: WindowGeometryService) {
        self.window = window
        self.service = service
    }

    @discardableResult
    func begin(at url: URL?) -> Bool {
        self.url = url.flatMap { incoming in
            guard URLPolicy.canPreview(incoming) else { return nil }
            return WindowGeometryService.searchRedirectDestination(in: incoming) ?? incoming
        }
        return restore()
    }

    func committed(_ destination: URL) {
        guard URLPolicy.canPreview(destination) else { return }
        // Bing and some other engines commit a JavaScript redirect document.
        // Keep the destination geometry through that intermediate document too.
        let sizingURL = WindowGeometryService.searchRedirectDestination(in: destination) ?? destination
        let changedHost = WindowGeometryService.siteKey(for: sizingURL) != url.flatMap(WindowGeometryService.siteKey(for:))
        url = sizingURL
        if changedHost { _ = restore() }
    }

    func save() {
        guard !isApplying, let window, window.isVisible, let url else { return }
        service.save(window.frame, for: url)
    }

    private func restore() -> Bool {
        guard let url, let frame = service.frame(for: url), let window else { return false }
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(NSPoint(x: frame.midX, y: frame.midY)) }
            ?? window.screen ?? NSScreen.main
        guard let screen else { return false }
        isApplying = true
        window.setFrame(WindowGeometryService.clamped(frame, to: screen.visibleFrame), display: false)
        isApplying = false
        return true
    }
}

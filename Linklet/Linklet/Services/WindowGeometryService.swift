import AppKit

/// Stores only Linklet window geometry, keyed by the currently displayed website host.
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
        guard let host = Self.host(for: url), let stored = frames[host] else { return nil }
        return stored.rect
    }

    func save(_ frame: NSRect, for url: URL) {
        guard let host = Self.host(for: url), frame.width > 0, frame.height > 0 else { return }
        var next = frames
        next[host] = StoredFrame(frame)
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }

    /// Google Search includes the destination in /url?url=… . Use it only as a
    /// local geometry hint; the original request still goes through WebKit.
    static func googleRedirectDestination(in url: URL) -> URL? {
        guard URLPolicy.canPreview(url),
              ["google.com", "www.google.com"].contains(url.host?.lowercased() ?? ""),
              url.path == "/url",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let destinations = items.filter { $0.name == "url" }
        guard destinations.count == 1, let value = destinations.first?.value,
              let destination = URL(string: value), URLPolicy.canPreview(destination),
              destination.host?.isEmpty == false else { return nil }
        return destination
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
        return host
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
            return WindowGeometryService.googleRedirectDestination(in: incoming) ?? incoming
        }
        return restore()
    }

    func committed(_ destination: URL) {
        guard URLPolicy.canPreview(destination) else { return }
        let changedHost = destination.host?.lowercased() != url?.host?.lowercased()
        url = destination
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

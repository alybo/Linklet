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

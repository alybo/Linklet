import Foundation
import ImageIO
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum FavoriteSiteIconError: LocalizedError {
    case unavailable

    var errorDescription: String? { L("Couldn't load a favicon for this website.") }
}

/// Shared, cookie-free favicon requests for visible bookmark and history rows.
enum FavoriteSiteIconService {
    static let pipelineVersion = 2
    private static let httpCache = SiteIconHTTPValidationCache()
    struct PreparedIcon {
        let data: Data
        let pixelSize: Int
    }
    static func fetch(for siteURL: URL) async throws -> Data {
        guard URLPolicy.canPreview(siteURL), var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false) else {
            throw FavoriteSiteIconError.unavailable
        }
        components.user = nil
        components.password = nil
        components.path = "/"
        components.query = nil
        components.fragment = nil
        guard let homeURL = components.url else { throw FavoriteSiteIconError.unavailable }
        components.path = "/favicon.ico"
        guard let conventionalURL = components.url else { throw FavoriteSiteIconError.unavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var best: PreparedIcon?
        if let response = try? await download(conventionalURL, session: session, accept: "image/*") {
            best = try? prepare(response.data)
        }
        // Revalidate declared icons too: a site can change their address while /favicon.ico stays the same.
        if let response = try? await download(homeURL, session: session, accept: "text/html"),
           let html = String(data: response.data, encoding: .utf8) {
            for url in declaredIcons(in: html, baseURL: response.url).prefix(4) {
                if let response = try? await download(url, session: session, accept: "image/*"),
                   let candidate = try? prepare(response.data) {
                    if candidate.pixelSize >= (best?.pixelSize ?? 0) { best = candidate }
                    if candidate.pixelSize >= 128 { break }
                }
            }
        }
        guard let best else { throw FavoriteSiteIconError.unavailable }
        return best.data
    }

    private static func download(_ url: URL, session: URLSession, accept: String) async throws -> (data: Data, url: URL) {
        let cached = await httpCache.record(for: url)
        var request = URLRequest(url: url)
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = cached?.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw FavoriteSiteIconError.unavailable }
        if response.statusCode == 304, let cached { return (cached.data, cached.finalURL) }
        guard (200..<300).contains(response.statusCode), data.count <= 512_000 else {
            throw FavoriteSiteIconError.unavailable
        }
        let finalURL = response.url ?? url
        await httpCache.store(data, for: url, finalURL: finalURL,
                              etag: response.value(forHTTPHeaderField: "ETag"),
                              lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
        return (data, finalURL)
    }

    static func declaredIcons(in html: String, baseURL: URL) -> [URL] {
        guard let tags = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive),
              let attributes = try? NSRegularExpression(pattern: #"\b(rel|href|sizes)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: .caseInsensitive) else { return [] }
        let document = html as NSString
        let candidates: [(URL, Int)] = tags.matches(in: html, range: NSRange(location: 0, length: document.length)).compactMap { match in
            let tag = document.substring(with: match.range) as NSString
            var values: [String: String] = [:]
            for attribute in attributes.matches(in: tag as String, range: NSRange(location: 0, length: tag.length)) {
                let name = tag.substring(with: attribute.range(at: 1)).lowercased()
                for index in 2...4 where attribute.range(at: index).location != NSNotFound {
                    values[name] = tag.substring(with: attribute.range(at: index))
                }
            }
            let relationships = values["rel"]?.lowercased().split(whereSeparator: { $0.isWhitespace }) ?? []
            guard relationships.contains("icon") || relationships.contains("apple-touch-icon"),
                  let href = values["href"]?.replacingOccurrences(of: "&amp;", with: "&"),
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  URLPolicy.canPreview(url), url.user == nil, url.password == nil else { return nil }
            let declaredSize = values["sizes"]?.split(whereSeparator: { $0.isWhitespace }).compactMap { size -> Int? in
                let sides = size.lowercased().split(separator: "x").compactMap { Int($0) }
                return sides.count == 2 ? sides.min() : nil
            }.max() ?? 0
            let score = declaredSize > 0 ? declaredSize : (relationships.contains("apple-touch-icon") ? 180 : 0)
            return (url, score)
        }
        return candidates.enumerated().sorted {
            $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 > $1.element.1
        }.map { $0.element.0 }
    }

    static func prepare(_ data: Data) throws -> PreparedIcon {
        // ICO files often start with a 16 px frame even when larger representations are available.
        // Inspect dimensions without decoding every frame, then decode only the largest one.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw FavoriteSiteIconError.unavailable
        }
        let frames = (0..<min(CGImageSourceGetCount(source), 256)).compactMap { index -> (Int, Int)? in
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return (index, min(width, height))
        }
        guard let frame = frames.max(by: { $0.1 < $1.1 }),
              let image = CGImageSourceCreateThumbnailAtIndex(source, frame.0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw FavoriteSiteIconError.unavailable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw FavoriteSiteIconError.unavailable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FavoriteSiteIconError.unavailable }
        return PreparedIcon(data: output as Data, pixelSize: min(image.width, image.height))
    }
}

enum FavoriteSiteLayout {
    static let iconSize: CGFloat = 16
    static let labelFont = Font.system(size: 12, weight: .medium)
}

/// One icon source for Quick Search, the sidebar, history and bookmark settings.
struct SiteIcon: View {
    @ObservedObject var settings: SearchSettings
    let url: URL
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let data = settings.iconData(for: url), let image = NSImage(data: data) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .task(id: SearchSettings.iconOrigin(url)) { await settings.ensureIcon(for: url) }
        .accessibilityHidden(true)
    }
}

/// Validators and response bodies are bounded and memory-only, separate from WebKit website data.
private actor SiteIconHTTPValidationCache {
    struct Record {
        let data: Data
        let finalURL: URL
        let etag: String?
        let lastModified: String?
        var touched: Int
    }
    private var records: [URL: Record] = [:]
    private var tick = 0

    func record(for url: URL) -> Record? {
        guard var record = records[url] else { return nil }
        tick += 1; record.touched = tick; records[url] = record
        return record
    }

    func store(_ data: Data, for url: URL, finalURL: URL, etag: String?, lastModified: String?) {
        tick += 1
        records[url] = Record(data: data, finalURL: finalURL, etag: etag, lastModified: lastModified, touched: tick)
        while records.count > 64 || records.values.reduce(0, { $0 + $1.data.count }) > 8_000_000 {
            guard let oldest = records.min(by: { $0.value.touched < $1.value.touched })?.key else { break }
            records.removeValue(forKey: oldest)
        }
    }
}

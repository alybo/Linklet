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
        if let data = try? await download(conventionalURL, session: session, accept: "image/*"),
           let image = try? thumbnail(data.data) { return image }

        // Some sites declare only a custom PNG/touch icon in the document head.
        // Fetch the public origin root, never the incoming page's private path or query.
        let htmlData = try await download(homeURL, session: session, accept: "text/html")
        guard let html = String(data: htmlData.data, encoding: .utf8) else { throw FavoriteSiteIconError.unavailable }
        for url in declaredIcons(in: html, baseURL: htmlData.url).prefix(4) {
            if let data = try? await download(url, session: session, accept: "image/*"),
               let image = try? thumbnail(data.data) { return image }
        }
        throw FavoriteSiteIconError.unavailable
    }

    private static func download(_ url: URL, session: URLSession, accept: String) async throws -> (data: Data, url: URL) {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode), data.count <= 512_000 else {
            throw FavoriteSiteIconError.unavailable
        }
        return (data, response.url ?? url)
    }

    static func declaredIcons(in html: String, baseURL: URL) -> [URL] {
        guard let tags = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive),
              let attributes = try? NSRegularExpression(pattern: #"\b(rel|href)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: .caseInsensitive) else { return [] }
        let document = html as NSString
        return tags.matches(in: html, range: NSRange(location: 0, length: document.length)).compactMap { match in
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
            return url
        }
    }

    private static func thumbnail(_ data: Data) throws -> Data {
        // Decode and downsample on this nonisolated async executor, before SwiftUI reads the image.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw FavoriteSiteIconError.unavailable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw FavoriteSiteIconError.unavailable
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw FavoriteSiteIconError.unavailable }
        return output as Data
    }
}

/// One icon source for Quick Search, the sidebar, history and bookmark settings.
struct SiteIcon: View {
    @ObservedObject var settings: SearchSettings
    let url: URL
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let data = settings.iconData(for: url), let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
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

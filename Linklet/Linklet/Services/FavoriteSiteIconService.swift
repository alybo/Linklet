import Foundation
import ImageIO

enum FavoriteSiteIconError: LocalizedError {
    case unavailable

    var errorDescription: String? { L("Couldn't load a favicon for this website.") }
}

/// Downloads the conventional favicon endpoint only after an explicit user action.
enum FavoriteSiteIconService {
    static func fetch(for siteURL: URL) async throws -> Data {
        guard var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false) else {
            throw FavoriteSiteIconError.unavailable
        }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw FavoriteSiteIconError.unavailable }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              data.count <= 512_000,
              CGImageSourceCreateWithData(data as CFData, nil) != nil else {
            throw FavoriteSiteIconError.unavailable
        }
        return data
    }
}

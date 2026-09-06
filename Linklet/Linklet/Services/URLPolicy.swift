import Foundation

enum URLPolicy {
    static let previewSchemes: Set<String> = ["http", "https"]

    static func canPreview(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return previewSchemes.contains(scheme)
    }

    static func normalizedURL(from input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let url = URL(string: value), canPreview(url) {
            return url
        }

        if !value.contains("://"),
           let url = URL(string: "https://\(value)"),
           canPreview(url) {
            return url
        }

        return nil
    }
}

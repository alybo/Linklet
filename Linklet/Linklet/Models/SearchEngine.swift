import Foundation

enum SearchEngine: String, CaseIterable, Identifiable, Codable {
    case google, yandex, duckDuckGo, bing
    var id: Self { self }
    var title: String {
        switch self {
        case .google: return "Google"
        case .yandex: return L("Yandex")
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }

    func searchURL(for query: String) -> URL {
        let endpoint: String
        switch self {
        case .google: endpoint = "https://www.google.com/search"
        case .yandex: endpoint = "https://yandex.ru/search/"
        case .duckDuckGo: endpoint = "https://duckduckgo.com/"
        case .bing: endpoint = "https://www.bing.com/search"
        }
        var components = URLComponents(string: endpoint)!
        components.queryItems = [URLQueryItem(name: self == .yandex ? "text" : "q", value: query)]
        // Search endpoints decode form queries, where a literal + means a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

enum SearchInput {
    static func destination(for input: String, engine: SearchEngine) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return webAddress(text) ?? engine.searchURL(for: text)
    }

    private static func webAddress(_ text: String) -> URL? {
        // Whitespace is valid in a query, but never infer a hostname from it.
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let explicit = text.lowercased().hasPrefix("https://") || text.lowercased().hasPrefix("http://")
        let candidate = text.hasPrefix("//") ? "https:\(text)" : (explicit ? text : "https://\(text)")
        guard let url = URL(string: candidate), URLPolicy.canPreview(url),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        if explicit { return url }
        if host == "localhost" || host.contains(":") { return url }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.first != "-" && label.last != "-" &&
            label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else { return nil }
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return url }
        guard let suffix = labels.last, suffix.count >= 2,
              suffix.allSatisfy({ $0.isLetter }) || suffix.hasPrefix("xn--") else { return nil }
        return url
    }
}

/// Receives text supplied by integrations; never reads another app's selection.
enum SearchRequest {
    static func query(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "linklet", components.host == "search",
              components.path.isEmpty || components.path == "/",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "text", let text = items[0].value else { return nil }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }
}

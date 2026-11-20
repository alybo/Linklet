import AppKit

struct DefaultBrowserService {
    private let applicationForURL: (URL) -> URL?
    private let openURL: (URL) -> Bool

    init(applicationForURL: @escaping (URL) -> URL? = NSWorkspace.shared.urlForApplication(toOpen:),
         openURL: @escaping (URL) -> Bool = NSWorkspace.shared.open(_:)) {
        self.applicationForURL = applicationForURL
        self.openURL = openURL
    }

    func isLinkletDefault() -> Bool {
        ["http", "https"].allSatisfy { scheme in
            guard let probeURL = URL(string: "\(scheme)://peekroute.invalid") else { return false }
            return isLinkletDefault(for: probeURL)
        }
    }

    func isLinkletDefault(for url: URL) -> Bool {
        guard let ownID = Bundle.main.bundleIdentifier,
              let applicationURL = applicationForURL(url) else { return false }
        return Bundle(url: applicationURL)?.bundleIdentifier == ownID
    }

    func open(_ url: URL) -> Bool { openURL(url) }

    func makeLinkletDefault() async throws {
        let applicationURL = Bundle.main.bundleURL
        let workspace = NSWorkspace.shared
        try await workspace.setDefaultApplication(
            at: applicationURL,
            toOpenURLsWithScheme: "http"
        )
        try await workspace.setDefaultApplication(
            at: applicationURL,
            toOpenURLsWithScheme: "https"
        )
    }
}

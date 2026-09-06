import AppKit

struct DefaultBrowserService {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func isLinkletDefault() -> Bool {
        guard let ownID = Bundle.main.bundleIdentifier else { return false }

        return ["http", "https"].allSatisfy { scheme in
            guard let probeURL = URL(string: "\(scheme)://peekroute.invalid"),
                  let currentAppURL = workspace.urlForApplication(toOpen: probeURL)
            else { return false }

            return Bundle(url: currentAppURL)?.bundleIdentifier == ownID
        }
    }

    func makeLinkletDefault() async throws {
        let applicationURL = Bundle.main.bundleURL
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

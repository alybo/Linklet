import Foundation

struct BrowserTarget: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case browser
        case orionProfile
    }

    let id: String
    let displayName: String
    let applicationURL: URL
    let kind: Kind
    let browserName: String
    let profileName: String?

    var secondaryText: String {
        switch kind {
        case .browser:
            return L("Browser")
        case .orionProfile:
            return browserName
        }
    }

    static func browser(name: String, applicationURL: URL) -> BrowserTarget {
        BrowserTarget(
            id: "browser:\(applicationURL.standardizedFileURL.path)",
            displayName: name,
            applicationURL: applicationURL,
            kind: .browser,
            browserName: name,
            profileName: nil
        )
    }

    static func orionProfile(
        name: String,
        applicationURL: URL,
        channelName: String
    ) -> BrowserTarget {
        BrowserTarget(
            id: "orion-profile:\(applicationURL.standardizedFileURL.path)",
            displayName: name,
            applicationURL: applicationURL,
            kind: .orionProfile,
            browserName: channelName,
            profileName: name
        )
    }
}

import AppKit

struct BrowserDiscoveryService {
    private let workspace: NSWorkspace
    private let orionLocator: OrionProfileLocator

    init(
        workspace: NSWorkspace = .shared,
        orionLocator: OrionProfileLocator = OrionProfileLocator()
    ) {
        self.workspace = workspace
        self.orionLocator = orionLocator
    }

    func discoverTargets() -> [BrowserTarget] {
        let probeURL = URL(string: "https://example.com")!
        let ownBundleIdentifier = Bundle.main.bundleIdentifier

        let browsers = workspace.urlsForApplications(toOpen: probeURL).compactMap { appURL -> BrowserTarget? in
            let bundle = Bundle(url: appURL)
            if bundle?.bundleIdentifier == ownBundleIdentifier {
                return nil
            }
            guard isLikelyBrowser(bundle) else { return nil }

            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? appURL.deletingPathExtension().lastPathComponent
            return .browser(name: name, applicationURL: appURL)
        }

        let profiles = orionLocator.discoverProfiles()
        var seenPaths = Set<String>()

        return (profiles + browsers)
            .filter { seenPaths.insert($0.applicationURL.standardizedFileURL.path).inserted }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .orionProfile
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func isLikelyBrowser(_ bundle: Bundle?) -> Bool {
        guard let info = bundle?.infoDictionary else { return false }

        // Link routers and menu bar utilities also register for HTTP/HTTPS. They
        // are useful default handlers but are not destinations in Linklet.
        if info["LSUIElement"] as? Bool == true {
            return false
        }

        let documentTypes = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        return documentTypes.contains { documentType in
            let contentTypes = documentType["LSItemContentTypes"] as? [String] ?? []
            let extensions = documentType["CFBundleTypeExtensions"] as? [String] ?? []

            return contentTypes.contains(where: { type in
                type == "public.html" || type == "public.xhtml"
            }) || extensions.contains(where: { fileExtension in
                ["html", "htm", "shtml", "xhtml"].contains(fileExtension.lowercased())
            })
        }
    }
}

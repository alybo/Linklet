import AppKit

enum BrowserLaunchError: LocalizedError {
    case refusedSelfTarget

    var errorDescription: String? {
        switch self {
        case .refusedSelfTarget:
            return L("Linklet cannot route a link back to itself.")
        }
    }
}

struct BrowserLaunchService {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func open(
        _ url: URL,
        in target: BrowserTarget,
        completion: @escaping (Error?) -> Void
    ) {
        if Bundle(url: target.applicationURL)?.bundleIdentifier == Bundle.main.bundleIdentifier {
            completion(BrowserLaunchError.refusedSelfTarget)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        if target.kind == .orionProfile {
            configuration.allowsRunningApplicationSubstitution = false
        }

        workspace.open(
            [url],
            withApplicationAt: target.applicationURL,
            configuration: configuration
        ) { _, error in
            DispatchQueue.main.async {
                completion(error)
            }
        }
    }
}

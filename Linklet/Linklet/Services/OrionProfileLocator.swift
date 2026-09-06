import Foundation

struct OrionProfileLocator {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func defaultSearchRoots(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            homeDirectory.appending(path: "Applications/Orion/Orion Profiles", directoryHint: .isDirectory),
            homeDirectory.appending(path: "Applications/Orion RC/Orion RC Profiles", directoryHint: .isDirectory),
            homeDirectory.appending(path: "Applications/Orion Profiles", directoryHint: .isDirectory)
        ]
    }

    func discoverProfiles(searchRoots: [URL]? = nil) -> [BrowserTarget] {
        let roots = searchRoots ?? defaultSearchRoots()
        var targets: [BrowserTarget] = []
        var seenPaths = Set<String>()

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }

                let path = url.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }

                let appName = url.deletingPathExtension().lastPathComponent
                guard appName.localizedCaseInsensitiveContains("Orion") else { continue }

                let profileName = parsedProfileName(from: appName)
                let channelName = appName.localizedCaseInsensitiveContains("RC") ? "Orion RC" : "Orion"
                targets.append(.orionProfile(
                    name: profileName,
                    applicationURL: url,
                    channelName: channelName
                ))
            }
        }

        return targets.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func parsedProfileName(from applicationName: String) -> String {
        guard let separator = applicationName.range(of: " - ", options: .backwards) else {
            return applicationName
        }
        let candidate = applicationName[separator.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? applicationName : candidate
    }
}

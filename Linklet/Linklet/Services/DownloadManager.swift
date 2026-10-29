import AppKit
import Combine
import CoreServices
import WebKit

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    enum State { case choosing, downloading, finishing, finished, cancelled, failed }
    let id = UUID()
    @Published var filename = L("Download")
    @Published var state: State = .choosing
    @Published var received: Int64 = 0
    @Published var expected: Int64 = 0
    @Published var error: String?
    var destination: URL?
    var isActive: Bool { [.choosing, .downloading, .finishing].contains(state) }
    var canCancel: Bool { [.choosing, .downloading].contains(state) }
    var fraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
    var status: String {
        switch state {
        case .choosing: return L("Choose where to save")
        case .downloading:
            let size = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            return expected > 0 ? "\(size) / \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))" : size
        case .finishing: return L("Saving file…")
        case .finished: return L("Download complete")
        case .cancelled: return L("Download cancelled")
        case .failed: return error ?? L("Download failed")
        }
    }
}

/// Owns WebKit transfers independently of page/window lifetime. Neither URLs nor
/// download history are persisted. WebKit retains the original POST/cookie context.
@MainActor
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var activeCount = 0
    var hasActiveDownloads: Bool { activeCount > 0 }
    var hasPendingWork: Bool { !jobs.isEmpty || picking != nil || !cleanupTasks.isEmpty }

    @MainActor private final class Job {
        let download: WKDownload
        let item = DownloadItem()
        let releaseWebsiteData: () -> Void
        var destinationHandler: ((URL?) -> Void)?
        var folder: URL?
        var fingerprint: DownloadFiles.Fingerprint?
        init(_ download: WKDownload, release: @escaping () -> Void) {
            self.download = download
            releaseWebsiteData = release
        }
        func resolveDestination(_ url: URL?) {
            let handler = destinationHandler
            destinationHandler = nil
            handler?(url)
        }
    }
    private var jobs: [ObjectIdentifier: Job] = [:]
    private var destinationQueue: [Job] = []
    private var picking: Job?
    private var savePanel: NSSavePanel?
    private var progressTimer: Timer?
    private var isStopping = false
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    // Tests choose files in a temporary directory without driving a system dialog.
    private let chooseDestination: (@MainActor (String) async -> URL?)?

    init(chooseDestination: (@MainActor (String) async -> URL?)? = nil) {
        self.chooseDestination = chooseDestination
        super.init()
    }

    func adopt(_ download: WKDownload, from session: PreviewSession) {
        guard !isStopping else { download.cancel(nil); return }
        guard jobs[ObjectIdentifier(download)] == nil else { return }
        let job = Job(download, release: session.retainWebsiteDataForDownload())
        jobs[ObjectIdentifier(download)] = job
        items.append(job.item)
        download.delegate = self
        updateActivity()
    }

    func cancel(_ id: UUID) {
        guard let job = jobs.values.first(where: { $0.item.id == id }), job.item.canCancel else { return }
        job.item.state = .cancelled
        if picking === job { savePanel?.cancel(nil) }
        job.resolveDestination(nil)
        updateActivity()
        job.download.cancel { [weak self] _ in self?.finish(job, state: .cancelled) }
    }

    func cancelAll() {
        for job in Array(jobs.values) where job.item.canCancel { cancel(job.item.id) }
    }

    func stopForTermination() async {
        isStopping = true
        cancelAll()
        // Keep the run loop alive for WebKit cancellation callbacks and any
        // atomic file publication already underway before allowing normal quit.
        while !jobs.isEmpty || picking != nil { try? await Task.sleep(for: .milliseconds(30)) }
        for task in Array(cleanupTasks.values) { await task.value }
    }

    func clearFinished() { items.removeAll { !$0.isActive } }

    func reveal(_ item: DownloadItem) {
        guard item.state == .finished, let url = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let job = jobs[ObjectIdentifier(download)], job.item.state == .choosing else {
            completionHandler(nil); return
        }
        job.item.filename = Self.safeFilename(suggestedFilename)
        job.destinationHandler = completionHandler
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            job.item.error = L("The server returned HTTP %d.", http.statusCode)
            job.resolveDestination(nil)
            download.cancel { [weak self] _ in self?.finish(job, state: .failed) }
            return
        }
        destinationQueue.append(job)
        pickNextDestination()
    }

    private func pickNextDestination() {
        guard picking == nil else { return }
        while let next = destinationQueue.first, jobs[ObjectIdentifier(next.download)] !== next || next.item.state != .choosing {
            destinationQueue.removeFirst()
        }
        guard !destinationQueue.isEmpty else { return }
        let job = destinationQueue.removeFirst()
        picking = job
        Task { @MainActor in
            let selected: URL?
            if let chooseDestination { selected = await chooseDestination(job.item.filename) }
            else { selected = await presentSavePanel(filename: job.item.filename) }
            if jobs[ObjectIdentifier(job.download)] === job, job.item.state == .choosing {
                if let selected, selected.isFileURL {
                    do {
                        let prepared = try await Task.detached(priority: .utility) {
                            try DownloadFiles.prepare(destination: selected)
                        }.value
                        if jobs[ObjectIdentifier(job.download)] === job, job.item.state == .choosing {
                            job.folder = prepared.folder
                            job.fingerprint = prepared.existing
                            job.item.destination = selected
                            job.item.filename = selected.lastPathComponent
                            job.item.state = .downloading
                            job.resolveDestination(prepared.folder.appendingPathComponent(job.item.filename))
                        } else {
                            cleanup(prepared.folder)
                        }
                    } catch {
                        job.item.error = error.localizedDescription
                        job.resolveDestination(nil)
                        job.download.cancel { [weak self] _ in self?.finish(job, state: .failed) }
                    }
                } else { cancel(job.item.id) }
            }
            picking = nil
            updateActivity()
            pickNextDestination()
        }
    }

    private func presentSavePanel(filename: String) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.title = L("Save download")
            panel.nameFieldStringValue = filename
            panel.canCreateDirectories = true
            panel.showsTagField = false
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            savePanel = panel
            NSApp.activate(ignoringOtherApps: true)
            // Not a sheet of the originating page: that page may close meanwhile.
            panel.begin { [weak self] response in
                self?.savePanel = nil
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let job = jobs[ObjectIdentifier(download)], job.item.state == .downloading,
              let folder = job.folder, let destination = job.item.destination else { return }
        job.item.received = max(job.item.received, download.progress.completedUnitCount)
        job.item.state = .finishing
        let source = folder.appendingPathComponent(job.item.filename)
        let existing = job.fingerprint
        Task { @MainActor in
            do {
                try await Task.detached(priority: .utility) {
                    try DownloadFiles.publish(source: source, destination: destination, existing: existing)
                }.value
                finish(job, state: .finished)
            } catch {
                job.item.error = error.localizedDescription
                finish(job, state: .failed)
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let job = jobs[ObjectIdentifier(download)] else { return }
        if job.item.state != .cancelled { job.item.error = error.localizedDescription }
        finish(job, state: job.item.state == .cancelled ? .cancelled : .failed)
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(request.url.map(URLPolicy.canPreview) == true ? .allow : .cancel)
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    private func finish(_ job: Job, state: DownloadItem.State) {
        guard jobs.removeValue(forKey: ObjectIdentifier(job.download)) != nil else { return }
        job.resolveDestination(nil)
        job.download.delegate = nil
        job.item.state = state
        job.releaseWebsiteData()
        if let folder = job.folder { cleanup(folder) }
        updateActivity()
    }

    private func cleanup(_ folder: URL) {
        let id = UUID()
        let task = Task.detached(priority: .utility) { DownloadFiles.remove(folder) }
        cleanupTasks[id] = task
        Task { @MainActor in
            await task.value
            cleanupTasks.removeValue(forKey: id)
        }
    }

    private func updateActivity() {
        activeCount = items.filter(\.isActive).count
        if activeCount > 0, progressTimer == nil {
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for job in self.jobs.values where job.item.state == .downloading {
                        let progress = job.download.progress
                        if job.item.received != progress.completedUnitCount { job.item.received = progress.completedUnitCount }
                        if job.item.expected != progress.totalUnitCount { job.item.expected = progress.totalUnitCount }
                    }
                }
            }
        } else if activeCount == 0 {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    static func safeFilename(_ proposed: String) -> String {
        let basename = (proposed.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let clean = String(String.UnicodeScalarView(basename.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return clean.isEmpty ? L("Download") : String(clean.prefix(180))
    }
}

/// Filesystem work stays off MainActor. Stage bytes away from the selected file,
/// and publish only after success, preserving any existing file on error/cancel.
enum DownloadFiles {
    struct Fingerprint: Equatable, Sendable {
        let inode: UInt64
        let size: UInt64
        let modified: Date?
    }
    struct Prepared: Sendable { let folder: URL; let existing: Fingerprint? }

    static func fingerprint(_ url: URL) throws -> Fingerprint? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return nil }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileWriteInvalidFileName) }
        return Fingerprint(inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                           size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                           modified: attributes[.modificationDate] as? Date)
    }

    static func prepare(destination: URL) throws -> Prepared {
        let existing = try fingerprint(destination)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LinkletDownload-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return Prepared(folder: folder, existing: existing)
    }

    static func publish(source: URL, destination: URL, existing: Fingerprint?) throws {
        let manager = FileManager.default
        var pending = destination.deletingLastPathComponent().appendingPathComponent(".Linklet-\(UUID()).download")
        defer { remove(pending) }
        try manager.copyItem(at: source, to: pending)
        if try pending.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties == nil {
            var values = URLResourceValues()
            values.quarantineProperties = [
                kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
                kLSQuarantineAgentNameKey as String: "Linklet",
                kLSQuarantineTimeStampKey as String: Date()
            ]
            try pending.setResourceValues(values)
        }
        guard try fingerprint(destination) == existing else { throw CocoaError(.fileWriteFileExists) }
        if existing != nil {
            _ = try manager.replaceItemAt(destination, withItemAt: pending, options: .usingNewMetadataOnly)
        }
        else { try manager.moveItem(at: pending, to: destination) }
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

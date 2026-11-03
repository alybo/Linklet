import Foundation
import Network
import OSLog
import WebKit

/// Used only by builds with LINKLET_TCP_UPLOAD_DIAGNOSTICS. CONNECT keeps TLS
/// end-to-end in WebKit; this process forwards opaque bytes and never logs them.
@MainActor
final class DiagnosticUploadTransport {
    static let shared = DiagnosticUploadTransport()
    private let tunnel: UploadConnectTunnel
    private var startup: Task<NWEndpoint.Port?, Never>?
    private let configured = NSHashTable<WKWebsiteDataStore>.weakObjects()

    init(tunnel: UploadConnectTunnel = UploadConnectTunnel()) { self.tunnel = tunnel }

    func prepare(_ store: WKWebsiteDataStore) async {
        guard !configured.contains(store), store.proxyConfigurations.isEmpty else { return }
        if startup == nil {
            let tunnel = tunnel
            startup = Task {
                do { return try await tunnel.start() }
                catch {
                    Logger(subsystem: "Linklet", category: "UploadTransport")
                        .error("Could not start diagnostic upload transport")
                    return nil
                }
            }
        }
        guard let port = await startup?.value else { return }
        // Another navigation may have awaited the same listener.
        guard !configured.contains(store), store.proxyConfigurations.isEmpty else { return }
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .ipv4(.loopback), port: port))
        proxy.matchDomains = ["upload.youtube.com"]
        proxy.allowFailover = false
        store.proxyConfigurations = [proxy]
        configured.add(store)
    }
}

/// Loopback-only CONNECT endpoint with a single fixed destination. Socket work
/// and bounded, backpressured forwarding stay on a utility queue.
final class UploadConnectTunnel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Linklet.UploadConnectTunnel", qos: .utility)
    private let upstream: NWEndpoint
    private var listener: NWListener?
    private var sessions: [UUID: UploadTunnelConnection] = [:]
    private var waiters: [CheckedContinuation<NWEndpoint.Port, Error>] = []

    init(upstream: NWEndpoint = .hostPort(host: "upload.youtube.com", port: 443)) {
        self.upstream = upstream
    }

    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let port = self.listener?.port { continuation.resume(returning: port); return }
                self.waiters.append(continuation)
                guard self.listener == nil else { return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if let port = listener?.port { self.finishStart(.success(port)) }
                        case .failed(let error): self.finishStart(.failure(error))
                        case .cancelled: self.finishStart(.failure(CancellationError()))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] client in
                        guard let self, self.sessions.count < 16 else { client.cancel(); return }
                        let id = UUID()
                        let connection = UploadTunnelConnection(client: client, upstream: self.upstream,
                            queue: self.queue) { [weak self] in self?.sessions[id] = nil }
                        self.sessions[id] = connection
                        connection.start()
                    }
                    listener.start(queue: self.queue)
                } catch { self.finishStart(.failure(error)) }
            }
        }
    }

    private func finishStart(_ result: Result<NWEndpoint.Port, Error>) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.finishStart(.failure(CancellationError()))
            for session in Array(self.sessions.values) { session.close() }
        }
    }
}

private final class UploadTunnelConnection: @unchecked Sendable {
    private let client: NWConnection
    private let upstream: NWEndpoint
    private let queue: DispatchQueue
    private let onClose: () -> Void
    private var remote: NWConnection?
    private var header = Data()
    private var closed = false
    private var connected = false
    private var endedDirections = 0

    init(client: NWConnection, upstream: NWEndpoint, queue: DispatchQueue, onClose: @escaping () -> Void) {
        self.client = client; self.upstream = upstream; self.queue = queue; self.onClose = onClose
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
        }
        client.start(queue: queue)
        readHeader()
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.connected else { return }
            self.close()
        }
    }

    private func readHeader() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil else { self.close(); return }
            self.header.append(bytes ?? Data())
            guard let split = self.header.range(of: Data("\r\n\r\n".utf8)) else {
                if self.header.count > 8192 { self.reject() }
                else if complete { self.close() }
                else { self.readHeader() }
                return
            }
            let line = String(decoding: self.header[..<split.lowerBound], as: UTF8.self)
                .components(separatedBy: "\r\n").first
            guard split.lowerBound <= 8192,
                  line == "CONNECT upload.youtube.com:443 HTTP/1.1"
                    || line == "CONNECT upload.youtube.com:443 HTTP/1.0" else { self.reject(); return }
            let remainder = Data(self.header[split.upperBound...])
            self.header.removeAll()
            self.connect(remainder: remainder)
        }
    }

    private func reject() {
        client.send(content: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                    completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    private func connect(remainder: Data) {
        let remote = NWConnection(to: upstream, using: .tcp)
        self.remote = remote
        remote.stateUpdateHandler = { [weak self, weak remote] state in
            guard let self, let remote, !self.closed else { return }
            switch state {
            case .ready:
                guard !self.connected else { return }
                self.connected = true
                self.client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                    completion: .contentProcessed { [weak self] error in
                        guard let self, !self.closed else { return }
                        guard error == nil else { self.close(); return }
                        self.pump(from: remote, to: self.client)
                        if remainder.isEmpty { self.pump(from: self.client, to: remote) }
                        else {
                            remote.send(content: remainder, completion: .contentProcessed { [weak self] error in
                                guard let self, !self.closed else { return }
                                if error == nil { self.pump(from: self.client, to: remote) }
                                else { self.close() }
                            })
                        }
                    })
            case .failed: self.close()
            default: break
            }
        }
        remote.start(queue: queue)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] bytes, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil else { self.close(); return }
            let advance: @Sendable () -> Void = { [weak self] in
                guard let self, !self.closed else { return }
                if complete {
                    destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
                            guard let self, !self.closed else { return }
                            self.endedDirections += 1
                            if self.endedDirections == 2 { self.close() }
                        })
                } else { self.pump(from: source, to: destination) }
            }
            if let bytes, !bytes.isEmpty {
                destination.send(content: bytes, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.close() } else { advance() }
                })
            } else { advance() }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        client.cancel(); remote?.cancel()
        client.stateUpdateHandler = nil; remote?.stateUpdateHandler = nil
        onClose()
    }
}

import AppKit
import AVFoundation
import CoreLocation
import WebKit

@MainActor
enum NativeLocationProvider {
    static func install(in pool: WKProcessPool) -> Bool { LKInstallNativeLocationProvider(pool) }
#if DEBUG
    static func useTestLocation(_ location: CLLocation, in pool: WKProcessPool) { LKUseTestLocation(pool, location) }
    static func isUpdating(in pool: WKProcessPool) -> Bool { LKLocationProviderIsUpdating(pool) }
#endif
}

struct MediaSiteOrigin: Codable, Hashable {
    private enum CodingKeys: String, CodingKey { case address }
    let address: String
    var url: URL { URL(string: address)! }
    var host: String { url.host ?? address }
    init?(url: URL) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        parts.scheme = scheme; parts.host = host
        parts.user = nil; parts.password = nil; parts.path = ""; parts.query = nil; parts.fragment = nil
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        guard let address = parts.url?.absoluteString else { return nil }
        self.address = address
    }
    init?(_ origin: WKSecurityOrigin) {
        var parts = URLComponents()
        parts.scheme = origin.protocol; parts.host = origin.host
        if origin.port > 0 { parts.port = origin.port }
        guard let url = parts.url else { return nil }
        self.init(url: url)
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let address = try container.decode(String.self, forKey: .address)
        guard let url = URL(string: address), let origin = Self(url: url), origin.address == address else {
            throw DecodingError.dataCorruptedError(forKey: .address, in: container, debugDescription: "Invalid website origin")
        }
        self = origin
    }
    var isSecure: Bool {
        if url.scheme == "https" { return true }
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || ["::1", "[::1]"].contains(host) { return true }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return false }
        let octets = pieces.compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 127 && octets.allSatisfy { (0...255).contains($0) }
    }
}

enum SiteMediaDevice: String, CaseIterable, Codable {
    case camera, microphone, location
    var title: String {
        switch self { case .camera: return L("Camera"); case .microphone: return L("Microphone"); case .location: return L("Location") }
    }
    var mediaType: AVMediaType? {
        switch self { case .camera: return .video; case .microphone: return .audio; case .location: return nil }
    }
    static var availableDevices: [Self] {
        if #available(macOS 27.0, *) { return allCases }
        return [.camera, .microphone]
    }
}

enum SiteMediaChoice: String, CaseIterable, Codable {
    case ask, allow, deny
    var title: String {
        switch self { case .ask: return L("Ask"); case .allow: return L("Allow"); case .deny: return L("Block") }
    }
}

struct SiteMediaRule: Codable, Identifiable, Equatable {
    let top: MediaSiteOrigin
    let requester: MediaSiteOrigin
    var camera: SiteMediaChoice = .ask
    var microphone: SiteMediaChoice = .ask
    var location: SiteMediaChoice = .ask
    var id: String { top.address + "|" + requester.address }
    subscript(device: SiteMediaDevice) -> SiteMediaChoice {
        get { switch device { case .camera: return camera; case .microphone: return microphone; case .location: return location } }
        set { switch device { case .camera: camera = newValue; case .microphone: microphone = newValue; case .location: location = newValue } }
    }

    private enum CodingKeys: String, CodingKey { case top, requester, camera, microphone, location }
    init(top: MediaSiteOrigin, requester: MediaSiteOrigin) { self.top = top; self.requester = requester }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        top = try values.decode(MediaSiteOrigin.self, forKey: .top)
        requester = try values.decode(MediaSiteOrigin.self, forKey: .requester)
        camera = try values.decodeIfPresent(SiteMediaChoice.self, forKey: .camera) ?? .ask
        microphone = try values.decodeIfPresent(SiteMediaChoice.self, forKey: .microphone) ?? .ask
        location = try values.decodeIfPresent(SiteMediaChoice.self, forKey: .location) ?? .ask
    }
}

/// Site consent uses standard NSAlert sheets. macOS owns TCC prompts, and WebKit
/// owns capture and site permissions. The native location adapter forwards fixes
/// to WebKit without storing them in preferences, history, logs or other files.
@MainActor
final class SiteMediaPermissions: ObservableObject {
    static let storageKey = "websiteMediaPermissions"
    @Published private(set) var rules: [SiteMediaRule]
    @Published private(set) var persists: Bool
    private let defaults: UserDefaults
    var systemStatus: (SiteMediaDevice) -> AVAuthorizationStatus
    var requestSystemAccess: (SiteMediaDevice, @escaping (Bool) -> Void) -> Void = {
        guard let media = $0.mediaType else { $1(true); return }
        AVCaptureDevice.requestAccess(for: media, completionHandler: $1)
    }
    // Tests inspect native alerts and resolve them without accessing devices.
    var presentAlert: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
        $0.beginSheetModal(for: $1, completionHandler: $2)
    }
    private var bindings: [ObjectIdentifier: Binding] = [:]
    private var isOpeningSystemSettings = false

    private final class Request {
        let id = UUID()
        let context: SiteMediaRule
        let devices: [SiteMediaDevice]
        let generation: UUID
        let systemDenied: Bool
        var reply: ((WKPermissionDecision) -> Void)?
        var alert: NSAlert?
        var authorizing = false
        init(context: SiteMediaRule, devices: [SiteMediaDevice], generation: UUID, systemDenied: Bool = false,
             reply: ((WKPermissionDecision) -> Void)?) {
            self.context = context; self.devices = devices; self.generation = generation
            self.systemDenied = systemDenied; self.reply = reply
        }
        func resolve(_ decision: WKPermissionDecision) { let callback = reply; reply = nil; callback?(decision) }
    }
    private final class Binding {
        weak var view: WKWebView?
        weak var session: PreviewSession?
        var generation = UUID()
        var contexts: Set<String> = []
        var revoked: Set<SiteMediaDevice> = []
        var warned: Set<SiteMediaDevice> = []
        var requests: [Request] = []
        var observations: [NSKeyValueObservation] = []
        var sheetObserver: NSObjectProtocol?
        var grantGraceUntil = Date.distantPast
        var locationGranted = false
        init(view: WKWebView, session: PreviewSession) { self.view = view; self.session = session }
    }

    var hasPendingOrActiveCapture: Bool {
        isOpeningSystemSettings || bindings.values.contains { binding in
            !binding.requests.isEmpty || binding.grantGraceUntil > Date() || binding.locationGranted
                || (binding.view.map { $0.cameraCaptureState != .none || $0.microphoneCaptureState != .none } ?? false)
        }
    }

    init(defaults: UserDefaults, persists: Bool,
         systemStatus: @escaping (SiteMediaDevice) -> AVAuthorizationStatus = { device in
             if let media = device.mediaType { return AVCaptureDevice.authorizationStatus(for: media) }
             switch CLLocationManager().authorizationStatus {
             case .authorizedAlways, .authorizedWhenInUse: return .authorized
             case .denied: return .denied
             case .restricted: return .restricted
             case .notDetermined: return .notDetermined
             @unknown default: return .denied
             }
         }) {
        self.defaults = defaults; self.persists = persists; self.systemStatus = systemStatus
        let stored = persists ? defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([SiteMediaRule].self, from: $0) } ?? [] : []
        var seen = Set<String>()
        rules = stored.filter { rule in
            MediaSiteOrigin(url: rule.top.url) == rule.top && MediaSiteOrigin(url: rule.requester.url) == rule.requester
                && rule.top.isSecure && rule.requester.isSecure && seen.insert(rule.id).inserted
        }
        if !persists { defaults.removeObject(forKey: Self.storageKey) }
    }

    func attach(_ view: WKWebView, session: PreviewSession) {
        let id = ObjectIdentifier(view)
        guard bindings[id] == nil else { return }
        let binding = Binding(view: view, session: session)
        bindings[id] = binding
        binding.observations = [
            view.observe(\.cameraCaptureState) { [weak self] _, _ in
                Task { @MainActor in self?.enforceRevocation(id, device: .camera) }
            },
            view.observe(\.microphoneCaptureState) { [weak self] _, _ in
                Task { @MainActor in self?.enforceRevocation(id, device: .microphone) }
            }
        ]
    }

    func detach(_ view: WKWebView) {
        let id = ObjectIdentifier(view)
        navigationChanged(in: view)
        guard let binding = bindings.removeValue(forKey: id) else { return }
        if let observer = binding.sheetObserver { NotificationCenter.default.removeObserver(observer) }
        if bindings.isEmpty && !persists { rules = [] }
    }

    func navigationChanged(in view: WKWebView) {
        guard let binding = bindings[ObjectIdentifier(view)] else { return }
        binding.generation = UUID()
        cancelRequests(binding)
        binding.contexts = []; binding.revoked = []; binding.warned = []
        binding.grantGraceUntil = .distantPast
        binding.locationGranted = false
        stop(.camera, in: view); stop(.microphone, in: view)
    }

    func request(in view: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                 type: WKMediaCaptureType, reply: @escaping (WKPermissionDecision) -> Void) {
        guard let topURL = view.url, let top = MediaSiteOrigin(url: topURL),
              let requester = MediaSiteOrigin(origin), MediaSiteOrigin(frame.securityOrigin) == requester else { reply(.deny); return }
        let devices: [SiteMediaDevice]
        switch type {
        case .camera: devices = [.camera]
        case .microphone: devices = [.microphone]
        case .cameraAndMicrophone: devices = [.camera, .microphone]
        @unknown default: reply(.deny); return
        }
        request(in: view, context: SiteMediaRule(top: top, requester: requester), devices: devices, reply: reply)
    }

    func requestLocation(in view: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                         reply: @escaping (WKPermissionDecision) -> Void) {
        guard let url = view.url, let top = MediaSiteOrigin(url: url),
              let requester = MediaSiteOrigin(origin), MediaSiteOrigin(frame.securityOrigin) == requester else { reply(.deny); return }
        request(in: view, context: SiteMediaRule(top: top, requester: requester), devices: [.location], reply: reply)
    }

    func request(in view: WKWebView, context: SiteMediaRule, devices: [SiteMediaDevice],
                 reply: @escaping (WKPermissionDecision) -> Void) {
        let id = ObjectIdentifier(view)
        guard let binding = bindings[id], isValid(binding, context: context), !devices.isEmpty else { reply(.deny); return }
        if !rules.contains(where: { $0.id == context.id }) {
            rules.append(SiteMediaRule(top: context.top, requester: context.requester)); save()
        }
        let rule = rules.first { $0.id == context.id }!
        binding.contexts.insert(context.id)
        guard !devices.contains(where: { rule[$0] == .deny }) else { reply(.deny); return }
        let blocked = devices.filter { [.denied, .restricted].contains(systemStatus($0)) }
        if !blocked.isEmpty {
            reply(.deny)
            if blocked.contains(where: { !binding.warned.contains($0) }) {
                binding.warned.formUnion(blocked)
                enqueue(Request(context: context, devices: blocked, generation: binding.generation, systemDenied: true, reply: nil), in: binding, id: id)
            }
            return
        }
        enqueue(Request(context: context, devices: devices, generation: binding.generation, reply: reply), in: binding, id: id)
    }

    private func isValid(_ binding: Binding, context: SiteMediaRule) -> Bool {
        guard let view = binding.view, let session = binding.session,
              session.isActive, session.webView === view, view.window?.isVisible == true,
              let url = view.url, MediaSiteOrigin(url: url) == context.top else { return false }
        return context.top.isSecure && context.requester.isSecure
    }

    private func enqueue(_ request: Request, in binding: Binding, id: ObjectIdentifier) {
        guard binding.requests.count < 16, let window = binding.view?.window else { request.resolve(.deny); return }
        binding.requests.append(request)
        if binding.sheetObserver == nil {
            binding.sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
                object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.presentNext(id) }
                }
        }
        presentNext(id)
    }

    private func presentNext(_ id: ObjectIdentifier) {
        guard let binding = bindings[id], let request = binding.requests.first, request.alert == nil, !request.authorizing,
              let window = binding.view?.window, window.attachedSheet == nil else { return }
        guard request.generation == binding.generation, isValid(binding, context: request.context) else {
            binding.requests.removeFirst().resolve(.deny); presentNext(id); return
        }
        if !request.systemDenied, let rule = rules.first(where: { $0.id == request.context.id }) {
            let denied = request.devices.contains { rule[$0] == .deny }
            let allowed = request.devices.allSatisfy { rule[$0] == .allow }
            if denied || allowed {
                if denied { finish(request, in: id, decision: .deny) }
                else { request.authorizing = true; authorizeDevices(request, in: id) }
                return
            }
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        let names = L(request.devices.count > 1 ? "the camera and microphone"
            : (request.devices.first == .camera ? "the camera" : request.devices.first == .location ? "your location" : "the microphone"))
        if request.systemDenied {
            alert.messageText = L("macOS has blocked access to %@", names)
            alert.informativeText = L("Allow Linklet in System Settings → Privacy & Security, then try again on the website.")
            alert.addButton(withTitle: L("Open System Settings…"))
            alert.addButton(withTitle: L("Not now"))
        } else {
            alert.messageText = L("Allow %@ to use %@?", request.context.requester.address, names)
            alert.informativeText = request.context.top == request.context.requester
                ? L(request.devices == [.location] ? "Your location helps this website show nearby places and routes." : "This website is requesting access to your devices.")
                : L("This request comes from content embedded in %@.", request.context.top.address)
            alert.addButton(withTitle: L("Allow"))
            alert.addButton(withTitle: L("Don't Allow"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L(persists ? "Remember for this website" : "Remember until all website windows close")
            alert.suppressionButton?.state = .off
        }
        request.alert = alert
        presentAlert(alert, window) { [weak self, weak request] response in
            guard let self, let request, let binding = self.bindings[id],
                  binding.requests.first?.id == request.id else { return }
            guard request.generation == binding.generation, self.isValid(binding, context: request.context) else {
                self.finish(request, in: id, decision: .deny); return
            }
            if request.systemDenied {
                if response == .alertFirstButtonReturn { self.openSystemSettings(for: request.devices[0]) }
                self.finish(request, in: id, decision: .deny)
            } else {
                let allowed = response == .alertFirstButtonReturn
                if !allowed { binding.requests.removeFirst() }
                if alert.suppressionButton?.state == .on {
                    for device in request.devices { self.setChoice(allowed ? .allow : .deny, device: device, ruleID: request.context.id) }
                }
                if allowed { request.authorizing = true; self.authorizeDevices(request, in: id) }
                else { request.resolve(.deny); self.presentNext(id) }
            }
        }
    }

    private func authorizeDevices(_ request: Request, in id: ObjectIdentifier, index: Int = 0) {
        guard let binding = bindings[id], binding.requests.first?.id == request.id,
              request.generation == binding.generation, isValid(binding, context: request.context),
              let rule = rules.first(where: { $0.id == request.context.id }),
              !request.devices.contains(where: { rule[$0] == .deny }) else {
            finish(request, in: id, decision: .deny); return
        }
        guard index < request.devices.count else { finish(request, in: id, decision: .grant); return }
        let device = request.devices[index]
        // After site consent, WebKit starts the native Core Location adapter.
        // That adapter owns system authorization and forwards fixes transiently.
        if device == .location { authorizeDevices(request, in: id, index: index + 1); return }
        switch systemStatus(device) {
        case .authorized: authorizeDevices(request, in: id, index: index + 1)
        case .notDetermined:
            requestSystemAccess(device) { [weak self, weak request] granted in
                Task { @MainActor in
                    guard let self, let request else { return }
                    if granted { self.authorizeDevices(request, in: id, index: index + 1) }
                    else { self.finish(request, in: id, decision: .deny) }
                }
            }
        case .denied, .restricted: finish(request, in: id, decision: .deny)
        @unknown default: finish(request, in: id, decision: .deny)
        }
    }

    private func finish(_ request: Request, in id: ObjectIdentifier, decision: WKPermissionDecision) {
        if let binding = bindings[id] {
            binding.requests.removeAll { $0.id == request.id }
            if decision == .grant {
                binding.revoked.subtract(request.devices)
                binding.grantGraceUntil = Date().addingTimeInterval(5)
                if request.devices.contains(.location) { binding.locationGranted = true }
            }
        }
        request.resolve(decision)
        objectWillChange.send()
        presentNext(id)
    }

    func setChoice(_ choice: SiteMediaChoice, device: SiteMediaDevice, ruleID: String) {
        guard let index = rules.firstIndex(where: { $0.id == ruleID }), rules[index][device] != choice else { return }
        rules[index][device] = choice
        for binding in bindings.values where binding.contexts.contains(ruleID) {
            if choice != .allow {
                cancelRequests(binding, context: ruleID, device: device)
                binding.revoked.insert(device)
                if let view = binding.view { stop(device, in: view) }
                if device == .location { revokeLocation(in: binding) }
            } else { binding.revoked.remove(device) }
        }
        save()
        for id in bindings.keys { presentNext(id) }
    }

    func reset(_ rule: SiteMediaRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].camera = .ask; rules[index].microphone = .ask; rules[index].location = .ask
        // A one-time grant still has Ask in settings; resetting it must revoke
        // capture too, even though neither stored picker value changes.
        for binding in bindings.values where binding.contexts.contains(rule.id) {
            cancelRequests(binding, context: rule.id)
            binding.revoked.formUnion(SiteMediaDevice.allCases)
            if let view = binding.view { stop(.camera, in: view); stop(.microphone, in: view) }
            revokeLocation(in: binding)
        }
        save()
        for id in bindings.keys { presentNext(id) }
    }

    func remove(forDomain domain: String? = nil) {
        let removed = rules.filter { rule in
            guard let domain else { return true }
            return SiteDataService.host(rule.top.host, belongsTo: domain) || SiteDataService.host(rule.requester.host, belongsTo: domain)
        }
        for rule in removed {
            for binding in bindings.values where binding.contexts.contains(rule.id) {
                cancelRequests(binding, context: rule.id)
                binding.revoked.formUnion(SiteMediaDevice.allCases)
                if let view = binding.view { stop(.camera, in: view); stop(.microphone, in: view) }
                revokeLocation(in: binding)
            }
        }
        let ids = Set(removed.map(\.id))
        rules.removeAll { ids.contains($0.id) }
        save()
        for id in bindings.keys { presentNext(id) }
    }

    func setPersistence(_ enabled: Bool) {
        guard persists != enabled else { return }
        persists = enabled
        if !enabled { remove() }
        save()
    }

    func openSystemSettings(for device: SiteMediaDevice) {
        isOpeningSystemSettings = true
        let pane = device == .camera ? "Privacy_Camera" : device == .location ? "Privacy_LocationServices" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }

    func refreshSystemStatus() { isOpeningSystemSettings = false; objectWillChange.send() }

    private func cancelRequests(_ binding: Binding, context: String? = nil, device: SiteMediaDevice? = nil) {
        func matches(_ request: Request) -> Bool {
            (context == nil || request.context.id == context) && (device == nil || request.devices.contains(device!))
        }
        let cancelled = binding.requests.filter(matches)
        binding.requests.removeAll(where: matches)
        for request in cancelled {
            request.resolve(.deny)
            if let sheet = request.alert?.window, let parent = sheet.sheetParent {
                parent.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil)
            }
        }
    }

    private func enforceRevocation(_ id: ObjectIdentifier, device: SiteMediaDevice) {
        guard let binding = bindings[id], binding.revoked.contains(device), let view = binding.view else { return }
        let state = device == .camera ? view.cameraCaptureState : view.microphoneCaptureState
        if state != .none { stop(device, in: view) }
    }
    private func stop(_ device: SiteMediaDevice, in view: WKWebView) {
        if device == .camera { view.setCameraCaptureState(.none, completionHandler: nil) }
        else if device == .microphone { view.setMicrophoneCaptureState(.none, completionHandler: nil) }
    }
    private func revokeLocation(in binding: Binding) {
        guard binding.locationGranted else { return }
        binding.locationGranted = false
        // There is no public API for stopping a page's active location watch.
        // Reloading destroys the old document and its watches, preserving history.
        binding.session?.reload()
    }
    private func save() {
        if persists { defaults.set(try? JSONEncoder().encode(rules), forKey: Self.storageKey) }
        else { defaults.removeObject(forKey: Self.storageKey) }
    }
}

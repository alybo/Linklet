import AppKit
import Carbon

struct SearchShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let initial = SearchShortcut(keyCode: 49, modifiers: UInt32(controlKey | optionKey), keyLabel: "Space")
    var title: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + (keyLabel == "Space" ? L("Space") : keyLabel)
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              ![36, 48, 51, 53, 76, 117].contains(event.keyCode) else { return nil }
        var modifiers: UInt32 = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.command, cmdKey), (.control, controlKey), (.option, optionKey), (.shift, shiftKey)] {
            if flags.contains(flag) { modifiers |= UInt32(carbon) }
        }
        let label = event.keyCode == 49 ? "Space" : event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        guard !label.isEmpty, label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
    }
}

/// Registers a single system hotkey without monitoring other apps' keystrokes.
@MainActor
final class SearchHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    private var isPressed = false

    func register(_ shortcut: SearchShortcut?) -> Bool {
        unregister()
        guard let shortcut else { return true }
        var systemKeys: Unmanaged<CFArray>?
        if CopySymbolicHotKeys(&systemKeys) == noErr,
           let keys = systemKeys?.takeRetainedValue() as? [[String: Any]],
           keys.contains(where: {
               ($0[kHISymbolicHotKeyEnabled as String] as? Bool) == true &&
               ($0[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == shortcut.keyCode &&
               ($0[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == shortcut.modifiers
           }) { return false }
        if handler == nil {
            var events = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                      identifier.signature == 0x4C4E4B53, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    let hotKey = Unmanaged<SearchHotKey>.fromOpaque(context).takeUnretainedValue()
                    hotKey.handle(pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
                }
                return noErr
            }, 2, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return false }
        }
        let identifier = EventHotKeyID(signature: 0x4C4E4B53, id: 1)
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                   GetApplicationEventTarget(), 0, &reference) == noErr
    }

    private func handle(pressed: Bool) {
        guard pressed else { isPressed = false; return }
        guard !isPressed else { return }
        isPressed = true
        action?()
    }

    func unregister() {
        isPressed = false
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor
final class SearchSettings: ObservableObject {
    @Published private(set) var engine: SearchEngine
    @Published private(set) var shortcut: SearchShortcut?
    @Published var shortcutError: String?
    private let defaults: UserDefaults
    private let hotKey = SearchHotKey()
    private var isStarted = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        engine = SearchEngine(rawValue: defaults.string(forKey: "searchEngine") ?? "") ?? .google
        if defaults.bool(forKey: "searchShortcutDisabled") {
            shortcut = nil
        } else {
            shortcut = defaults.data(forKey: "searchShortcut").flatMap { try? JSONDecoder().decode(SearchShortcut.self, from: $0) } ?? .initial
        }
    }

    func start(action: @escaping () -> Void) {
        hotKey.action = action
        isStarted = true
        resumeShortcut()
    }

    func setEngine(_ engine: SearchEngine) {
        self.engine = engine
        defaults.set(engine.rawValue, forKey: "searchEngine")
    }

    @discardableResult
    func setShortcut(_ value: SearchShortcut?) -> Bool {
        if isStarted && !hotKey.register(value) {
            _ = hotKey.register(shortcut)
            shortcutError = L("This shortcut is unavailable. Choose another combination.")
            return false
        }
        shortcut = value
        defaults.set(value == nil, forKey: "searchShortcutDisabled")
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: "searchShortcut")
        shortcutError = nil
        return true
    }

    func suspendShortcut() { hotKey.unregister() }
    func resumeShortcut() {
        guard isStarted else { return }
        shortcutError = hotKey.register(shortcut) ? nil : L("This shortcut is unavailable. Choose another combination.")
    }
}

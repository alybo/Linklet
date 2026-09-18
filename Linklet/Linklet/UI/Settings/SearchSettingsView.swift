import AppKit
import SwiftUI

struct SearchSettingsView: View {
    @ObservedObject var settings: SearchSettings
    let showSearch: () -> Void
    @State private var recording = false
    @State private var eventMonitor: Any?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(L("Open search bar"))
                    Spacer()
                    Button(recording ? L("Press a shortcut…") : settings.shortcut?.title ?? L("Record shortcut")) {
                        if recording { stopRecording() } else { startRecording() }
                    }
                    .frame(minWidth: 150)
                    .help(L("Press Escape to cancel recording"))
                    if settings.shortcut != nil {
                        Button {
                            stopRecording()
                            settings.setShortcut(nil)
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(L("Remove shortcut"))
                    }
                }
                if let error = settings.shortcutError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text(L("Choose a combination with ⌘, ⌥ or ⌃. Linklet must be running."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text(L("Keyboard shortcut")) }
            Section {
                Picker(L("Default search engine"), selection: Binding(get: { settings.engine }, set: settings.setEngine)) {
                    ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
                }
                Text(L("You can change the engine in the search bar for a single query. Web addresses open directly."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(L("Open search bar")) {
                    stopRecording()
                    showSearch()
                }
                Text(L("Results open in the usual Linklet window. Each search starts with an empty field."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if recording { stopRecording() }
        }
    }

    private func startRecording() {
        settings.shortcutError = nil
        settings.suspendShortcut()
        recording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            guard !event.isARepeat else { return nil }
            guard let shortcut = SearchShortcut(event: event) else {
                settings.shortcutError = L("Choose a combination with ⌘, ⌥ or ⌃.")
                return nil
            }
            if settings.setShortcut(shortcut) { stopRecording() }
            else { settings.suspendShortcut() }
            return nil
        }
    }

    private func stopRecording() {
        guard recording else { return }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        recording = false
        settings.resumeShortcut()
    }
}

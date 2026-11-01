import AppKit
import SwiftUI

struct SearchSettingsView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var settings: SearchSettings
    let showSearch: () -> Void
    var browserModel: AppModel? = nil
    @State private var recording = false
    @State private var eventMonitor: Any?

    var body: some View {
        Form {
            SettingsPageHeader(page: .search)
            Section {
                Picker(L("Search engine"), selection: Binding(get: { settings.engine }, set: settings.setEngine)) {
                    ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Text(L("Open Quick Search"))
                    Spacer()
                    Button(recording ? L("Press a shortcut…") : settings.shortcut?.title ?? L("Set Shortcut…")) {
                        if recording { stopRecording() } else { startRecording() }
                    }.help(L("Press Escape to cancel recording"))
                    if settings.shortcut != nil {
                        Button { stopRecording(); settings.setShortcut(nil) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel(L("Remove shortcut"))
                    }
                }
                if let error = settings.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
                Toggle(L("Show bookmarks"), isOn: Binding(get: { settings.showsFavoriteSites }, set: settings.setShowsFavoriteSites))
                Button(L("Open Quick Search")) { stopRecording(); showSearch() }
            } header: { Text(L("Quick Search")) } footer: {
                Text(L("Web addresses open directly. Other text is sent to your search engine."))
            }
            if let browserModel { BrowserSettingsSections(model: browserModel) }
        }
        .formStyle(.grouped).toggleStyle(.switch)
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

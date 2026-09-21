import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SearchSettingsView: View {
    @ObservedObject var settings: SearchSettings
    let showSearch: () -> Void
    @State private var recording = false
    @State private var eventMonitor: Any?
    @State private var showingFavoriteEditor = false
    @State private var editingFavorite: FavoriteSite?
    @State private var draggedFavoriteID: UUID?
    @State private var dropTargetFavoriteID: UUID?

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
            Section {
                Toggle(L("Show favorites in Quick Search"), isOn: Binding(
                    get: { settings.showsFavoriteSites }, set: settings.setShowsFavoriteSites))
                .disabled(settings.favoriteSites.isEmpty)
                if settings.favoriteSites.isEmpty {
                    Text(L("Add websites you open often to show them in Quick Search."))
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.favoriteSites) { site in
                    favoriteRow(site)
                        .onDrag {
                            draggedFavoriteID = site.id
                            return NSItemProvider(object: site.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.text], delegate: FavoriteSiteDropDelegate(
                            destination: site.id, settings: settings,
                            draggedID: $draggedFavoriteID, dropTargetID: $dropTargetFavoriteID))
                        .overlay(alignment: .top) {
                            if dropTargetFavoriteID == site.id {
                                Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
                            }
                        }
                }
                HStack {
                    Button { editingFavorite = nil; showingFavoriteEditor = true } label: {
                        Label(L("Add website"), systemImage: "plus")
                    }
                    Spacer()
                    if !settings.favoriteSites.isEmpty {
                        Text(L("Drag to reorder."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDrop(of: [UTType.text], delegate: FavoriteSiteDropDelegate(
                    destination: nil, settings: settings,
                    draggedID: $draggedFavoriteID, dropTargetID: $dropTargetFavoriteID))
            } header: {
                Text(L("Favorite websites"))
            } footer: {
                Text(L("Favorites are stored only in Linklet on this Mac. They open in the usual private preview."))
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingFavoriteEditor) {
            FavoriteSiteEditor(site: editingFavorite) { name, address in
                do {
                    if let editingFavorite {
                        try settings.updateFavoriteSite(editingFavorite, name: name, address: address)
                    } else {
                        try settings.addFavoriteSite(name: name, address: address)
                    }
                    showingFavoriteEditor = false
                } catch {
                    return error.localizedDescription
                }
                return nil
            }
        }
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

    private func favoriteRow(_ site: FavoriteSite) -> some View {
        HStack(spacing: 10) {
            FavoriteSiteSettingsIcon(site: site)
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name)
                Text(site.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                editingFavorite = site
                showingFavoriteEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L("Edit"))
            Button { settings.loadFavoriteIcon(for: site) } label: {
                if settings.loadingFavoriteIconIDs.contains(site.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .buttonStyle(.borderless)
            .disabled(settings.loadingFavoriteIconIDs.contains(site.id))
            .help(L("Load favicon"))
            .accessibilityLabel(L("Load favicon"))
            Button(role: .destructive) { settings.removeFavoriteSite(site) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L("Remove"))
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("Edit…")) { editingFavorite = site; showingFavoriteEditor = true }
            Button(L("Move up")) { settings.moveFavoriteSite(site.id, offset: -1) }
                .disabled(settings.favoriteSites.first?.id == site.id)
            Button(L("Move down")) { settings.moveFavoriteSite(site.id, offset: 1) }
                .disabled(settings.favoriteSites.last?.id == site.id)
            Divider()
            Button(L("Remove"), role: .destructive) { settings.removeFavoriteSite(site) }
        }
        .accessibilityAction(named: Text(L("Edit"))) { editingFavorite = site; showingFavoriteEditor = true }
        .accessibilityAction(named: Text(L("Move up"))) { settings.moveFavoriteSite(site.id, offset: -1) }
        .accessibilityAction(named: Text(L("Move down"))) { settings.moveFavoriteSite(site.id, offset: 1) }
    }
}

private struct FavoriteSiteSettingsIcon: View {
    let site: FavoriteSite

    var body: some View {
        Group {
            if let data = site.faviconData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().padding(2)
            } else {
                Image(systemName: "globe").foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
    }
}

private struct FavoriteSiteDropDelegate: DropDelegate {
    let destination: UUID?
    let settings: SearchSettings
    @Binding var draggedID: UUID?
    @Binding var dropTargetID: UUID?

    func dropEntered(info: DropInfo) { if draggedID != nil { dropTargetID = destination } }
    func dropExited(info: DropInfo) { if dropTargetID == destination { dropTargetID = nil } }
    func validateDrop(info: DropInfo) -> Bool { draggedID != nil }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard let id = draggedID else { return false }
        settings.moveFavoriteSite(id, before: destination)
        draggedID = nil
        dropTargetID = nil
        return true
    }
}

private struct FavoriteSiteEditor: View {
    let site: FavoriteSite?
    let save: (String, String) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var error: String?

    init(site: FavoriteSite?, save: @escaping (String, String) -> String?) {
        self.site = site
        self.save = save
        _name = State(initialValue: site?.name ?? "")
        _address = State(initialValue: site?.address ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(site == nil ? L("Add favorite website") : L("Edit favorite website"))
                .font(.title2.bold())
            TextField(L("Name"), text: $name)
            TextField(L("Web address"), text: $address)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                Button(L("Save")) { error = save(name, address) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
    }
}

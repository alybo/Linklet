import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var model: AppModel
    @ObservedObject private var library: LinkLibrary
    @ObservedObject private var settings: SearchSettings
    let dismiss: () -> Void
    @State private var query = ""
    @State private var showsEditor = false
    @State private var editingSite: FavoriteSite?
    @State private var showsFolderEditor = false
    @State private var editingFolder: BookmarkFolder?
    @State private var folderName = ""

    init(model: AppModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.library = model.linkLibrary
        self.settings = model.searchSettings
        self.dismiss = dismiss
    }

    private func matches(_ title: String, address: String = "") -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query) || address.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image("MenuBarIcon").renderingMode(.template)
                Text("Linklet").font(.headline)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .help(L("Close sidebar"))
            }.padding(16)
            TextField(L("Search links"), text: $query)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 14).padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(L("Bookmarks")).font(.headline)
                        Spacer()
                        Menu {
                            Button(L("Add bookmark")) { editingSite = nil; showsEditor = true }
                            Button(L("New folder")) { editingFolder = nil; folderName = ""; showsFolderEditor = true }
                        } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help(L("Add bookmark or folder"))
                    }
                    ForEach(library.rootOrder, id: \.self) { id in
                        if let folder = library.folders.first(where: { $0.id == id }) {
                            folderRow(folder)
                        } else if let site = settings.favoriteSites.first(where: { $0.id == id }), matches(site.name, address: site.address) {
                            bookmarkRow(site)
                        }
                    }
                    dropSlot(before: nil, folder: nil)
                    if settings.favoriteSites.isEmpty && library.folders.isEmpty {
                        Text(L("Save links here or add the current page with the bookmark button."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider().padding(.vertical, 4)
                    DisclosureGroup(isExpanded: $library.showsRecentLinks) {
                        ForEach(library.recentLinks.filter { matches($0.title, address: $0.address) }) { link in
                            Button { if let url = link.url { open(url) } } label: {
                                linkLabel(title: link.title, address: link.address)
                            }.buttonStyle(.plain)
                            .contextMenu {
                                Button(L("Add bookmark")) {
                                    editingSite = nil
                                    // Recent links use the editor's optional initial URL via a draft.
                                    recentDraft = link
                                    showsEditor = true
                                }
                                Button(L("Remove"), role: .destructive) { library.removeRecent(link) }
                            }
                        }
                        if library.recentLinks.isEmpty {
                            Text(L("No recent links.")).font(.caption).foregroundStyle(.secondary)
                        }
                        if !library.recentLinks.isEmpty {
                            Button(L("Clear history"), role: .destructive, action: library.clearHistory).font(.caption)
                        }
                    } label: { Text(L("Recent links")).font(.headline) }
                    Text(library.savesHistory ? L("History is saved on this Mac.") : L("History is kept until Linklet quits."))
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(14)
            }
            Divider()
            HStack {
                Button { dismiss(); model.showSettings(page: .sidebar) } label: {
                    Label(L("Settings…"), systemImage: "gearshape")
                }
                Spacer()
                Button { dismiss(); model.toggleSearch() } label: { Image(systemName: "magnifyingglass") }
                    .help(L("Quick Search"))
            }.buttonStyle(.plain).padding(16)
        }
        .padding(.vertical, 24)
        .background(Color.black, in: SidebarContour())
        .preferredColorScheme(.dark)
        .onExitCommand(perform: dismiss)
        .sheet(isPresented: $showsEditor, onDismiss: { recentDraft = nil }) {
            BookmarkEditor(settings: settings, library: library, site: editingSite,
                           initialURL: recentDraft?.url, initialTitle: recentDraft?.title ?? "")
        }
        .sheet(isPresented: $showsFolderEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L(editingFolder == nil ? "New folder" : "Rename folder")).font(.title2.bold())
                TextField(L("Name"), text: $folderName)
                HStack {
                    Spacer()
                    Button(L("Cancel")) { showsFolderEditor = false }
                    Button(L("Save")) {
                        if let editingFolder { library.renameFolder(editingFolder, name: folderName) }
                        else { library.addFolder(name: folderName) }
                        showsFolderEditor = false
                    }.keyboardShortcut(.defaultAction)
                        .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).frame(width: 320)
        }
    }

    @State private var recentDraft: RecentLink?

    private func open(_ url: URL) { dismiss(); model.showPreview(url: url) }

    @State private var targetedDrop: UUID?

    private func folderRow(_ folder: BookmarkFolder) -> some View {
        let sites = settings.favoriteSites.filter { library.folderID(for: $0) == folder.id }
        let expanded = !query.isEmpty || library.expandedFolderIDs.contains(folder.id)
        return VStack(alignment: .leading, spacing: 0) {
            if query.isEmpty || matches(folder.name) || sites.contains(where: { matches($0.name, address: $0.address) }) {
                dropSlot(before: folder.id, folder: nil)
                Button {
                    if expanded { library.expandedFolderIDs.remove(folder.id) }
                    else { library.expandedFolderIDs.insert(folder.id) }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: expanded ? "folder.fill" : "folder").font(.system(size: 22))
                            .frame(width: 24)
                        Text(folder.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
                .background(targetedDrop == folder.id ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .onDrag { NSItemProvider(object: folder.id.uuidString as NSString) }
                .onDrop(of: [UTType.text], isTargeted: Binding(get: { targetedDrop == folder.id }, set: { targetedDrop = $0 ? folder.id : nil })) {
                    acceptDrop($0, before: nil, folder: folder.id)
                }
                .contextMenu {
                    Button(L("Rename folder")) { editingFolder = folder; folderName = folder.name; showsFolderEditor = true }
                    Button(L("Move up")) { library.moveItem(folder.id, offset: -1) }
                    Button(L("Move down")) { library.moveItem(folder.id, offset: 1) }
                    Button(L("Remove folder; keep bookmarks"), role: .destructive) { library.removeFolder(folder) }
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sites.filter { query.isEmpty || matches(folder.name) || matches($0.name, address: $0.address) }) { bookmarkRow($0) }
                        dropSlot(before: nil, folder: folder.id)
                        if sites.isEmpty { Text(L("Empty folder")).font(.caption).foregroundStyle(.secondary).padding(.vertical, 6) }
                    }.padding(.leading, 30)
                }
            }
        }
    }

    private func dropSlot(before id: UUID?, folder: UUID?) -> some View {
        SidebarDropSlot { providers in acceptDrop(providers, before: id, folder: folder) }
    }

    private func acceptDrop(_ providers: [NSItemProvider], before id: UUID?, folder: UUID?) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String, let source = UUID(uuidString: text) else { return }
            Task { @MainActor in library.moveItem(source, before: id, into: folder) }
        }
        return true
    }

    private func bookmarkRow(_ site: FavoriteSite) -> some View {
        VStack(spacing: 0) {
            dropSlot(before: site.id, folder: library.folderID(for: site))
            Button { open(site.url) } label: { linkLabel(title: site.name, address: site.address) }
            .buttonStyle(.plain)
            .contextMenu {
                Button(L("Edit")) { editingSite = site; showsEditor = true }
                Menu(L("Move to folder")) {
                    Button(L("No folder")) { library.moveBookmark(site, to: nil) }
                    ForEach(library.folders) { folder in
                        Button(folder.name) { library.moveBookmark(site, to: folder.id) }
                    }
                }
                Button(L("Move up")) { library.moveItem(site.id, offset: -1) }
                Button(L("Move down")) { library.moveItem(site.id, offset: 1) }
                Button(L("Remove"), role: .destructive) { settings.removeFavoriteSite(site) }
            }
            .onDrag { NSItemProvider(object: site.id.uuidString as NSString) }
        }
    }

    private func linkLabel(title: String, address: String) -> some View {
        HStack(spacing: 9) {
            if let url = URL(string: address) { SiteIcon(settings: settings, url: url, size: 22) }
            Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }.padding(.vertical, 7).contentShape(Rectangle()).help(address)
    }
}

struct BookmarkEditor: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var settings: SearchSettings
    @ObservedObject var library: LinkLibrary
    let site: FavoriteSite?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var folderID: UUID?
    @State private var error: String?

    init(settings: SearchSettings, library: LinkLibrary, site: FavoriteSite? = nil,
         initialURL: URL? = nil, initialTitle: String = "") {
        self.settings = settings; self.library = library; self.site = site
        _name = State(initialValue: site?.name ?? initialTitle)
        _address = State(initialValue: site?.address ?? initialURL?.absoluteString ?? "")
        _folderID = State(initialValue: site.flatMap { library.folderID(for: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L(site == nil ? "Add bookmark" : "Edit bookmark")).font(.title2.bold())
            TextField(L("Name"), text: $name)
            TextField(L("Web address"), text: $address)
            Picker(L("Folder"), selection: $folderID) {
                Text(L("No folder")).tag(nil as UUID?)
                ForEach(library.folders) { Text($0.name).tag(Optional($0.id)) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                Button(L("Save"), action: save).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 400)
    }

    private func save() {
        do {
            let saved: FavoriteSite
            if let site { try settings.updateFavoriteSite(site, name: name, address: address); saved = site }
            else { saved = try settings.addFavoriteSite(name: name, address: address) }
            library.moveBookmark(saved, to: folderID)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct SidebarSettingsView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var library: LinkLibrary
    let show: () -> Void
    var body: some View {
        Form {
            Section {
                Toggle(L("Enable global sidebar"), isOn: Binding(get: { library.isEnabled }, set: library.setEnabled))
                Text(L("Hover at the left edge of any screen to show bookmarks and recent links. Clicking a link opens a normal Linklet preview."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Show sidebar"), action: show).disabled(!library.isEnabled)
                Text(L("Open the sidebar with ⌃⌥B or from the Linklet menu."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = library.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
            Section(L("Recent links")) {
                Toggle(L("Save history between launches"), isOn: Binding(get: { library.savesHistory }, set: library.setSavesHistory))
                Text(L("Only links opened in Linklet are listed. Page redirects and sign-in windows are excluded. Up to 200 links are kept; turning saving off removes history from disk."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Clear history"), role: .destructive, action: library.clearHistory)
                    .disabled(library.recentLinks.isEmpty)
            }
            Section(L("Bookmarks")) {
                Text(L("Bookmarks use the same saved links as Quick Search. Folders and bookmarks stay on this Mac and can be edited in the sidebar."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).toggleStyle(.switch)
    }
}

/// Wide insertion targets between rows; dropping on a folder body moves a bookmark inside.
private struct SidebarDropSlot: View {
    let accept: ([NSItemProvider]) -> Bool
    @State private var targeted = false
    var body: some View {
        Rectangle().fill(targeted ? Color.white.opacity(0.8) : Color.clear)
            .frame(height: 6).contentShape(Rectangle())
            .onDrop(of: [UTType.text], isTargeted: $targeted, perform: accept)
    }
}

/// Mirrored Slide Over contour: concave shoulders against the left edge and round outer corners.
struct SidebarContour: Shape {
    func path(in r: CGRect) -> Path {
        let radius = min(24, r.width / 2, r.height / 4)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY + radius), control: CGPoint(x: r.minX, y: r.minY + radius))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY + radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius * 2), control: CGPoint(x: r.maxX, y: r.minY + radius))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius * 2))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY - radius), control: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY - radius))
        p.closeSubpath()
        return p
    }
}

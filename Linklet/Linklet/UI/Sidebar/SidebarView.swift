import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SidebarRevealState: ObservableObject {
    @Published var progress: CGFloat = 0
    @Published var shoulderProgress: CGFloat = 0
}

/// The shoulders grow out of a stationary screen edge while the content slides underneath.
struct SidebarRevealSurface<Content: View>: View {
    @ObservedObject var reveal: SidebarRevealState
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    let appearance: SidebarAppearance
    private let reduceTransparency: Bool?
    let content: Content

    init(reveal: SidebarRevealState, appearance: SidebarAppearance = .black,
         reduceTransparency: Bool? = nil, @ViewBuilder content: () -> Content) {
        self.reveal = reveal
        self.appearance = appearance
        self.reduceTransparency = reduceTransparency
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            // Keep the moving edge on backing pixels, with a single antialiased mask.
            let width = (geometry.size.width * reveal.progress * displayScale).rounded() / displayScale
            let progress = geometry.size.width > 0 ? width / geometry.size.width : 0
            let contour = SidebarContour(revealProgress: progress, shoulderProgress: reveal.shoulderProgress)
            let glass = appearance == .glass && SidebarAppearance.supportsGlass && !(reduceTransparency ?? systemReduceTransparency)
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .offset(x: width - geometry.size.width)
                .background {
                    if glass {
                        SidebarGlassSurface(contour: contour, revealedWidth: width)
                    } else { Color.black }
                }
                .clipShape(contour)
        }
        .transaction { $0.animation = nil }
    }
}

/// Keep concave screen-edge shoulders out of the system's optical contour.
/// A continuous convex pane extends behind the screen edge, then the original
/// sidebar contour clips the result. Opaque tint cancels glass brightening on
/// the left without covering controls, which are above this entire background.
private struct SidebarGlassSurface: View {
    let contour: SidebarContour
    let revealedWidth: CGFloat

    var body: some View {
        if #available(macOS 26.0, *) {
            GeometryReader { geometry in
                let radius = min(24, geometry.size.height / 4)
                let extensionWidth: CGFloat = 48
                ZStack(alignment: .topLeading) {
                    SidebarSmokeTint(layer: .backing)
                        .frame(width: revealedWidth)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(contour)
                    SidebarNativeGlassBody(cornerRadius: radius)
                        .frame(width: revealedWidth + extensionWidth,
                               height: max(0, geometry.size.height - 2 * radius))
                        .offset(x: -extensionWidth, y: radius)
                    SidebarSmokeTint(layer: .correction)
                        .frame(width: revealedWidth)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(contour)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else { Color.black }
    }
}

/// Broad, static mesh lobes soften the tint boundary without moving the
/// background or adding grain. The left stays opaque and the far right clear.
@available(macOS 26.0, *)
private struct SidebarSmokeTint: View {
    enum Layer { case backing, correction }
    let layer: Layer

    private var points: [SIMD2<Float>] {
        let shifts: [Float] = [0, 0.006, 0.010, 0.007, -0.003, -0.005, 0]
        let heights: [Float] = [0, 0.10, 0.27, 0.51, 0.73, 0.91, 1]
        let columns: [Float] = [0, 0.50, 0.65, 0.86, 1]
        let weights: [Float] = [0, 1, 0.8, 0.4, 0]
        return shifts.enumerated().flatMap { row, shift in
            columns.enumerated().map { column, x in
                SIMD2(x + shift * weights[column], heights[row])
            }
        }
    }

    var body: some View {
        let row: [Color] = layer == .backing
            ? [.black, .black, .black.opacity(0.90), .black.opacity(0.28), .clear]
            : [.black, .black, .black.opacity(0.40), .clear, .clear]
        MeshGradient(width: 5, height: 7, points: points,
                     colors: Array(repeating: row, count: 7).flatMap { $0 },
                     smoothsColors: true)
    }
}

/// A separate hosting view confines native glass vibrancy to the material.
/// Sidebar labels and icons keep their own colors when the backdrop changes.
@available(macOS 26.0, *)
private struct SidebarNativeGlassBody: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: glass)
        host.sizingOptions = []
        return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
        host.rootView = glass
    }

    private var glass: AnyView {
        AnyView(Color.clear
            .glassEffect(.clear.tint(.black.opacity(0.28)), in: SidebarGlassBody(cornerRadius: cornerRadius))
            .environment(\.colorScheme, .dark))
    }
}

/// The right-hand quadratic corners match SidebarContour exactly. The left
/// boundary is positioned outside the visible panel and has no concave joins.
private struct SidebarGlassBody: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct SidebarPanelSurface: View {
    let model: AppModel
    @ObservedObject var library: LinkLibrary
    let reveal: SidebarRevealState
    let editor: SidebarEditorState
    let dismiss: () -> Void

    var body: some View {
        SidebarRevealSurface(reveal: reveal, appearance: library.sidebarAppearance) {
            SidebarView(model: model, dismiss: dismiss, editor: editor)
        }
    }
}

/// Read macOS's public sidebar environment instead of a separate Linklet size preference.
@MainActor
struct SidebarMetrics {
    let labelSize: CGFloat
    let iconSize: CGFloat
    var footerIconSize: CGFloat { 11 + iconSize / 4 }
    var labelFont: Font { .system(size: labelSize, weight: .semibold) }
    var groupFont: Font { .system(size: max(10, labelSize - 1), weight: .semibold) }
    var rowHeight: CGFloat { max(iconSize + 2, labelSize * 1.4) }
    var rowGap: CGFloat { 20 * labelSize / 13 }
    var iconGap: CGFloat { 8 }

    init(rowSize: SidebarRowSize) {
        switch rowSize {
        case .small: labelSize = Self.smallLabelSize; iconSize = 16
        case .medium: labelSize = Self.mediumLabelSize; iconSize = 20
        case .large: labelSize = Self.largeLabelSize; iconSize = 24
        @unknown default: labelSize = Self.mediumLabelSize; iconSize = 20
        }
    }

    // Source-list typography differs from ordinary small/regular/large control fonts.
    private static let smallLabelSize = nativeLabelSize(.small)
    private static let mediumLabelSize = nativeLabelSize(.medium)
    private static let largeLabelSize = nativeLabelSize(.large)

    private static func nativeLabelSize(_ style: NSTableView.RowSizeStyle) -> CGFloat {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let label = NSTextField(labelWithString: "")
        cell.addSubview(label)
        cell.textField = label
        cell.rowSizeStyle = style
        cell.layoutSubtreeIfNeeded()
        return label.font?.pointSize ?? NSFont.preferredFont(forTextStyle: .body, options: [:]).pointSize
    }
}

struct SidebarView: View {
    @Environment(\.sidebarRowSize) private var sidebarRowSize
    private var layout: SidebarMetrics { SidebarMetrics(rowSize: sidebarRowSize) }
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var model: AppModel
    @ObservedObject private var library: LinkLibrary
    @ObservedObject private var settings: SearchSettings
    @ObservedObject private var windows: BrowserWindowRegistry
    @ObservedObject private var downloads: DownloadManager
    let dismiss: () -> Void
    @ObservedObject var editor: SidebarEditorState

    init(model: AppModel, dismiss: @escaping () -> Void, editor: SidebarEditorState) {
        self.model = model
        self.library = model.linkLibrary
        self.settings = model.searchSettings
        self.windows = model.windowRegistry
        self.downloads = model.downloads
        self.dismiss = dismiss
        self.editor = editor
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: layout.iconGap) {
                Image("MenuBarIcon").renderingMode(.template).resizable().scaledToFit()
                    .frame(width: layout.iconSize, height: layout.iconSize)
                Text("Linklet").font(layout.labelFont)
                Spacer()
            }.padding(16)
            Divider().padding(.horizontal, SidebarLayout.inset)
            ScrollViewReader { proxy in
                ScrollView {
                    if let presentation = editor.presentation {
                        VStack(alignment: .leading, spacing: 0) {
                            switch presentation.target {
                            case let .bookmark(site, recent):
                                BookmarkEditor(settings: settings, library: library, site: site,
                                    initialURL: recent?.url, initialTitle: recent?.title ?? "",
                                    inline: true, onDismiss: editor.cancel)
                            case let .folder(folder):
                                SidebarFolderEditor(library: library, folder: folder, cancel: editor.cancel)
                            }
                        }
                        .id(presentation.id)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .padding(SidebarLayout.inset)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(library.sectionOrder) { section in sidebarSection(section) }
                        }.padding(SidebarLayout.inset)
                    }
                }.id(editor.presentation?.id)
                    .onChange(of: editor.downloadsRequest) { _ in
                        DispatchQueue.main.async { proxy.scrollTo(SidebarSection.downloads, anchor: .top) }
                    }
            }

            if library.isHistoryClearPending {
                HistoryClearConfirmation(library: library).padding(.horizontal, SidebarLayout.inset).padding(.bottom, 12)
            }
            Divider().padding(.horizontal, SidebarLayout.inset)
            HStack {
                Button { dismiss(); model.showSettings(page: .sidebar) } label: {
                    Image(systemName: "gearshape").font(.system(size: layout.footerIconSize))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.help(L("Settings…")).accessibilityLabel(L("Settings…"))
                Spacer()
                Button { dismiss(); model.toggleSearch() } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: layout.footerIconSize))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                    .help(L("Quick Search"))
            }.buttonStyle(.plain).padding(16)
        }
        .padding(.vertical, 24)
        .font(layout.labelFont)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onExitCommand {
            if editor.isEditing { editor.cancel() }
            else if library.isHistoryClearPending { library.cancelHistoryClear() }
            else { dismiss() }
        }
    }

    @State private var draggedSection: SidebarSection?

    private func sidebarSection(_ section: SidebarSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { library.toggleSection(section) } label: {
                    HStack(spacing: layout.iconGap) {
                        Image(systemName: library.expandedSections.contains(section) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                        Text(section.title)
                            .font(layout.groupFont).foregroundStyle(SidebarLayout.groupColor)
                        if section == .open, !windows.windows.isEmpty {
                            Text("\(windows.windows.count)")
                                .font(layout.groupFont).foregroundStyle(.secondary)
                        }
                        if section == .downloads, downloads.activeCount > 0 {
                            Text("\(downloads.activeCount)").font(layout.groupFont).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.frame(height: layout.rowHeight).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar-section-\(section.rawValue)")
                    .accessibilityValue(library.expandedSections.contains(section) ? L("Expanded") : L("Collapsed"))
                if section == .bookmarks {
                    Menu {
                        Button(L("Add bookmark")) { editor.showBookmark() }
                        Button(L("New folder")) { editor.showFolder() }
                    } label: { Image(systemName: "plus").font(.system(size: 12)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("Add bookmark or folder"))
                }
                if section == .downloads, downloads.items.contains(where: { !$0.isActive }) {
                    Button { downloads.clearFinished() } label: {
                        Image(systemName: "xmark").font(.system(size: 10))
                    }.buttonStyle(.plain).help(L("Clear completed downloads"))
                        .accessibilityLabel(L("Clear completed downloads"))
                }
            }
            .onDrag {
                draggedSection = section
                return NSItemProvider(object: "linklet-sidebar-section:\(section.rawValue)" as NSString)
            }
            .contextMenu {
                Button(L("Move up")) { library.moveSection(section, before: library.sectionOrder.first) }
                    .disabled(library.sectionOrder.first == section)
                Button(L("Move down")) { library.moveSection(section, before: nil) }
                    .disabled(library.sectionOrder.last == section)
            }
            if library.expandedSections.contains(section) {
                switch section {
                case .open: openContents
                case .bookmarks: bookmarkContents
                case .recent: recentContents
                case .downloads: downloadContents
                }
            }
            Divider().padding(.vertical, layout.rowGap)
        }
        // The whole section is a target, rather than only the thin header strip.
        .contentShape(Rectangle())
        .onDrop(of: [SidebarSectionDropDelegate.dragType], delegate:
            SidebarSectionDropDelegate(library: library, destination: section, draggedSection: $draggedSection))
        .id(section)
    }

    private var downloadContents: some View {
        VStack(alignment: .leading, spacing: layout.rowGap) {
            ForEach(downloads.items.reversed()) { item in
                DownloadSidebarRow(item: item, manager: downloads, layout: layout)
            }
            if downloads.items.isEmpty {
                Text(L("No downloads.")).font(layout.groupFont).foregroundStyle(.secondary)
            }
        }.padding(.top, layout.rowGap)
    }

    private var bookmarkContents: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(library.rootOrder, id: \.self) { id in
                if let folder = library.folders.first(where: { $0.id == id }) {
                    folderRow(folder)
                } else if let site = settings.favoriteSites.first(where: { $0.id == id }) {
                    bookmarkRow(site)
                }
            }
            dropSlot(before: nil, folder: nil)
            if settings.favoriteSites.isEmpty && library.folders.isEmpty {
                Text(L("Save links here or add the current page with the bookmark button."))
                    .font(layout.groupFont).foregroundStyle(.secondary)
            }
        }
    }

    private var openContents: some View {
        VStack(alignment: .leading, spacing: layout.rowGap) {
            ForEach(windows.windows) { window in
                Button {
                    dismiss()
                    windows.activate(window.id)
                } label: {
                    HStack(spacing: layout.iconGap) {
                        Group {
                            if window.isLoading {
                                ProgressView().controlSize(.small)
                            } else if let url = window.url {
                                SiteIcon(settings: settings, url: url, size: layout.iconSize)
                            } else {
                                Image(systemName: "globe")
                            }
                        }.frame(width: layout.iconSize, height: layout.iconSize)
                        Text(window.title).font(layout.labelFont).foregroundStyle(SidebarLayout.linkColor)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if window.isMiniaturized {
                            Image(systemName: "minus.rectangle").font(.system(size: 11))
                                .foregroundStyle(.secondary).accessibilityLabel(L("Minimized"))
                        } else if window.isKey {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                                .accessibilityLabel(L("Active window"))
                        }
                    }.frame(height: layout.rowHeight)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(window.url?.absoluteString ?? window.title)
                    .accessibilityIdentifier("sidebar-window-\(window.id.uuidString)")
                    .contextMenu {
                        Button(L("Close window"), role: .destructive) { windows.close(window.id) }
                    }
            }
            if windows.windows.isEmpty {
                Text(L("No open windows.")).font(layout.groupFont).foregroundStyle(.secondary)
                    .accessibilityIdentifier("sidebar-open-empty")
            }
        }.padding(.top, layout.rowGap)
    }

    private var recentContents: some View {
        VStack(alignment: .leading, spacing: layout.rowGap) {
            ForEach(library.visibleRecentLinks) { link in
                Button { if let url = link.url { open(url) } } label: {
                    linkLabel(title: link.title, address: link.address)
                }.buttonStyle(.plain)
                .contextMenu {
                    Button(L("Add bookmark")) { editor.showBookmark(recent: link) }
                    Button(L("Remove"), role: .destructive) { library.removeRecent(link) }
                }
            }
            if library.recentLinks.isEmpty {
                Text(L("No recent links.")).font(layout.groupFont).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    if library.hasMoreRecentLinks { Button(L("Show more"), action: library.showMoreRecentLinks) }
                    Button(L("Clear history"), action: library.requestHistoryClear)
                }.font(layout.groupFont).buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 8)
            }
        }.padding(.top, layout.rowGap)
    }

    private func open(_ url: URL) { dismiss(); model.showPreview(url: url) }

    @State private var targetedDrop: UUID?

    private func folderRow(_ folder: BookmarkFolder) -> some View {
        let sites = settings.favoriteSites.filter { library.folderID(for: $0) == folder.id }
        let expanded = library.expandedFolderIDs.contains(folder.id)
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                dropSlot(before: folder.id, folder: nil)
                Button {
                    if expanded { library.expandedFolderIDs.remove(folder.id) }
                    else { library.expandedFolderIDs.insert(folder.id) }
                } label: {
                    HStack(spacing: layout.iconGap) {
                        Image(systemName: expanded ? "folder.fill" : "folder").font(.system(size: layout.iconSize))
                            .frame(width: layout.iconSize, height: layout.iconSize).foregroundStyle(SidebarLayout.linkColor)
                        Text(folder.name).font(layout.labelFont).foregroundStyle(SidebarLayout.linkColor).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }.frame(height: layout.rowHeight).contentShape(Rectangle())
                }.buttonStyle(.plain)
                .background(targetedDrop == folder.id ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .onDrag { draggedSection = nil; return NSItemProvider(object: folder.id.uuidString as NSString) }
                .onDrop(of: [UTType.text], isTargeted: Binding(get: { targetedDrop == folder.id }, set: { targetedDrop = $0 ? folder.id : nil })) {
                    acceptDrop($0, before: nil, folder: folder.id)
                }
                .contextMenu {
                    Button(L("Rename folder")) { editor.showFolder(folder) }
                    Button(L("Move up")) { library.moveItem(folder.id, offset: -1) }
                    Button(L("Move down")) { library.moveItem(folder.id, offset: 1) }
                    Button(L("Remove folder; keep bookmarks"), role: .destructive) { library.removeFolder(folder) }
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sites) { bookmarkRow($0) }
                        dropSlot(before: nil, folder: folder.id).padding(.bottom, -layout.rowGap)
                        if sites.isEmpty { Text(L("Empty folder")).font(layout.groupFont).foregroundStyle(.secondary).padding(.vertical, 6) }
                    }.padding(.leading, 20)
                }
            }
        }
    }

    private func dropSlot(before id: UUID?, folder: UUID?) -> some View {
        SidebarDropSlot(height: layout.rowGap) { providers in acceptDrop(providers, before: id, folder: folder) }
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
                Button(L("Edit")) { editor.showBookmark(site: site) }
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
            .onDrag { draggedSection = nil; return NSItemProvider(object: site.id.uuidString as NSString) }
        }
    }

    private func linkLabel(title: String, address: String) -> some View {
        HStack(spacing: layout.iconGap) {
            if let url = URL(string: address) { SiteIcon(settings: settings, url: url, size: layout.iconSize) }
            Text(title).font(layout.labelFont).foregroundStyle(SidebarLayout.linkColor).lineLimit(1)
            Spacer(minLength: 0)
        }.frame(height: layout.rowHeight).contentShape(Rectangle()).help(address)
    }
}

private struct DownloadSidebarRow: View {
    @ObservedObject var item: DownloadItem
    @ObservedObject var manager: DownloadManager
    let layout: SidebarMetrics

    private var symbol: String {
        switch item.state {
        case .choosing, .downloading: return "arrow.down.circle"
        case .finishing, .finished: return "doc"
        case .cancelled: return "xmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        HStack(spacing: layout.iconGap) {
            Button { manager.reveal(item) } label: {
                HStack(spacing: layout.iconGap) {
                    Image(systemName: symbol).font(.system(size: layout.iconSize * 0.8))
                        .foregroundStyle(item.state == .failed ? Color.orange : Color.secondary)
                        .frame(width: layout.iconSize, height: layout.iconSize)
                    Text(item.filename).font(layout.labelFont).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(item.state != .finished)
                .accessibilityLabel("\(item.filename), \(item.status)")
            if item.canCancel {
                Button { manager.cancel(item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 20, height: 20)
                }.buttonStyle(.plain).help(L("Cancel download")).accessibilityLabel(L("Cancel download"))
            }
        }
        .frame(height: layout.rowHeight)
        .overlay(alignment: .bottom) {
            if item.state == .downloading || item.state == .finishing {
                Group {
                    if let fraction = item.fraction { ProgressView(value: fraction).progressViewStyle(.linear) }
                    else { ProgressView().progressViewStyle(.linear) }
                }.frame(height: 2).allowsHitTesting(false)
            }
        }
        .help("\(item.filename)\n\(item.status)")
        .accessibilityIdentifier("sidebar-download-\(item.id.uuidString)")
        .contextMenu {
            Text(item.status).disabled(true)
            if item.state == .finished { Button(L("Show in Finder")) { manager.reveal(item) } }
            if item.canCancel { Button(L("Cancel download")) { manager.cancel(item.id) } }
        }
    }
}

struct SidebarEditorPresentation: Identifiable {
    enum Target {
        case bookmark(FavoriteSite?, RecentLink?)
        case folder(BookmarkFolder?)
    }
    let id = UUID()
    let target: Target
}

@MainActor
final class SidebarEditorState: ObservableObject {
    @Published var downloadsRequest = 0
    @Published private(set) var presentation: SidebarEditorPresentation?
    var isEditing: Bool { presentation != nil }
    func showBookmark(site: FavoriteSite? = nil, recent: RecentLink? = nil) {
        presentation = SidebarEditorPresentation(target: .bookmark(site, recent))
    }
    func showFolder(_ folder: BookmarkFolder? = nil) {
        presentation = SidebarEditorPresentation(target: .folder(folder))
    }
    func cancel() { presentation = nil }
}

private struct SidebarFolderEditor: View {
    @Environment(\.sidebarRowSize) private var rowSize
    @ObservedObject private var language = AppLanguage.shared
    let library: LinkLibrary
    let folder: BookmarkFolder?
    let cancel: () -> Void
    @State private var name: String
    @FocusState private var nameIsFocused: Bool

    init(library: LinkLibrary, folder: BookmarkFolder?, cancel: @escaping () -> Void) {
        self.library = library; self.folder = folder; self.cancel = cancel
        _name = State(initialValue: folder?.name ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(folder == nil ? "New folder" : "Rename folder")).font(SidebarMetrics(rowSize: rowSize).labelFont)
            Text(L("Name")).font(SidebarMetrics(rowSize: rowSize).groupFont).foregroundStyle(.secondary)
            TextField(L("Name"), text: $name).textFieldStyle(.roundedBorder).focused($nameIsFocused)
                .onSubmit(save)
            VStack(spacing: 8) {
                Button(action: save) { Text(L("Save")).frame(maxWidth: .infinity) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(role: .cancel, action: cancel) { Text(L("Cancel")).frame(maxWidth: .infinity) }
            }.buttonStyle(.bordered)

        }.frame(maxWidth: .infinity, alignment: .leading).onAppear { nameIsFocused = true }
    }
    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let folder { library.renameFolder(folder, name: name) }
        else { library.addFolder(name: name) }
        cancel()
    }
}

private enum SidebarLayout {
    static let inset: CGFloat = 16
    static let groupColor = Color(red: 141 / 255, green: 141 / 255, blue: 141 / 255)
    static let linkColor = Color.white
}

/// Native sibling of the hosting view: SwiftUI hit testing cannot cover this edge.
final class SidebarResizeView: NSView {
    var start: (() -> Void)?
    var resize: ((CGFloat) -> Void)?
    var finish: (() -> Void)?
    private var initialWidth: CGFloat = 0
    private var initialX: CGFloat = 0
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .cursorUpdate], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialWidth = window.frame.width
        initialX = window.convertPoint(toScreen: event.locationInWindow).x
        start?()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        resize?(initialWidth + window.convertPoint(toScreen: event.locationInWindow).x - initialX)
    }
    override func mouseUp(with event: NSEvent) { finish?() }
}

struct BookmarkEditor: View {
    @Environment(\.sidebarRowSize) private var rowSize
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var settings: SearchSettings
    @ObservedObject var library: LinkLibrary
    let site: FavoriteSite?
    private let inline: Bool
    private let onDismiss: (() -> Void)?
    @FocusState private var nameIsFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var folderID: UUID?
    @State private var error: String?

    init(settings: SearchSettings, library: LinkLibrary, site: FavoriteSite? = nil,
         initialURL: URL? = nil, initialTitle: String = "", inline: Bool = false, onDismiss: (() -> Void)? = nil) {
        self.settings = settings; self.library = library; self.site = site
        self.inline = inline; self.onDismiss = onDismiss
        _name = State(initialValue: site?.name ?? initialTitle)
        _address = State(initialValue: site?.address ?? initialURL?.absoluteString ?? "")
        _folderID = State(initialValue: site.flatMap { library.folderID(for: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: inline ? 12 : 16) {
            Text(L(site == nil ? "Add bookmark" : "Edit bookmark"))
                .font(inline ? SidebarMetrics(rowSize: rowSize).labelFont : .title2.bold())
            if inline { Text(L("Name")).font(inline ? SidebarMetrics(rowSize: rowSize).groupFont : .caption).foregroundStyle(.secondary) }
            TextField(L("Name"), text: $name).focused($nameIsFocused)
            if inline { Text(L("Web address")).font(inline ? SidebarMetrics(rowSize: rowSize).groupFont : .caption).foregroundStyle(.secondary) }
            TextField(L("Web address"), text: $address)
            if inline {
                Text(L("Folder")).font(inline ? SidebarMetrics(rowSize: rowSize).groupFont : .caption).foregroundStyle(.secondary)
                folderPicker.labelsHidden().frame(maxWidth: .infinity)
            } else { folderPicker }
            if let error { Text(error).font(inline ? SidebarMetrics(rowSize: rowSize).groupFont : .caption).foregroundStyle(.red) }
            if inline {
                VStack(spacing: 8) {
                    Button(action: save) { Text(L("Save")).frame(maxWidth: .infinity) }
                        .keyboardShortcut(.defaultAction)
                    Button(role: .cancel, action: finish) { Text(L("Cancel")).frame(maxWidth: .infinity) }
                }.buttonStyle(.bordered)
            } else {
                HStack {
                    Spacer()
                    Button(L("Cancel"), role: .cancel, action: finish)
                    Button(L("Save"), action: save).keyboardShortcut(.defaultAction)
                }
            }

        }.textFieldStyle(.roundedBorder)
            .padding(inline ? 0 : 20).frame(width: inline ? nil : 400)
            .frame(maxWidth: inline ? .infinity : nil, alignment: .leading)
            .onAppear { nameIsFocused = true }
    }

    private var folderPicker: some View {
        Picker(L("Folder"), selection: $folderID) {
            Text(L("No folder")).tag(nil as UUID?)
            ForEach(library.folders) { Text($0.name).tag(Optional($0.id)) }
        }
    }

    private func finish() { if let onDismiss { onDismiss() } else { dismiss() } }

    private func save() {
        do {
            let saved: FavoriteSite
            if let site { try settings.updateFavoriteSite(site, name: name, address: address); saved = site }
            else { saved = try settings.addFavoriteSite(name: name, address: address) }
            library.moveBookmark(saved, to: folderID)
            finish()
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
                Text(L("Hover at the left edge of any screen to see open windows, bookmarks and recent links. Select an open window to return to it, or a saved link to open a preview."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("Show sidebar reveal indicator"), isOn: Binding(get: { library.showsRevealIndicator }, set: library.setShowsRevealIndicator))
                    .disabled(!library.isEnabled)
                if !library.showsRevealIndicator {
                    HStack {
                        Text(L("Delay before opening"))
                        Slider(value: Binding(get: { library.edgeOpenDelay }, set: library.setEdgeOpenDelay), in: 0.1...2, step: 0.1)
                        Text(String(format: "%.1f s", library.edgeOpenDelay)).monospacedDigit().frame(width: 48)
                    }.disabled(!library.isEnabled)
                }
                Button(L("Show sidebar"), action: show).disabled(!library.isEnabled)
                Text(L("Open the sidebar with ⌃⌥B or from the Linklet menu."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = library.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
            Section(L("Sidebar appearance")) {
                if SidebarAppearance.supportsGlass {
                    Picker(L("Appearance"), selection: Binding(get: { library.sidebarAppearance }, set: { appearance in
                        // AppKit's segmented picker can send its action while another
                        // hosting view is updating. Publish to both hosts next turn.
                        DispatchQueue.main.async { library.setSidebarAppearance(appearance) }
                    })) {
                        ForEach(SidebarAppearance.allCases) { appearance in Text(appearance.title).tag(appearance) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("sidebar-appearance-picker")
                    Text(L("Test appearance: a full Liquid Glass panel, tinted black on the left and transparent on the right. The sidebar shape and row sizes stay the same."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L("Reduce Transparency uses the black appearance."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("Liquid Glass requires macOS 26 or later. The black appearance is used on this Mac."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Recent links")) {
                Toggle(L("Save history between launches"), isOn: Binding(get: { library.savesHistory }, set: library.setSavesHistory))
                Text(L("Only links opened in Linklet are listed. Page redirects and sign-in windows are excluded. Up to 200 links are kept; turning saving off removes history from disk."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Clear history"), action: library.requestHistoryClear)
                    .disabled(library.recentLinks.isEmpty)
                if library.isHistoryClearPending { HistoryClearConfirmation(library: library) }
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
    let height: CGFloat
    let accept: ([NSItemProvider]) -> Bool
    @State private var targeted = false
    var body: some View {
        SidebarInsertionGap(height: height, targeted: targeted)
            .onDrop(of: [UTType.text], isTargeted: $targeted, perform: accept)
    }
}

struct SidebarInsertionGap: View {
    let height: CGFloat
    let targeted: Bool
    var body: some View {
        Color.clear.frame(height: height)
            .overlay {
                if targeted { SidebarInsertionIndicator().frame(height: 1) }
            }
            .contentShape(Rectangle())
    }
}

/// A paper-like perforation centered inside the full gap, without reducing the drop target.
struct SidebarInsertionIndicator: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
            }.stroke(Color(white: 0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Mirrored Slide Over contour: concave shoulders against the left edge and round outer corners.
struct SidebarContour: Shape {
    var revealProgress: CGFloat = 1
    var shoulderProgress: CGFloat = 1

    func path(in r: CGRect) -> Path {
        let width = r.width * min(1, max(0, revealProgress))
        guard width > 0 else { return Path() }
        let radius = min(24, r.height / 4)
        // Keep the right corners intact as the body is cropped against the screen edge.
        // Fillets only grow into the straight top/bottom edge, never across a right corner.
        let shoulderExtent = radius * min(1, max(0, shoulderProgress)) * min(1, max(0, (width - radius) / radius))
        let shoulderReach = min(shoulderExtent, max(0, width - radius))
        let outerRadius = radius
        let right = r.minX + width
        if width < radius {
            // Trim the original quadratic curves analytically (de Casteljau), preserving
            // their radius instead of flattening a tiny shape through a path intersection.
            let t = 1 - sqrt(width / radius)
            let top = r.minY + radius
            let bottom = r.maxY - radius
            var clipped = Path()
            clipped.move(to: CGPoint(x: r.minX, y: top + radius * t * t))
            clipped.addQuadCurve(to: CGPoint(x: right, y: top + radius), control: CGPoint(x: right, y: top + radius * t))
            clipped.addLine(to: CGPoint(x: right, y: bottom - radius))
            clipped.addQuadCurve(to: CGPoint(x: r.minX, y: bottom - radius * t * t), control: CGPoint(x: right, y: bottom - radius * t))
            clipped.closeSubpath()
            return clipped
        }
        let left = r.minX
        var p = Path()
        p.move(to: CGPoint(x: left, y: r.minY + radius - shoulderExtent))
        p.addQuadCurve(to: CGPoint(x: left + shoulderReach, y: r.minY + radius), control: CGPoint(x: left, y: r.minY + radius))
        p.addLine(to: CGPoint(x: right - outerRadius, y: r.minY + radius))
        p.addQuadCurve(to: CGPoint(x: right, y: r.minY + radius + outerRadius), control: CGPoint(x: right, y: r.minY + radius))
        p.addLine(to: CGPoint(x: right, y: r.maxY - radius - outerRadius))
        p.addQuadCurve(to: CGPoint(x: right - outerRadius, y: r.maxY - radius), control: CGPoint(x: right, y: r.maxY - radius))
        p.addLine(to: CGPoint(x: left + shoulderReach, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: left, y: r.maxY - radius + shoulderExtent), control: CGPoint(x: left, y: r.maxY - radius))
        p.closeSubpath()
        return p
    }
}

struct HistoryClearConfirmation: View {
    @ObservedObject var library: LinkLibrary
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Clear all recent links?"), systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
            Text(L("This cannot be undone.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Cancel"), action: library.cancelHistoryClear)
                Spacer()
                Button(L("Clear history"), role: .destructive, action: library.confirmHistoryClear)
            }.buttonStyle(.bordered).controlSize(.small)
        }.padding(12).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

struct SidebarSectionDropDelegate: DropDelegate {
    static let dragType = UTType.text
    let library: LinkLibrary
    let destination: SidebarSection
    @Binding var draggedSection: SidebarSection?

    func validateDrop(info: DropInfo) -> Bool {
        draggedSection != nil && info.hasItemsConforming(to: [Self.dragType])
    }
    func dropEntered(info: DropInfo) {
        guard let source = draggedSection, source != destination else { return }
        library.reorderSection(source, onto: destination)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard draggedSection != nil else { return false }
        draggedSection = nil
        return true
    }
}

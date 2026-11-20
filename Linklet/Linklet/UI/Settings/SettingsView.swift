import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, windows, search, sites, about
    var id: String { rawValue }
    static func restoring(_ value: String?) -> Self {
        switch value {
        case "sidebar": return .windows
        case "browsers": return .search
        default: return value.flatMap(Self.init(rawValue:)) ?? .general
        }
    }
    var title: String {
        switch self {
        case .general: return L("General")
        case .windows: return L("Windows & Sidebar")
        case .search: return L("Search & Browsers")
        case .sites: return L("Privacy")
        case .about: return L("About Linklet")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .windows: return "macwindow.on.rectangle"
        case .search: return "magnifyingglass"
        case .sites: return "hand.raised.fill"
        case .about: return "info.circle"
        }
    }
}

/// Kept as a SwiftUI entry point for previews and embedded settings tests.
struct SettingsView: NSViewControllerRepresentable {
    let model: AppModel
    func makeNSViewController(context: Context) -> SettingsSplitViewController {
        SettingsSplitViewController(model: model)
    }
    func updateNSViewController(_ controller: SettingsSplitViewController, context: Context) {}
}

enum SettingsDesignMetrics {
    static let formInset: CGFloat = 24
    static let formWidth: CGFloat = 760
    static let labelSpacing: CGFloat = 4
    static let sidebarWidth: CGFloat = 216
}

struct SettingsNavigationMetrics {
    let rowHeight: CGFloat
    let iconSize: CGFloat
    let labelSize: CGFloat
    init(_ size: SidebarRowSize) {
        switch size {
        case .small: rowHeight = 29; iconSize = 18; labelSize = 12
        case .large: rowHeight = 42; iconSize = 26; labelSize = 15
        default: rowHeight = 36; iconSize = 22; labelSize = 13
        }
    }
}

struct SettingsSidebarView: View {
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sidebarRowSize) private var rowSize
    @State private var hoveredPage: SettingsPage?
    @FocusState private var focusedPage: SettingsPage?
    @ObservedObject var model: AppModel
    private var metrics: SettingsNavigationMetrics { SettingsNavigationMetrics(rowSize) }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(SettingsPage.allCases) { navigationRow($0) }
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(sidebarBackground.ignoresSafeArea())
        .environment(\.locale, Locale(identifier: language.code))
    }

    private func navigationRow(_ page: SettingsPage) -> some View {
        let isSelected = model.settingsPage == page
        return Button {
            model.settingsPage = page
        } label: {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(.system(size: metrics.iconSize * 0.61, weight: .medium))
                    .foregroundStyle(isSelected ? .white : iconColor)
                    .frame(width: metrics.iconSize, height: metrics.iconSize)
                    .background((isSelected ? Color.white : iconColor).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                Text(page.title)
                    .font(.system(size: metrics.labelSize, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : labelColor)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: metrics.rowHeight, alignment: .leading)
            .background(selectionColor(for: page), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .focused($focusedPage, equals: page)
        .onMoveCommand { moveSelection(from: page, $0) }
        .onHover { hoveredPage = $0 ? page : nil }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings-page-\(page.rawValue)")
    }

    private func moveSelection(from page: SettingsPage, _ direction: MoveCommandDirection) {
        let pages = SettingsPage.allCases
        guard let index = pages.firstIndex(of: page), direction == .up || direction == .down else { return }
        let next = index + (direction == .up ? -1 : 1)
        guard pages.indices.contains(next) else { return }
        model.settingsPage = pages[next]
        focusedPage = pages[next]
    }

    private func selectionColor(for page: SettingsPage) -> Color {
        if model.settingsPage == page { return Color(red: 0.105, green: 0.35, blue: 0.77) }
        if hoveredPage == page { return labelColor.opacity(0.07) }
        return .clear
    }

    private var labelColor: Color { colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.16) }
    private var iconColor: Color {
        colorScheme == .dark ? Color(red: 0.73, green: 0.78, blue: 0.86) : Color(red: 0.27, green: 0.33, blue: 0.43)
    }
    private var sidebarBackground: Color {
        colorScheme == .dark ? Color(white: 0.139) : Color(red: 0.92, green: 0.93, blue: 0.95)
    }
}

struct SettingsDetailView: View {
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: model.settingsPage.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text(model.settingsPage.title)
                    .font(.system(size: 25, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("settings-page-heading")
            }
            .frame(maxWidth: SettingsDesignMetrics.formWidth, alignment: .leading)
            .padding(.horizontal, SettingsDesignMetrics.formInset)
            .padding(.top, 10)
            .padding(.bottom, 16)

            Group {
                switch model.settingsPage {
                case .general: general
                case .windows: windows
                case .search: SearchSettingsView(settings: model.searchSettings, showSearch: model.openQuickSearch, browserModel: model)
                case .sites: SiteDataSettingsView(model: model, data: model.siteData)
                case .about: AboutSettingsView(model: model, updates: model.appUpdates)
                }
            }
            .id(model.settingsPage)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let message = model.statusMessage {
                Divider()
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colorScheme == .dark ? Color(white: 0.096) : Color(red: 0.963, green: 0.969, blue: 0.977))
        .environment(\.locale, Locale(identifier: language.code))
    }

    private var general: some View {
        SettingsContent {
            SettingsGroup(L("Opening Links")) { DefaultBrowserSetting(model: model) }
            SettingsGroup(L("Application")) {
                SettingsToggle(L("Launch at login"), isOn: Binding(
                    get: { model.isLaunchAtLoginEnabled }, set: model.setLaunchAtLogin))
                SettingsPicker(L("Language"), selection: Binding(get: { language.selection }, set: model.setLanguage)) {
                    Text(L("Same as macOS")).tag("system")
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
            }
            SettingsGroup(L("Getting Started")) {
                SettingsNavigationLink(L("How to Use Linklet"),
                                       detail: L("Opening links, search, and the sidebar."), action: model.showWelcome)
            }
        }
    }

    private var windows: some View {
        SettingsContent {
            SettingsGroup(L("Windows")) {
                SettingsLabel(L("Window mode"), detail: L(model.opensLinksInNewWindows
                    ? "Each new link opens in a separate window."
                    : "New links replace the page in a single window.")) {
                    Picker(L("Window mode"), selection: Binding(
                        get: { model.opensLinksInNewWindows }, set: model.setOpensLinksInNewWindows)) {
                        Text(L("Single window")).tag(false)
                        Text(L("Multiple windows")).tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().id(language.code)
                    .fixedSize()
                }
                VStack(alignment: .leading, spacing: 9) {
                    SettingsText(L("Window behavior"), detail: L("When switching between apps."))
                    Picker(L("Window behavior"), selection: Binding(
                        get: { model.previewWindowBehavior }, set: model.setPreviewWindowBehavior)) {
                        ForEach(PreviewWindowBehavior.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().id(language.code)
                    .accessibilityIdentifier("settings-window-behavior")
                }
            }
            SidebarSettingsSections(library: model.linkLibrary, show: model.showSidebar)
        }
    }
}

struct SettingsContent<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) { content }
                .frame(maxWidth: SettingsDesignMetrics.formWidth)
                .padding(.horizontal, SettingsDesignMetrics.formInset)
                .padding(.top, 2)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
        }
    }
}

struct SettingsGroup<Rows: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String?
    let note: String?
    let rows: Rows

    init(_ title: String? = nil, note: String? = nil, @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.note = note
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                if #available(macOS 15.0, *) {
                    Group(subviews: rows) { subviews in
                        ForEach(subviews) { row in
                            if row.id != subviews.first?.id {
                                Rectangle().fill(.primary.opacity(0.075)).frame(height: 1)
                                    .padding(.horizontal, 14).accessibilityHidden(true)
                            }
                            row.modifier(SettingsRowInsets())
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) { rows }
                        .modifier(SettingsRowInsets())
                }
            }
            .background(colorScheme == .dark ? Color(white: 0.143) : .white,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }
}

private struct SettingsRowInsets: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct SettingsText: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsDesignMetrics.labelSpacing) {
            Text(title)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsLabel<Accessory: View>: View {
    let title: String
    let detail: String?
    let accessory: Accessory

    init(_ title: String, detail: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 14) {
            SettingsText(title, detail: detail)
            Spacer(minLength: 0)
            accessory.layoutPriority(1)
        }
    }
}

struct SettingsToggle: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        SettingsLabel(title, detail: detail) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

struct SettingsPicker<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    let options: Options

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.title = title
        _selection = selection
        self.options = options()
    }

    var body: some View {
        SettingsLabel(title) {
            Picker(title, selection: $selection) { options }
                .pickerStyle(.menu).labelsHidden()
                .accessibilityLabel(title)
                .frame(maxWidth: 220, alignment: .trailing)
        }
    }
}

private struct SettingsNavigationLink: View {
    let title: String
    let detail: String
    let action: () -> Void

    init(_ title: String, detail: String, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingsLabel(title, detail: detail) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DefaultBrowserSetting: View {
    @ObservedObject var model: AppModel
    var body: some View {
        SettingsLabel(L("Default browser"), detail: L(model.isDefaultBrowser
            ? "Links open in Linklet." : "Optional. Opens links from other apps in Linklet.")) {
            if model.isDefaultBrowser {
                Label(L("Default"), systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else {
                Button(L("Make Default…"), action: model.makeDefaultBrowser)
            }
        }
    }
}

private struct AdBlockSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var blocker: AdBlockService
    @State private var showingAddSite = false
    @State private var address = ""
    @State private var invalidAddress = false

    var body: some View {
        SettingsGroup(L("Ad Blocking")) {
            SettingsToggle(L("Block ads"), detail: L("AdGuard filter lists"),
                           isOn: Binding(get: { blocker.isEnabled }, set: model.setAdBlockingEnabled))
            DisclosureGroup(L("Exceptions (%d)", blocker.siteOverrides.count)) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(blocker.siteOverrides.keys.sorted(), id: \.self) { host in
                        HStack {
                            SettingsToggle(host, isOn: Binding(get: { blocker.siteOverrides[host] ?? blocker.isEnabled }, set: { enabled in
                                blocker.setSiteEnabled(enabled, host: host); reload(host: host)
                            }))
                            Button { blocker.removeSiteOverride(host); reload(host: host) } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless)
                                .accessibilityLabel(L("Remove exception"))
                        }
                    }
                    Button(L("Add website…"), systemImage: "plus") {
                        address = ""; invalidAddress = false; showingAddSite = true
                    }
                }
                .padding(.top, 10)
            }
            if let error = blocker.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .sheet(isPresented: $showingAddSite) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("Add website")).font(.headline)
                TextField(L("Website address"), text: $address, prompt: Text("example.com"))
                    .onSubmit(addSite)
                Text(L("AdGuard will be turned off for this domain.")).font(.callout).foregroundStyle(.secondary)
                if invalidAddress { Text(L("Enter an HTTP(S) address or domain.")).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button(L("Cancel")) { showingAddSite = false }.keyboardShortcut(.cancelAction)
                    Button(L("Add"), action: addSite).keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 380)
        }
    }

    private func addSite() {
        guard let host = AdBlockService.siteHost(address), blocker.setSiteEnabled(false, host: host) else {
            invalidAddress = true; return
        }
        showingAddSite = false
        reload(host: host)
    }

    private func reload(host: String) {
        Task { @MainActor in
            await blocker.waitForPolicyUpdate()
            guard blocker.errorMessage == nil else { return }
            for session in model.windowRegistry.activeSessions {
                if let url = session.webView?.url, AdBlockService.siteHost(url.absoluteString) == host { session.reload() }
            }
        }
    }
}

struct BrowserSettingsSections: View {
    @ObservedObject var model: AppModel
    @State private var draggedID: String?
    @State private var dropTargetID: String?

    var body: some View {
        SettingsGroup(L("Opening in Another Browser"),
                      note: L("The arrow beside the page address opens the browser menu. The selected browser appears first and opens the original link with ⌘1.")) {
            SettingsToggle(L("Show Open in browser button"), isOn: Binding(
                get: { model.showsOpenInButton }, set: model.setShowsOpenInButton))
                .accessibilityIdentifier("settings-show-open-in-button")
            SettingsPicker(L("Open browser list"), selection: Binding(
                get: { model.opensBrowserMenuOnHover }, set: model.setOpensBrowserMenuOnHover)) {
                Text(L("On click")).tag(false)
                Text(L("On hover")).tag(true)
            }.accessibilityIdentifier("settings-browser-menu-trigger")
            if !model.visibleTargets.isEmpty {
                SettingsPicker(L("Browser for sending links"), selection: Binding(
                    get: { model.preferredTarget?.id ?? "" }, set: model.setPreferredTarget)) {
                    ForEach(model.visibleTargets) { Text($0.displayName).tag($0.id) }
                }
            }
        }
        SettingsGroup(L("Browsers in the Open in menu")) {
            if model.targets.isEmpty {
                Text(L("No compatible browsers or Orion profile apps were found.")).foregroundStyle(.secondary)
            }
            ForEach(model.orderedTargets) { target in
                row(target)
                    .background {
                        if dropTargetID == target.id {
                            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.14))
                        }
                    }
                    .onDrag { draggedID = target.id; return NSItemProvider(object: target.id as NSString) }
                    .onDrop(of: [UTType.text], delegate: BrowserOrderDropDelegate(
                        destination: target.id, model: model, draggedID: $draggedID, dropTargetID: $dropTargetID))
            }
            HStack {
                Button(L("Refresh")) { Task { await model.refreshTargetsForSettings() } }
                    .disabled(model.isRefreshingTargets)
                if model.isRefreshingTargets { ProgressView().controlSize(.small) }
            }
        }
        SettingsGroup(L("Browser order"), note: L("Drag browsers to reorder when automatic sorting is off.")) {
            SettingsToggle(L("Sort browsers by usage"), isOn: Binding(get: { model.sortsTargetsByUsage }, set: model.setSortTargetsByUsage))
            Button(L("Reset usage"), action: model.resetTargetUsage)
                .disabled(model.targets.allSatisfy { model.targetUsageCount($0) == 0 })
        }
    }

    private func row(_ target: BrowserTarget) -> some View {
        HStack(spacing: 10) {
            Toggle(L("Show %@", target.displayName), isOn: Binding(
                get: { model.isTargetVisible(target) },
                set: { model.setTargetVisible(target, isVisible: $0) }))
                .labelsHidden().toggleStyle(.checkbox)
            Image(nsImage: TargetIconCache.shared.icon(for: target.applicationURL))
                .resizable().scaledToFit().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(target.displayName)
                    if model.preferredTarget?.id == target.id {
                        Text(L("Primary")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(L("Opened through Linklet: %d", model.targetUsageCount(target)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.sortsTargetsByUsage {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            if !model.sortsTargetsByUsage {
                Button(L("Move up")) { model.moveTarget(target.id, offset: -1) }
                    .disabled(model.manuallyOrderedTargets.first?.id == target.id)
                Button(L("Move down")) { model.moveTarget(target.id, offset: 1) }
                    .disabled(model.manuallyOrderedTargets.last?.id == target.id)
            }
        }
        .accessibilityAction(named: Text(L("Move up"))) { model.moveTarget(target.id, offset: -1) }
        .accessibilityAction(named: Text(L("Move down"))) { model.moveTarget(target.id, offset: 1) }
    }
}

private struct BrowserOrderDropDelegate: DropDelegate {
    let destination: String?
    let model: AppModel
    @Binding var draggedID: String?
    @Binding var dropTargetID: String?
    func dropEntered(info: DropInfo) { if draggedID != nil { dropTargetID = destination ?? "end" } }
    func dropExited(info: DropInfo) { if dropTargetID == destination ?? "end" { dropTargetID = nil } }
    func validateDrop(info: DropInfo) -> Bool { draggedID != nil && !model.sortsTargetsByUsage }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard let id = draggedID, !model.sortsTargetsByUsage else { return false }
        model.moveTarget(id, before: destination)
        draggedID = nil
        dropTargetID = nil
        return true
    }
}

struct SiteDataSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var data: SiteDataService
    @State private var showsWebsiteData = false

    var body: some View {
        if showsWebsiteData {
            WebsiteDataSettingsView(model: model, data: data, close: { showsWebsiteData = false })
        } else {
            SettingsContent {
                SettingsGroup {
                    SettingsNavigationLink(L("Website Data"), detail: L(data.isEnabled ? "Website data is saved." : "Website data is temporary.")) {
                        showsWebsiteData = true
                    }.accessibilityIdentifier("settings-website-data")
                }
                HistorySettingsSection(library: model.linkLibrary)
                AdBlockSettingsView(model: model, blocker: model.adBlockService)
                SiteMediaPermissionsSettings(permissions: data.mediaPermissions)
            }
        }
    }
}

/// A separate, lazy list: opening Privacy never fetches or lays out stored sites.
struct WebsiteDataSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var data: SiteDataService
    let close: () -> Void
    @State private var search = ""
    @State private var confirmation: DataDeletion?
    @State private var isMutating = false

    private enum DataDeletion: Identifiable {
        case disable, all, site(WKWebsiteDataRecord)
        var id: String {
            switch self { case .disable: return "disable"; case .all: return "all"; case .site(let record): return record.displayName }
        }
        var title: String {
            switch self {
            case .disable: return L("Turn off saving and delete website data?")
            case .all: return L("Delete all website data?")
            case .site(let record): return L("Delete data for %@?", record.displayName)
            }
        }
    }
    private var filtered: [WKWebsiteDataRecord] {
        data.records.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
    }
    private var isBusy: Bool { data.isBusy || isMutating }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button(L("Back"), systemImage: "chevron.left", action: close)
                Text(L("Website Data")).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
            }
            SettingsGroup(L("Storage"), note: L(data.isEnabled
                ? "Website data is stored on this Mac. Turning this off deletes saved website data."
                : "Without saving, website data is deleted when all related windows close. Hiding the window when switching apps also ends the preview.")) {
                SettingsToggle(L("Save website data"), detail: L("Stay signed in and keep website preferences."),
                               isOn: Binding(get: { data.isEnabled }, set: { enabled in
                    if !enabled { confirmation = .disable }
                    else { setSavingEnabled() }
                })).disabled(isBusy)
                if data.isEnabled {
                    SettingsPicker(L("Automatically clear data"), selection: Binding(get: { data.inactiveDays }, set: data.setInactiveDays)) {
                        Text(L("Never")).tag(0)
                        ForEach([7, 30, 90], id: \.self) { Text(L("%d days", $0)).tag($0) }
                    }.disabled(isBusy)
                }
            }
            HStack(spacing: 8) {
                Text(L("Stored websites")).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if data.isBusy { ProgressView().controlSize(.small).accessibilityLabel(L("Updating website data…")) }
                TextField(L("Search websites"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 156)
                Button(L("Refresh")) { Task { await data.refresh() } }.disabled(isBusy)
            }
            List {
                if filtered.isEmpty && !data.isBusy {
                    Text(L(search.isEmpty ? "No stored website data." : "No matching websites."))
                        .foregroundStyle(.secondary).padding(.vertical, 12)
                }
                ForEach(filtered, id: \.displayName) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: SettingsDesignMetrics.labelSpacing) {
                            Text(record.displayName).textSelection(.enabled)
                            Text(types(for: record)).font(.caption).foregroundStyle(.secondary)
                            if let visit = data.lastVisit(for: record.displayName) {
                                Text(L("Last visited: %@", visit.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: AppLanguage.shared.code)))))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(L("Delete data…")) { confirmation = .site(record) }.disabled(isBusy)
                    }.padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Button(L("Delete all data…")) { confirmation = .all }.disabled(isBusy || data.records.isEmpty)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: SettingsDesignMetrics.formWidth)
        .padding(.horizontal, SettingsDesignMetrics.formInset)
        .padding(.bottom, 18)
        .task { await data.refresh() }
        .alert(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { action in
            Button(L("Cancel"), role: .cancel) { confirmation = nil }
            Button(L(action.id == "disable" ? "Turn off and delete" : "Delete data"), role: .destructive) {
                isMutating = true
                Task {
                    defer { isMutating = false }
                    switch action {
                    case .disable: await model.setSavesSiteData(false)
                    case .all: await model.deleteSiteData(nil)
                    case .site(let record): await model.deleteSiteData(record)
                    }
                }
                confirmation = nil
            }
        } message: { _ in
            Text(L("The current preview will close. You may need to sign in again. This does not affect your other browsers."))
        }
    }

    private func setSavingEnabled() {
        isMutating = true
        Task {
            defer { isMutating = false }
            await model.setSavesSiteData(true)
        }
    }
    private func types(for record: WKWebsiteDataRecord) -> String {
        var labels: [String] = []
        if record.dataTypes.contains(WKWebsiteDataTypeCookies) { labels.append(L("Cookies")) }
        if !record.dataTypes.isDisjoint(with: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]) { labels.append(L("Cache")) }
        if !record.dataTypes.subtracting([WKWebsiteDataTypeCookies, WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]).isEmpty { labels.append(L("Local storage")) }
        return labels.joined(separator: ", ")
    }
}

private struct SiteMediaPermissionsSettings: View {
    @ObservedObject var permissions: SiteMediaPermissions
    var body: some View {
        SettingsGroup(L("Website permissions"), note: L(permissions.persists
            ? "Remembered permissions stay on this Mac until you reset them or delete website data."
            : "In private mode, remembered permissions are removed when the last website window closes.")) {
            ForEach(SiteMediaDevice.availableDevices, id: \.self) { device in
                SettingsLabel(device.title) {
                    HStack {
                        Text(systemStatus(device)).foregroundStyle(.secondary)
                        if [.denied, .restricted].contains(permissions.systemStatus(device)) {
                            Button(L("System Settings…")) { permissions.openSystemSettings(for: device) }
                        }
                    }
                }
            }
            if permissions.rules.isEmpty {
                Text(L("Websites appear here when they request camera, microphone or location access."))
                    .foregroundStyle(.secondary)
            }
            ForEach(permissions.rules) { rule in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(SiteMediaDevice.availableDevices, id: \.self) { device in
                            SettingsPicker(device.title, selection: Binding(
                                get: { permissions.rules.first(where: { $0.id == rule.id })?[device] ?? .ask },
                                set: { permissions.setChoice($0, device: device, ruleID: rule.id) })) {
                                    ForEach(SiteMediaChoice.allCases, id: \.self) { choice in Text(choice.title).tag(choice) }
                                }
                        }
                        Button(L("Reset permissions")) { permissions.reset(rule) }
                        Text(L("Blocking access stops active capture. Reload the website if it needs to ask again."))
                            .font(.caption).foregroundStyle(.secondary)
                        if #available(macOS 27.0, *) {
                            Text(L("Changing location access reloads the page to stop its location requests."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.requester.address).textSelection(.enabled)
                        if rule.top != rule.requester {
                            Text(L("Embedded in %@", rule.top.address)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refreshSystemStatus()
        }
    }

    private func systemStatus(_ device: SiteMediaDevice) -> String {
        switch permissions.systemStatus(device) {
        case .authorized: return L("Allowed by macOS")
        case .denied: return L("Blocked by macOS")
        case .restricted: return L("Restricted by macOS")
        case .notDetermined: return L("macOS will ask when needed")
        @unknown default: return L("Unknown")
        }
    }
}

private struct AboutSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: AppUpdateService
    @State private var showingThanks = false

    var body: some View {
        SettingsContent {
            SettingsGroup {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 54, height: 54)
                        .accessibilityHidden(true)
                    SettingsText(L("Version %@", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"),
                                 detail: L("Build %@", Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))
                }
            }
            SettingsGroup(L("Updates")) {
                SettingsToggle(L("Check for updates automatically"),
                               detail: L("Updates are downloaded and installed only after your confirmation."),
                               isOn: Binding(get: { updates.automaticallyChecksForUpdates }, set: updates.setAutomaticallyChecksForUpdates))
                CheckForAppUpdatesButton(updates: updates)
            }
            SettingsGroup(L("Support")) {
                Button(L("Support development"), systemImage: "heart") { showingThanks = true }
                SettingsLabel("Telegram") {
                    ViewThatFits {
                        HStack(spacing: 8) { contactButtons }
                        VStack(alignment: .trailing, spacing: 6) { contactButtons }
                    }
                }
            }
        }
        .sheet(isPresented: $showingThanks) { SupportDevelopmentView() }
    }

    @ViewBuilder private var contactButtons: some View {
        Button(L("Open channel")) { model.openDeveloperLink("https://t.me/go_bo") }
        Button(L("Contact the author")) { model.openDeveloperLink("https://t.me/go_bo?direct") }
    }
}

struct SupportDevelopmentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false
    @State private var resetCopyTask: Task<Void, Never>?
    private let address = "TGH8YeF8j1mC7pHnKR7ksYAqrJpYmpDvMh"

    var body: some View {
        VStack(spacing: 18) {
            Text(L("Support development")).font(.title2.bold())
            Text(L("If you find the app useful, you can support its development.\nThank you for your support!"))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(spacing: 5) {
                Text("USDT · TRC20").font(.headline)
                Text(L("TRON network")).foregroundStyle(.secondary)
            }
            Text(address).font(.system(.body, design: .monospaced))
                .textSelection(.enabled).fixedSize()
                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Button {
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(address, forType: .string) else { return }
                didCopy = true
                resetCopyTask?.cancel()
                resetCopyTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    didCopy = false
                }
            } label: { Text(L(didCopy ? "Copied" : "Copy address")).frame(width: 180) }
            Text(L("Send only USDT on the TRON (TRC20) network."))
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(28).frame(width: 480)
        .onExitCommand { dismiss() }
        .onDisappear { resetCopyTask?.cancel() }
    }
}

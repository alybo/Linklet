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
    var color: Color {
        switch self {
        case .general: return .gray
        case .windows, .search: return .blue
        case .sites: return .purple
        case .about: return .gray
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

// Apple macOS 27 UI Kit: Forms examples and Sidebars/{Small,Medium,Large}.
// Provenance and component measurements: docs/MACOS-27-DESIGN-REFERENCE.md.
enum SettingsDesignMetrics {
    static let formInset: CGFloat = 20
    static let labelSpacing: CGFloat = 2
    static let sidebarWidth: CGFloat = 256
    static let sidebarSelectionInset: CGFloat = 10
    // The plain native List adds 8 pt; the resulting icon origin is 28 pt.
    static let sidebarContentInset: CGFloat = 20
    static let selectionRadius: CGFloat = 8
}

struct SettingsNavigationMetrics {
    let rowHeight: CGFloat
    let iconSize: CGFloat
    let labelSize: CGFloat
    init(_ size: SidebarRowSize) {
        switch size {
        case .small: rowHeight = 24; iconSize = 16; labelSize = 11
        case .large: rowHeight = 40; iconSize = 24; labelSize = 15
        default: rowHeight = 32; iconSize = 20; labelSize = 13
        }
    }
}

struct SettingsSidebarView: View {
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sidebarRowSize) private var rowSize
    @ObservedObject var model: AppModel
    private var metrics: SettingsNavigationMetrics { SettingsNavigationMetrics(rowSize) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 12)
            List(selection: Binding<SettingsPage?>(
                get: { model.settingsPage },
                set: { if let page = $0 { model.settingsPage = page } }
            )) {
                Section {
                    ForEach(SettingsPage.allCases.filter { $0 != .about }) { navigationRow($0) }
                }
                Section { navigationRow(.about) }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, metrics.rowHeight)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor).ignoresSafeArea())
        .environment(\.locale, Locale(identifier: language.code))
    }

    private func navigationRow(_ page: SettingsPage) -> some View {
        HStack(spacing: 4) {
            SettingsSectionIcon(page: page, size: metrics.iconSize)
            Text(page.title).font(.system(size: metrics.labelSize))
                .foregroundStyle(model.settingsPage == page || colorScheme == .dark ? Color.white : Color.black)
            Spacer(minLength: 0)
        }
        .frame(height: metrics.rowHeight)
        .contentShape(Rectangle())
        .tag(page)
        .listRowInsets(EdgeInsets(top: 0, leading: SettingsDesignMetrics.sidebarContentInset, bottom: 0, trailing: 14))
        .listRowSeparator(.hidden)
        .listRowBackground(ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if model.settingsPage == page {
                RoundedRectangle(cornerRadius: SettingsDesignMetrics.selectionRadius).fill(Color.accentColor)
                    .padding(.horizontal, SettingsDesignMetrics.sidebarSelectionInset)
            }
        })
    }

}

struct SettingsSectionIcon: View {
    let page: SettingsPage
    let size: CGFloat
    var body: some View {
        Image(systemName: page.symbol).font(.system(size: size * 0.54, weight: .medium))
            .foregroundStyle(.white).frame(width: size, height: size)
            .background(page.color.gradient, in: RoundedRectangle(cornerRadius: size / 4))
    }
}

struct SettingsDetailView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
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
            .frame(maxWidth: 760, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let message = model.statusMessage {
                Divider()
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: language.code))
    }

    private var general: some View {
        Form {
            Section { DefaultBrowserSetting(model: model) }
            Section(L("Application")) {
                Toggle(L("Launch at login"), isOn: Binding(
                    get: { model.isLaunchAtLoginEnabled }, set: model.setLaunchAtLogin))
                Picker(L("Language"), selection: Binding(get: { language.selection }, set: model.setLanguage)) {
                    Text(L("Same as macOS")).tag("system")
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
            }
            Section(L("Getting Started")) {
                Button(action: model.showWelcome) {
                    HStack {
                        VStack(alignment: .leading, spacing: SettingsDesignMetrics.labelSpacing) {
                            Text(L("How to Use Linklet"))
                            Text(L("Opening links, search, and the sidebar.")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.formStyle(.grouped).toggleStyle(.switch)
    }

    private var windows: some View {
        Form {
            Section {
                Picker(L("Window mode"), selection: Binding(
                    get: { model.opensLinksInNewWindows }, set: model.setOpensLinksInNewWindows)) {
                    Text(L("Single window")).tag(false)
                    Text(L("Multiple windows")).tag(true)
                }.pickerStyle(.segmented)
                Text(L(model.opensLinksInNewWindows
                    ? "Each new link opens in a separate window."
                    : "New links replace the page in a single window."))
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Window behavior"))
                    Picker(L("Window behavior"), selection: Binding(
                        get: { model.previewWindowBehavior }, set: model.setPreviewWindowBehavior)) {
                        ForEach(PreviewWindowBehavior.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().id(language.code)
                    .accessibilityIdentifier("settings-window-behavior")
                    Text(L("When switching between apps.")).font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text(L("Windows")) }
            SidebarSettingsSections(library: model.linkLibrary, show: model.showSidebar)
        }.formStyle(.grouped).toggleStyle(.switch)
    }
}

struct DefaultBrowserSetting: View {
    @ObservedObject var model: AppModel
    var body: some View {
        LabeledContent {
            if model.isDefaultBrowser {
                Label(L("Default"), systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else {
                Button(L("Make Default…"), action: model.makeDefaultBrowser)
            }
        } label: {
            VStack(alignment: .leading, spacing: SettingsDesignMetrics.labelSpacing) {
                Text(L("Default browser"))
                Text(L(model.isDefaultBrowser ? "Links open in Linklet." : "Links will open in Linklet."))
                    .font(.caption).foregroundStyle(.secondary)
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
        Section {
            Toggle(isOn: Binding(get: { blocker.isEnabled }, set: model.setAdBlockingEnabled)) {
                VStack(alignment: .leading, spacing: SettingsDesignMetrics.labelSpacing) {
                    Text(L("Block ads"))
                    Text(L("AdGuard filter lists")).font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup(L("Exceptions (%d)", blocker.siteOverrides.count)) {
                if blocker.siteOverrides.isEmpty {
                    Text(L("No exceptions")).foregroundStyle(.secondary)
                }
                ForEach(blocker.siteOverrides.keys.sorted(), id: \.self) { host in
                    HStack {
                        Toggle(host, isOn: Binding(get: { blocker.siteOverrides[host] ?? blocker.isEnabled }, set: { enabled in
                            blocker.setSiteEnabled(enabled, host: host); reload(host: host)
                        }))
                        Button { blocker.removeSiteOverride(host); reload(host: host) } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless).help(L("Remove exception"))
                    }
                }
                Button(L("Add website…"), systemImage: "plus") {
                    address = ""; invalidAddress = false; showingAddSite = true
                }
            }
            if let error = blocker.errorMessage { Text(error).foregroundStyle(.red) }
        } header: { Text(L("Ad Blocking")) } footer: {
            Text(L("Uses AdGuard filters. Change blocking for the current website in its page menu."))
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
        Section {
            Toggle(L("Show Open in browser button"), isOn: Binding(
                get: { model.showsOpenInButton }, set: model.setShowsOpenInButton))
                .accessibilityIdentifier("settings-show-open-in-button")
            Picker(L("Open browser list"), selection: Binding(
                get: { model.opensBrowserMenuOnHover }, set: model.setOpensBrowserMenuOnHover)) {
                Text(L("On click")).tag(false)
                Text(L("On hover")).tag(true)
            }.accessibilityIdentifier("settings-browser-menu-trigger")
            if !model.visibleTargets.isEmpty {
                Picker(L("Browser for sending links"), selection: Binding(
                    get: { model.preferredTarget?.id ?? "" }, set: model.setPreferredTarget)) {
                    ForEach(model.visibleTargets) { Text($0.displayName).tag($0.id) }
                }
            }
        } header: { Text(L("Opening in Another Browser")) } footer: {
            Text(L("The arrow beside the page address opens the browser menu. The selected browser appears first and opens the original link with ⌘1."))
        }
        Section {
            if model.targets.isEmpty {
                Text(L("No compatible browsers or Orion profile apps were found.")).foregroundStyle(.secondary)
            }
            ForEach(model.orderedTargets) { target in
                row(target)
                    .onDrag { draggedID = target.id; return NSItemProvider(object: target.id as NSString) }
                    .onDrop(of: [UTType.text], delegate: BrowserOrderDropDelegate(
                        destination: target.id, model: model, draggedID: $draggedID, dropTargetID: $dropTargetID))
            }
            Button(L("Refresh")) { Task { await model.refreshTargetsForSettings() } }
                .disabled(model.isRefreshingTargets)
        } header: { Text(L("Browsers in the Open in menu")) }
        Section {
            Toggle(L("Sort browsers by usage"), isOn: Binding(get: { model.sortsTargetsByUsage }, set: model.setSortTargetsByUsage))
            Button(L("Reset usage"), action: model.resetTargetUsage)
                .disabled(model.targets.allSatisfy { model.targetUsageCount($0) == 0 })
        } header: { Text(L("Browser order")) } footer: {
            Text(L("Drag browsers to reorder when automatic sorting is off."))
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
            Form {
                Section {
                    Button { showsWebsiteData = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: SettingsDesignMetrics.labelSpacing) {
                                Text(L("Website Data"))
                                Text(L(data.isEnabled ? "Website data is saved." : "Website data is temporary."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("settings-website-data")
                }
                HistorySettingsSection(library: model.linkLibrary)
                AdBlockSettingsView(model: model, blocker: model.adBlockService)
                SiteMediaPermissionsSettings(permissions: data.mediaPermissions)
            }.formStyle(.grouped)
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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(L("Privacy"), action: close).buttonStyle(.link)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                Text(L("Website Data")).font(.headline)
                Spacer()
            }.padding(SettingsDesignMetrics.formInset)
            List {
                Section {
                    Toggle(isOn: Binding(get: { data.isEnabled }, set: { enabled in
                        if !enabled { confirmation = .disable }
                        else { setSavingEnabled() }
                    })) {
                        VStack(alignment: .leading, spacing: SettingsDesignMetrics.labelSpacing) {
                            Text(L("Save website data"))
                            Text(L("Stay signed in and keep website preferences."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.toggleStyle(.switch).controlSize(.mini).disabled(isBusy)
                    Text(L(data.isEnabled
                        ? "Website data is stored on this Mac. Turning this off deletes saved website data."
                        : "Without saving, website data is deleted when all related windows close. Hiding the window when switching apps also ends the preview."))
                        .font(.caption).foregroundStyle(.secondary)
                    if data.isEnabled {
                        Picker(L("Automatically clear data"), selection: Binding(get: { data.inactiveDays }, set: data.setInactiveDays)) {
                            Text(L("Never")).tag(0)
                            ForEach([7, 30, 90], id: \.self) { Text(L("%d days", $0)).tag($0) }
                        }.disabled(isBusy)
                    }
                } header: { Text(L("Storage")) }
                Section {
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
                } header: { Text(L("Stored websites")) }
            }.listStyle(.inset)
            Divider()
            HStack(spacing: 12) {
                if data.isBusy { ProgressView().controlSize(.small).accessibilityLabel(L("Updating website data…")) }
                TextField(L("Search websites"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer()
                Button(L("Refresh")) { Task { await data.refresh() } }.disabled(isBusy)
                Button(L("Delete all data…")) { confirmation = .all }.disabled(isBusy || data.records.isEmpty)
            }.padding(SettingsDesignMetrics.formInset)
        }
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
        Section {
            ForEach(SiteMediaDevice.availableDevices, id: \.self) { device in
                LabeledContent(device.title) {
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
                    ForEach(SiteMediaDevice.availableDevices, id: \.self) { device in
                        Picker(device.title, selection: Binding(
                            get: { permissions.rules.first(where: { $0.id == rule.id })?[device] ?? .ask },
                            set: { permissions.setChoice($0, device: device, ruleID: rule.id) })) {
                                ForEach(SiteMediaChoice.allCases, id: \.self) { choice in Text(choice.title).tag(choice) }
                            }
                    }
                    Button(L("Reset permissions")) { permissions.reset(rule) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.requester.address).textSelection(.enabled)
                        if rule.top != rule.requester {
                            Text(L("Embedded in %@", rule.top.address)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text(L("Website permissions"))
        } footer: {
            VStack(alignment: .leading, spacing: SettingsDesignMetrics.labelSpacing) {
                Text(L(permissions.persists
                    ? "Remembered permissions stay on this Mac until you reset them or delete website data."
                    : "In private mode, remembered permissions are removed when the last website window closes."))
                Text(L("Blocking access stops active capture. Reload the website if it needs to ask again."))
                if #available(macOS 27.0, *) {
                    Text(L("Changing location access reloads the page to stop its location requests."))
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
        ScrollView {
            VStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 80, height: 80)
                Text("Linklet").font(.largeTitle.bold())
                Text(L("Version %@", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"))
                    .foregroundStyle(.secondary)
                    .help(L("Build %@", Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))
                Button(L("Support development")) { showingThanks = true }
                    .padding(.vertical, 8)
                HStack(spacing: 10) {
                    Button("Telegram") { model.openDeveloperLink("https://t.me/go_bo") }
                    Text("·").foregroundStyle(.secondary)
                    Button(L("Contact the author")) { model.openDeveloperLink("https://t.me/go_bo?direct") }
                }.buttonStyle(.link)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(L("Check for updates automatically"), isOn: Binding(
                            get: { updates.automaticallyChecksForUpdates }, set: updates.setAutomaticallyChecksForUpdates))
                            .toggleStyle(.switch)
                        Text(L("Updates are downloaded and installed only after your confirmation."))
                            .font(.caption).foregroundStyle(.secondary)
                        CheckForAppUpdatesButton(updates: updates)
                    }.padding(8)
                } label: { Text(L("Updates")) }
                .padding(.top, 24)
            }
            .frame(maxWidth: 500).padding(SettingsDesignMetrics.formInset).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingThanks) { SupportDevelopmentView() }
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

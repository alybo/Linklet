import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, browsers, sites, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return L("General")
        case .browsers: return L("Browsers")
        case .sites: return L("Website data")
        case .about: return L("About")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .browsers: return "globe"
        case .sites: return "externaldrive"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding<SettingsPage?>(
                get: { model.settingsPage },
                set: { if let page = $0 { model.settingsPage = page } }
            )) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.symbol).tag(page)
                        .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(model.settingsPage.title).font(.title2.bold())
                    .padding(.horizontal, 24).padding(.vertical, 20)
                Divider()
                Group {
                    switch model.settingsPage {
                    case .general: general
                    case .browsers: BrowserSettingsView(model: model)
                    case .sites: SiteDataSettingsView(model: model, data: model.siteData)
                    case .about: AboutSettingsView(model: model, updates: model.appUpdates)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let message = model.statusMessage {
                    Divider()
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .padding(16).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: model.refreshTargets)
    }

    private var general: some View {
        Form {
            Section {
                Toggle(L("Launch Linklet when I sign in"), isOn: Binding(
                    get: { model.isLaunchAtLoginEnabled }, set: model.setLaunchAtLogin))
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Default link handler"))
                        Text(model.isDefaultBrowser ? L("Linklet handles web links on this Mac.") : L("Set Linklet as the default browser to preview external links."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Make Linklet Default Browser"), action: model.makeDefaultBrowser)
                        .disabled(model.isDefaultBrowser)
                }
            }
            Section(L("Preview window")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("When switching apps"))
                    Picker(L("When switching apps"), selection: Binding(
                        get: { model.previewWindowBehavior }, set: model.setPreviewWindowBehavior)) {
                        ForEach(PreviewWindowBehavior.allCases) { Text($0.title).tag($0) }
                    }
                    .id(language.code)
                    .pickerStyle(.segmented).labelsHidden()
                    Text(model.previewWindowBehavior.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(isOn: Binding(get: { model.isAdBlockingEnabled }, set: model.setAdBlockingEnabled)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Block ads"))
                        Text(L("AdGuard filter lists")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker(L("Language"), selection: Binding(get: { language.selection }, set: model.setLanguage)) {
                    Text(L("System language")).tag("system")
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
            }
            Section {
                Button(L("Welcome to Linklet"), action: model.showWelcome)
            }
        }
        .formStyle(.grouped).toggleStyle(.switch)
    }
}

private struct BrowserSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draggedID: String?
    @State private var dropTargetID: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.sortsTargetsByUsage }, set: model.setSortTargetsByUsage)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Sort browsers by usage"))
                        Text(L("The most-used browser becomes the primary Open in action; the others follow in the menu."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                HStack {
                    Button(L("Refresh"), action: model.refreshTargets)
                    Spacer()
                    Button(L("Reset usage"), action: model.resetTargetUsage)
                        .disabled(model.targets.allSatisfy { model.targetUsageCount($0) == 0 })
                }
            }
            Section {
                if model.targets.isEmpty {
                    Text(L("No compatible browsers or Orion profile apps were found."))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.orderedTargets) { target in
                    if model.sortsTargetsByUsage {
                        row(target)
                    } else {
                        row(target)
                            .onDrag {
                                draggedID = target.id
                                return NSItemProvider(object: target.id as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: BrowserOrderDropDelegate(
                                destination: target.id, model: model, draggedID: $draggedID, dropTargetID: $dropTargetID))
                            .overlay(alignment: .top) {
                                if dropTargetID == target.id {
                                    Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
                                }
                            }
                    }
                }
                if !model.sortsTargetsByUsage && !model.targets.isEmpty {
                    Text(L("Drag to reorder. The first enabled browser is the primary action."))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .onDrop(of: [UTType.text], delegate: BrowserOrderDropDelegate(
                            destination: nil, model: model, draggedID: $draggedID, dropTargetID: $dropTargetID))
                        .overlay(alignment: .top) {
                            if dropTargetID == "end" {
                                Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
                            }
                        }
                }
            } header: {
                Text(L("Shown browsers"))
            } footer: {
                Text(L("Usage counts only links opened through Linklet."))
            }
        }.formStyle(.grouped)
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

private struct SiteDataSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var data: SiteDataService
    @State private var search = ""
    @State private var confirmation: DataDeletion?

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

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { data.isEnabled }, set: { enabled in
                    if !enabled { confirmation = .disable }
                    else { Task { await model.setSavesSiteData(true) } }
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Save website data"))
                        Text(L("Keep sign-ins and website preferences between previews."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch).disabled(data.isBusy)
                Text(L("When saving is off, closing or hiding the preview deletes its data, including when switching apps."))
                    .font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text(L("Data is stored only in Linklet on this Mac, separately from your other browsers."))
            }
            Section {
                Picker(L("Delete data for websites not visited for"), selection: Binding(
                    get: { data.inactiveDays }, set: data.setInactiveDays)) {
                    Text(L("Never")).tag(0)
                    ForEach([7, 30, 90], id: \.self) { days in Text(L("%d days", days)).tag(days) }
                }
                .disabled(!data.isEnabled || data.isBusy)
            } footer: {
                Text(L("Inactive website data is removed before the next preview. Background requests do not count as visits."))
            }
            Section(L("Stored websites")) {
                if data.records.count > 5 || !search.isEmpty {
                    TextField(L("Search websites"), text: $search)
                        .textFieldStyle(.roundedBorder)
                }
                if data.isBusy {
                    HStack { ProgressView().controlSize(.small); Text(L("Updating website data…")).foregroundStyle(.secondary) }
                }
                if filtered.isEmpty && !data.isBusy {
                    Text(L(search.isEmpty ? "No stored website data." : "No matching websites."))
                        .foregroundStyle(.secondary).padding(.vertical, 12)
                }
                ForEach(filtered, id: \.displayName) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.displayName).textSelection(.enabled)
                            Text(types(for: record)).font(.caption).foregroundStyle(.secondary)
                            if let visit = data.lastVisit(for: record.displayName) {
                                Text(L("Last visited: %@", visit.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: AppLanguage.shared.code)))))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(L("Delete data…")) { confirmation = .site(record) }
                            .disabled(data.isBusy)
                    }
                }
                if !data.records.isEmpty {
                    Button(L("Delete all data…")) { confirmation = .all }
                        .disabled(data.isBusy)
                }
            }
        }
        .formStyle(.grouped)
        .task { await data.refresh() }
        .alert(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { action in
            Button(L("Cancel"), role: .cancel) { confirmation = nil }
            Button(L(action.id == "disable" ? "Turn off and delete" : "Delete data"), role: .destructive) {
                Task {
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

    private func types(for record: WKWebsiteDataRecord) -> String {
        var labels: [String] = []
        if record.dataTypes.contains(WKWebsiteDataTypeCookies) { labels.append(L("Cookies")) }
        if !record.dataTypes.isDisjoint(with: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]) { labels.append(L("Cache")) }
        if !record.dataTypes.subtracting([WKWebsiteDataTypeCookies, WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]).isEmpty { labels.append(L("Local storage")) }
        return labels.joined(separator: ", ")
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
                Text(L("Author — @alybo")).padding(.top, 4)
                Button(L("Support development")) { showingThanks = true }
                    .padding(.vertical, 8)
                HStack(spacing: 10) {
                    Button("Telegram") { model.openDeveloperLink("https://t.me/go_bo") }
                    Text("·").foregroundStyle(.secondary)
                    Button(L("Contact the author")) { model.openDeveloperLink("https://t.me/go_bo?direct") }
                }.buttonStyle(.link)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(L("Automatically check for updates"), isOn: Binding(
                            get: { updates.automaticallyChecksForUpdates }, set: updates.setAutomaticallyChecksForUpdates))
                            .toggleStyle(.switch)
                        Text(L("Updates are downloaded and installed only after your confirmation."))
                            .font(.caption).foregroundStyle(.secondary)
                        CheckForAppUpdatesButton(updates: updates)
                    }.padding(8)
                } label: { Text(L("Updates")) }
                .padding(.top, 24)
            }
            .frame(maxWidth: 520).padding(28).frame(maxWidth: .infinity)
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

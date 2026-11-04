import AppKit
import SwiftUI
import WebKit

enum PreviewLayout {
    // Keep the native macOS control target, while drawing compact symbols inside it.
    static let topBarHeight: CGFloat = 36
    static let controlHeight: CGFloat = 28
    static let toolbarItemSpacing: CGFloat = 8
    static let toolbarCornerRadius: CGFloat = 8
    static let toolbarHoverOpacity: CGFloat = 0.047
    static let toolbarContentInset: CGFloat = 10
    static let contentInset: CGFloat = 6
    static let contentCornerRadius: CGFloat = 12
    static let windowControlSymbolSize: CGFloat = 14
    static let windowControlHitSize: CGFloat = 24
}

struct PreviewRootView: View {
    @ObservedObject var model: AppModel
    let session: PreviewSession
    let existingWebView: WKWebView?

    init(model: AppModel, session: PreviewSession? = nil, existingWebView: WKWebView? = nil) {
        self.model = model
        self.session = session ?? model.previewSession
        self.existingWebView = existingWebView
    }

    var body: some View {
        PreviewPageView(session: session, model: model, existingWebView: existingWebView)
    }
}

/// Shared chrome for incoming links and WebKit-created child windows. An adopted
/// web view keeps its original configuration, opener, POST and navigation stack.
struct PreviewPageView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var session: PreviewSession
    var model: AppModel? = nil
    var existingWebView: WKWebView? = nil
    @State private var isToolbarHovered = false
    @StateObject private var browserMenu = BrowserMenuInteraction()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .frame(height: PreviewLayout.topBarHeight)
                .overlay(alignment: .bottom) {
                    if session.isLoading {
                        ProgressView(value: session.estimatedProgress)
                            .progressViewStyle(PreviewLoadingProgressStyle())
                            .accessibilityLabel(L("Loading page"))
                            .allowsHitTesting(false)
                    }
                }

            webContent
                .padding(.horizontal, PreviewLayout.contentInset)
                .padding(.bottom, PreviewLayout.contentInset)
        }
        .background { PreviewWindowMaterial() }
        .background { PreviewPageKeyboardCommands(session: session) }
        .overlay(alignment: .topTrailing) {
            if let model {
                PreviewBrowserMenuLayer(model: model, session: session, menu: browserMenu)
            }
        }
        .onChange(of: session.navigationID) { _ in browserMenu.dismiss() }
        .onChange(of: session.currentURL) { _ in browserMenu.dismiss() }
        .onChange(of: session.isActive) { _ in browserMenu.dismiss() }
        .onDisappear { browserMenu.dismiss() }
        .ignoresSafeArea(.container, edges: .all)
        .alert(
            L("Couldn't open the page"),
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            )
        ) {
            if let continueInBrowser = session.onContinueInBrowser,
               model == nil || model?.preferredTarget != nil {
                Button(L("Continue in browser"), action: continueInBrowser)
            }
            Button(L("OK"), role: .cancel) { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? L("Unknown error"))
        }
    }

    private var toolbar: some View {
        HStack(spacing: PreviewLayout.toolbarItemSpacing) {
            PreviewWindowControls(session: session)

            if let model {
                PreviewBookmarkLocationView(session: session, title: siteTitle,
                                            settings: model.searchSettings, library: model.linkLibrary,
                                            isToolbarHovered: isToolbarHovered)
            } else {
                PreviewLocationView(session: session, title: siteTitle, isToolbarHovered: isToolbarHovered) { input in
                    session.submitAddress(input, engine: .google)
                }
            }

            if !session.isWelcome && session.isActive {
                if let model {
                    PreviewOpenInToolbarView(model: model, session: session, menu: browserMenu)
                } else if let continueInBrowser = session.onContinueInBrowser {
                    Button(L("Continue in browser"), action: continueInBrowser)
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isToolbarHovered = $0 }
    }

    private var webContent: some View {
        ZStack(alignment: .top) {
            if session.isActive {
                Group {
                    if let existingWebView {
                        AdoptedWebPreview(webView: existingWebView)
                    } else {
                        WebPreview(session: session).id(session.navigationID)
                    }
                }.background(Color(nsColor: .textBackgroundColor))
                    .allowsHitTesting(session.pageFailure == nil)
                    .accessibilityHidden(session.pageFailure != nil)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }

            if session.isPreparingNewPage {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .transition(.opacity)
            }
            if let failure = session.pageFailure {
                PreviewPageFailureView(session: session, failure: failure)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PreviewLayout.contentCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PreviewLayout.contentCornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.72), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if session.pageFailure == nil { PreviewFindOverlay(controller: session.pageFind) }
        }
        .animation(.easeOut(duration: 0.13), value: session.isPreparingNewPage)
    }

    private var siteTitle: String {
        let pageTitle = session.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pageTitle.isEmpty {
            return pageTitle
        }

        guard let host = session.currentURL?.host, !host.isEmpty else {
            return L("Preview")
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

private struct PreviewPageFailureView: View {
    @ObservedObject var session: PreviewSession
    let failure: PageLoadFailure
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: failure.kind == .offline ? "wifi.slash" : (failure.kind == .crashed ? "arrow.clockwise.circle" : "exclamationmark.circle"))
                .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(failure.title).font(.system(size: 18, weight: .semibold))
            Text(failure.explanation).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let url = failure.url {
                Text(url.absoluteString).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            if failure.resubmitsForm {
                Text(L(failure.allowsRetry
                    ? "Submitting again may repeat an action on this website."
                    : "Return to the website to submit the form again."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                if session.canReturnToLoadedPage {
                    Button(L("Return to page"), action: session.returnToLoadedPage)
                }
                if failure.allowsRetry {
                    Button(L(failure.resubmitsForm ? "Retry submission" : (failure.kind == .crashed ? "Restore page" : "Try again")),
                           action: session.retryPageLoad)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("preview-retry-page")
                }
            }.padding(.top, 4)
        }.frame(maxWidth: 360).padding(24)
            .accessibilityElement(children: .contain)
    }
}

/// Shared by normal and adopted windows; does not add any visible chrome.
private struct PreviewPageKeyboardCommands: NSViewRepresentable {
    let session: PreviewSession
    func makeNSView(context: Context) -> PreviewPageCommandView {
        PreviewPageCommandView(session: session)
    }
    func updateNSView(_ view: PreviewPageCommandView, context: Context) {}
    static func dismantleNSView(_ view: PreviewPageCommandView, coordinator: ()) {
        view.stopObserving()
    }
}

final class PreviewPageCommandView: NSView {
    private weak var session: PreviewSession?
    private var eventMonitor: Any?

    init(session: PreviewSession) {
        self.session = session
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    func stopObserving() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.window === window, window?.isKeyWindow == true,
              window?.attachedSheet == nil, let session, session.isActive,
              !session.isWelcome, session.webView != nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .command || modifiers == [.command, .shift] else { return false }
        // Character matching supports other layouts; physical fallbacks also
        // keep these commands available when Russian letters are reported.
        let character = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command, character == "1" || event.keyCode == 18,
           let openInBrowser = session.onContinueInBrowser {
            if !event.isARepeat { openInBrowser() }
            return true
        }
        if modifiers == .command, character == "r" || event.keyCode == 15 {
            if !event.isARepeat { session.reload() }
            return true
        }
        if character == "+" || character == "=" || [24, 69].contains(event.keyCode) {
            session.changePageZoom(increase: true)
            return true
        }
        guard modifiers == .command else { return false }
        if character == "-" || [27, 78].contains(event.keyCode) {
            session.changePageZoom(increase: false)
            return true
        }
        if character == "0" || [29, 82].contains(event.keyCode) {
            session.resetPageZoom()
            return true
        }
        return false
    }
}

/// Lifecycle and delegates belong to WebPopupWindowController. SwiftUI only
/// embeds the supplied view; it must not attach/load it again or tear it down.
private struct AdoptedWebPreview: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct PreviewLoadingProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * min(max(configuration.fractionCompleted ?? 0, 0), 1))
        }
        .frame(height: 2)
    }
}

struct PreviewWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct PreviewWindowControls: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var session: PreviewSession

    var body: some View {
        HStack(spacing: 0) {
            WindowControlButton(
                imageName: "PreviewClose",
                help: L("Close preview"),
                action: { NSApp.keyWindow?.performClose(nil) }
            )

            if session.canGoBack {
                WindowControlButton(
                    imageName: "PreviewBack",
                    help: L("Back — ⌘["),
                    action: session.goBack
                )
                .keyboardShortcut("[", modifiers: .command)
            }

            if session.canGoForward {
                WindowControlButton(
                    imageName: "PreviewForward",
                    help: L("Forward — ⌘]"),
                    action: session.goForward
                )
                .keyboardShortcut("]", modifiers: .command)
            }
        }
        .offset(x: -4)
    }
}

struct WindowControlButton: View {
    @ObservedObject private var language = AppLanguage.shared
    let imageName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(imageName)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: PreviewLayout.windowControlSymbolSize, height: PreviewLayout.windowControlSymbolSize)
                .frame(width: PreviewLayout.windowControlHitSize, height: PreviewLayout.windowControlHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .help(help)
    }
}

private struct PreviewBookmarkLocationView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var session: PreviewSession
    let title: String
    @ObservedObject var settings: SearchSettings
    let library: LinkLibrary
    let isToolbarHovered: Bool
    @State private var showsEditor = false

    private var saved: FavoriteSite? { settings.bookmark(for: session.currentURL) }

    var body: some View {
        PreviewLocationView(session: session, title: title, isToolbarHovered: isToolbarHovered,
                            isBookmarked: saved != nil, isBookmarkEditorPresented: showsEditor,
                            editBookmark: { showsEditor = true }) { input in
            session.submitAddress(input, engine: settings.engine)
        }
            .sheet(isPresented: $showsEditor) {
                BookmarkEditor(settings: settings, library: library, site: saved,
                               initialURL: session.currentURL, initialTitle: session.pageTitle)
            }
    }
}

enum BrowserDrawerLayout {
    static let width: CGFloat = 184
    static let animationDuration: TimeInterval = 0.22
}

/// The viewport stays fixed below the toolbar while the drawer slides through it.
/// Keeping the view mounted also lets a quick reversal continue from its current position.
private struct BrowserDrawerSlide: GeometryEffect {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 0, y: -size.height * (1 - progress)))
    }
}

private struct PreviewBrowserMenuLayer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: PreviewSession
    @ObservedObject var menu: BrowserMenuInteraction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var targets: [BrowserTarget] {
        model.showsOpenInButton ? Array(model.previewOpenTargets.dropFirst()) : model.previewOpenTargets
    }

    var body: some View {
        BrowserTargetPicker(
            targets: targets,
            firstShortcutNumber: model.showsOpenInButton ? 2 : 1,
            menu: menu,
            onOpen: openBrowser,
            onFind: { menu.dismiss(); model.refreshTargets() },
            onChoose: { menu.dismiss(); model.showSettings(page: .search) }
        )
        .modifier(BrowserDrawerSlide(progress: menu.isPresented ? 1 : 0))
        .clipped()
        .animation(reduceMotion ? nil : .timingCurve(0.22, 0.7, 0.25, 1,
            duration: BrowserDrawerLayout.animationDuration), value: menu.isPresented)
        .allowsHitTesting(menu.isPresented)
        .disabled(!menu.isPresented)
        .accessibilityHidden(!menu.isPresented)
        .padding(.top, PreviewLayout.topBarHeight)
        .background { BrowserMenuEventBridge(menu: menu, targets: targets, onOpen: openBrowser).accessibilityHidden(true) }
        .onChange(of: model.showsOpenInButton) { _ in menu.dismiss() }
        .onChange(of: model.opensBrowserMenuOnHover) { _ in menu.dismiss() }
    }

    private func openBrowser(_ target: BrowserTarget) {
        menu.dismiss()
        model.openOriginalURL(in: target, session: session)
    }
}

/// Owns only menu interaction; the page and its native WebKit view keep focus.
@MainActor
final class BrowserMenuInteraction: ObservableObject {
    @Published private(set) var isPresented = false
    @Published var selectedIndex: Int?
    weak var triggerView: NSView?
    weak var cardView: NSView?
    private var triggerHovered = false
    private var cardHovered = false
    private var openedByHover = false
    private var pending: Task<Void, Never>?

    func toggle() {
        if isPresented { dismiss() }
        else { pending?.cancel(); openedByHover = false; isPresented = true }
    }

    func dismiss() {
        pending?.cancel()
        pending = nil
        if isPresented { isPresented = false }
        if selectedIndex != nil { selectedIndex = nil }
        openedByHover = false
        cardHovered = false
        triggerHovered = false
    }

    func beginKeyboardSelection() {
        pending?.cancel()
        openedByHover = false
    }

    func hoverTrigger(_ inside: Bool, enabled: Bool) {
        triggerHovered = inside
        pending?.cancel()
        guard enabled else { return }
        if inside && !isPresented {
            schedule(after: 180_000_000) { menu in
                guard menu.triggerHovered else { return }
                menu.openedByHover = true
                menu.isPresented = true
            }
        } else if !inside { closeAfterLeaving() }
    }

    func hoverCard(_ inside: Bool) {
        cardHovered = inside
        pending?.cancel()
        if !inside { closeAfterLeaving() }
    }

    private func closeAfterLeaving() {
        guard openedByHover, !triggerHovered, !cardHovered else { return }
        // Bridge the small gap between the arrow and the card.
        schedule(after: 300_000_000) { menu in
            if !menu.triggerHovered && !menu.cardHovered { menu.dismiss() }
        }
    }

    private func schedule(after delay: UInt64, action: @escaping (BrowserMenuInteraction) -> Void) {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self else { return }
            action(self)
        }
    }
}

private struct BrowserMenuRegion: NSViewRepresentable {
    let menu: BrowserMenuInteraction
    let isTrigger: Bool
    func makeNSView(context: Context) -> BrowserMenuRegionView {
        let view = BrowserMenuRegionView()
        view.setAccessibilityElement(false)
        if isTrigger { menu.triggerView = view } else { menu.cardView = view }
        return view
    }
    func updateNSView(_ view: BrowserMenuRegionView, context: Context) {}
}

private final class BrowserMenuRegionView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct BrowserMenuEventBridge: NSViewRepresentable {
    let menu: BrowserMenuInteraction
    let targets: [BrowserTarget]
    let onOpen: (BrowserTarget) -> Void
    func makeNSView(context: Context) -> BrowserMenuEventView { BrowserMenuEventView(menu: menu) }
    func updateNSView(_ view: BrowserMenuEventView, context: Context) {
        view.targets = targets
        view.onOpen = onOpen
    }
    static func dismantleNSView(_ view: BrowserMenuEventView, coordinator: ()) { view.stopObserving() }
}

final class BrowserMenuEventView: NSView {
    private let interaction: BrowserMenuInteraction
    var targets: [BrowserTarget] = []
    var onOpen: ((BrowserTarget) -> Void)?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(menu: BrowserMenuInteraction) {
        self.interaction = menu
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interaction.dismiss() }
            }
    }
    func stopObserving() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil; resignObserver = nil
    }
    func handle(_ event: NSEvent) -> Bool {
        guard interaction.isPresented else { return false }
        guard event.window === window else {
            if event.type != .keyDown { interaction.dismiss() }
            return false
        }
        if event.type != .keyDown {
            let inside = [interaction.triggerView, interaction.cardView].compactMap { $0 }.contains { region in
                region.bounds.contains(region.convert(event.locationInWindow, from: nil))
            }
            if !inside { interaction.dismiss() }
            return false
        }
        guard window?.isKeyWindow == true, window?.attachedSheet == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty {
            switch event.keyCode {
            case 53: interaction.dismiss(); return true
            case 125, 126:
                interaction.beginKeyboardSelection()
                guard !targets.isEmpty else { return true }
                let step = event.keyCode == 125 ? 1 : -1
                interaction.selectedIndex = interaction.selectedIndex.map { ($0 + step + targets.count) % targets.count }
                    ?? (step == 1 ? 0 : targets.count - 1)
                return true
            case 36, 76:
                if let index = interaction.selectedIndex, targets.indices.contains(index), !event.isARepeat {
                    onOpen?(targets[index])
                }
                return true
            case 48: interaction.dismiss()
            default: break
            }
        }
        return false
    }
}

struct PreviewOpenInToolbarView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var model: AppModel
    @ObservedObject var session: PreviewSession
    @ObservedObject var menu: BrowserMenuInteraction
    @State private var isHovered = false

    private var targets: [BrowserTarget] {
        model.previewOpenTargets
    }

    var body: some View {
        Group {
            if !model.showsOpenInButton {
                pickerButton
                    .background(Color.primary.opacity(isHovered || menu.isPresented ? PreviewLayout.toolbarHoverOpacity : 0))
                    .clipShape(RoundedRectangle(cornerRadius: PreviewLayout.toolbarCornerRadius, style: .continuous))
                    .onHover { isHovered = $0 }
            } else if let preferredTarget = targets.first {
                HStack(spacing: 0) {
                    primaryButton(for: preferredTarget)

                    pickerButton
                }
                .frame(height: PreviewLayout.controlHeight)
                .background(Color.primary.opacity(isHovered || menu.isPresented ? PreviewLayout.toolbarHoverOpacity : 0))
                .clipShape(RoundedRectangle(cornerRadius: PreviewLayout.toolbarCornerRadius, style: .continuous))
                .onHover { isHovered = $0 }
            } else {
                Button(action: model.refreshTargets) {
                    Label(model.targets.isEmpty ? L("Find browsers") : L("Choose browsers"), systemImage: "safari")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: PreviewLayout.controlHeight)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func primaryButton(for target: BrowserTarget) -> some View {
        Button {
            model.openOriginalURL(in: target, session: session)
        } label: {
            HStack(spacing: 7) {
                Image(nsImage: TargetIconCache.shared.icon(for: target.applicationURL))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)

                Text(L("Open in %@", target.displayName))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.leading, PreviewLayout.toolbarContentInset)
            .padding(.trailing, 10)
            .frame(height: PreviewLayout.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("1", modifiers: .command)
        .help(L("Open in %@", target.displayName) + " — ⌘1")
        .accessibilityIdentifier("preview-open-in-button")
    }

    private var pickerButton: some View {
        Button {
            menu.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 27, height: PreviewLayout.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.showsOpenInButton && targets.count < 2)
        .accessibilityLabel(L("Open browser menu"))
        .accessibilityIdentifier("preview-browser-menu")
        .background { BrowserMenuRegion(menu: menu, isTrigger: true).accessibilityHidden(true) }
        .onHover { inside in
            menu.hoverTrigger(inside, enabled: model.opensBrowserMenuOnHover && !(model.showsOpenInButton && targets.count < 2))
        }
    }
}

private struct BrowserTargetPicker: View {
    @ObservedObject private var language = AppLanguage.shared
    let targets: [BrowserTarget]
    let firstShortcutNumber: Int
    @ObservedObject var menu: BrowserMenuInteraction
    let onOpen: (BrowserTarget) -> Void
    let onFind: () -> Void
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L("Open in browser"))
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 5)

            if targets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button(L("Find browsers"), action: onFind)
                    Button(L("Choose browsers"), action: onChoose)
                }.buttonStyle(.plain).font(.system(size: 12)).padding(10)
                    .accessibilityIdentifier("preview-browser-picker-empty")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                                BrowserTargetPickerRow(
                                    target: target,
                                    shortcutNumber: index + firstShortcutNumber <= 9 ? index + firstShortcutNumber : nil,
                                    isSelected: menu.selectedIndex == index,
                                    onHover: { menu.selectedIndex = $0 ? index : nil },
                                    action: { onOpen(target) }
                                ).id(index)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: CGFloat(min(targets.count, 7)) * 38 - 2)
                    .onChange(of: menu.selectedIndex) { index in
                        if let index { proxy.scrollTo(index) }
                    }
                }
            }
        }
        .padding(6)
        .frame(width: BrowserDrawerLayout.width)
        .background { PreviewWindowMaterial() }
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
                .allowsHitTesting(false)
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
        .background { BrowserMenuRegion(menu: menu, isTrigger: false).accessibilityHidden(true) }
        .onHover { menu.hoverCard($0) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("preview-browser-card")
    }
}

private struct BrowserTargetPickerRow: View {
    @ObservedObject private var language = AppLanguage.shared
    let target: BrowserTarget
    let shortcutNumber: Int?
    let isSelected: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(nsImage: TargetIconCache.shared.icon(for: target.applicationURL))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(target.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    if target.kind == .orionProfile {
                        Text(target.browserName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 10)

                if let shortcutNumber {
                    Text("⌘\(shortcutNumber)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .frame(height: 18)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                isSelected ? Color.primary.opacity(0.075) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .applyShortcut(shortcutNumber)
        .help(L("Open in %@", target.displayName))
        .accessibilityIdentifier("preview-browser-target-\(target.id)")
    }
}

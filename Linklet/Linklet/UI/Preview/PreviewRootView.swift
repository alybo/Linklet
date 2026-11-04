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
                    PreviewOpenInToolbarView(model: model, session: session)
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

struct PreviewOpenInToolbarView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var model: AppModel
    @ObservedObject var session: PreviewSession
    @State private var isPickerPresented = false
    @State private var isHovered = false

    private var targets: [BrowserTarget] {
        model.previewOpenTargets
    }

    var body: some View {
        Group {
            if !model.showsOpenInButton {
                pickerButton
                    .background(Color.primary.opacity(isHovered ? PreviewLayout.toolbarHoverOpacity : 0))
                    .clipShape(RoundedRectangle(cornerRadius: PreviewLayout.toolbarCornerRadius, style: .continuous))
                    .onHover { isHovered = $0 }
            } else if let preferredTarget = targets.first {
                HStack(spacing: 0) {
                    primaryButton(for: preferredTarget)

                    pickerButton
                }
                .frame(height: PreviewLayout.controlHeight)
                .background(Color.primary.opacity(isHovered ? PreviewLayout.toolbarHoverOpacity : 0))
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
        }.onChange(of: model.showsOpenInButton) { _ in isPickerPresented = false }
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
            isPickerPresented.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 27, height: PreviewLayout.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.showsOpenInButton && targets.count < 2)
        .help(L("Open browser menu"))
        .accessibilityLabel(L("Open browser menu"))
        .accessibilityIdentifier("preview-browser-menu")
        .popover(isPresented: $isPickerPresented, arrowEdge: .top) {
            if targets.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Button(L("Find browsers")) { isPickerPresented = false; model.refreshTargets() }
                    Button(L("Choose browsers")) { isPickerPresented = false; model.showSettings(page: .search) }
                }.buttonStyle(.plain).padding(12).frame(width: 220, alignment: .leading)
                    .accessibilityIdentifier("preview-browser-picker-empty")
            } else {
                BrowserTargetPicker(
                    targets: model.showsOpenInButton ? Array(targets.dropFirst()) : targets,
                    firstShortcutNumber: model.showsOpenInButton ? 2 : 1,
                    onOpen: { target in
                        isPickerPresented = false
                        model.openOriginalURL(in: target, session: session)
                    }
                )
            }
        }
    }
}

private struct BrowserTargetPicker: View {
    @ObservedObject private var language = AppLanguage.shared
    let targets: [BrowserTarget]
    let firstShortcutNumber: Int
    let onOpen: (BrowserTarget) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                BrowserTargetPickerRow(
                    target: target,
                    shortcutNumber: index + firstShortcutNumber <= 9 ? index + firstShortcutNumber : nil,
                    action: { onOpen(target) }
                )
            }
        }
        .padding(5)
        .frame(width: 280)
    }
}

private struct BrowserTargetPickerRow: View {
    @ObservedObject private var language = AppLanguage.shared
    let target: BrowserTarget
    let shortcutNumber: Int?
    let action: () -> Void

    @State private var isHovered = false

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
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(
                isHovered ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .applyShortcut(shortcutNumber)
        .help(L("Open in %@", target.displayName))
        .accessibilityIdentifier("preview-browser-target-\(target.id)")
    }
}

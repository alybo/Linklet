import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 680, height: 590)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        guard let window else { return }
        window.title = L("Welcome to Linklet")
        let host = NSHostingController(rootView: WelcomeView(model: model))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 760, height: 650))
        PreviewWindowAppearance.place(window, on: PreviewWindowAppearance.screenAtPointer)
        model.makeAppVisibleInDock()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.welcomeDidClose() }
}

enum WelcomeStep: Int, CaseIterable {
    case introduction, tutorial, setup, ready
}

struct WelcomeView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var model: AppModel
    @ObservedObject private var data: SiteDataService
    @Environment(\.colorScheme) private var colorScheme
    @State private var step: WelcomeStep
    @State private var confirmsDeletingData = false

    init(model: AppModel, initialStep: WelcomeStep = .introduction) {
        self.model = model
        data = model.siteData
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    switch step {
                    case .introduction: introduction
                    case .tutorial:
                        heading("Try it yourself", "This is a Linklet window. Try the highlighted controls.")
                        WelcomeTutorialView(model: model, close: { step = .setup })
                    case .setup: setup
                    case .ready: ready
                    }
                }
                .padding(.horizontal, 26).padding(.vertical, 20)
                .frame(maxWidth: 860).frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 14) {
                if step == .ready {
                    Spacer()
                    Button(L("Open Settings")) { model.showSettings(page: .general) }
                    Button(L("Open Quick Search"), action: model.openQuickSearch)
                    Button(L("Open Example Page")) {
                        model.showPreview(url: URL(string: "https://example.com/")!)
                    }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(L(step == .introduction ? "Skip" : "Back")) {
                        step = step == .introduction ? .setup : (step == .tutorial ? .introduction : .tutorial)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(0..<3) { index in
                            Capsule().fill(index == step.rawValue ? Color.accentColor : Color.secondary.opacity(0.28))
                                .frame(width: index == step.rawValue ? 17 : 6, height: 6)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("%d of %d", step.rawValue + 1, 3))
                    Spacer()
                    Button(L(step == .introduction ? "Try It" : step == .tutorial ? "Continue" : "Get Started")) {
                        step = WelcomeStep(rawValue: step.rawValue + 1) ?? .ready
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 26).padding(.vertical, 14)
            .background(.bar)
        }
        .background(colorScheme == .dark ? Color(red: 0.08, green: 0.10, blue: 0.14) : Color(red: 0.96, green: 0.97, blue: 0.99))
        .environment(\.locale, Locale(identifier: language.code))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker(L("Language"), selection: Binding(get: { language.selection }, set: model.setLanguage)) {
                    Text(L("Same as macOS")).tag("system")
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }.labelsHidden().fixedSize()
            }
        }
        .alert(L("Turn off saving and delete website data?"), isPresented: $confirmsDeletingData) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Turn off and delete"), role: .destructive) { Task { await model.setSavesSiteData(false) } }
        } message: {
            Text(L("The current preview will close. You may need to sign in again. This does not affect your other browsers."))
        }
        .onExitCommand {
            if step == .tutorial { step = .setup }
            else { model.closeWelcome() }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 54, height: 54)
                    .accessibilityHidden(true)
                heading("Welcome to Linklet", "Browse in a compact window alongside your work.")
            }
            WelcomeArtwork(.preview, height: 236) {
                WelcomeInterfaceIllustration()
            }
            HStack(alignment: .top, spacing: 12) {
                feature("macwindow", .preview, "Links alongside your work", "Pages open in a compact window.")
                feature("magnifyingglass", .search, "Search and bookmarks", "Search, save, and return to what matters.")
                feature("arrow.up.forward.app", .setup, "Another browser", "Open the original link in your chosen browser.")
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Start using Linklet", "You can change these settings later.")
            WelcomeArtwork(.setup, height: 150) {
                WelcomeSymbolIllustration(primary: "lock.shield", leading: "link", trailing: "safari")
            }
            VStack(alignment: .leading, spacing: 0) {
                DefaultBrowserSetting(model: model)
                    .labeledContentStyle(WelcomeSettingsRowStyle())
                    .padding(16)
                Divider().padding(.horizontal, 16)
                LabeledContent {
                    Toggle(L("Save website data"), isOn: Binding(get: { data.isEnabled }, set: { enabled in
                        if enabled { Task { await model.setSavesSiteData(true) } }
                        else { confirmsDeletingData = true }
                    }))
                    .labelsHidden().toggleStyle(.switch).disabled(data.isBusy)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Save website data"))
                        Text(L("Stay signed in and keep website preferences.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .labeledContentStyle(WelcomeSettingsRowStyle())
                .padding(16)
            }
            .welcomeCard()
            Text(L(data.isEnabled
                ? "Website data is stored on this Mac. History has a separate setting."
                : "Website data is temporary. History has a separate setting."))
                .font(.caption).foregroundStyle(.secondary)
            Label(L("Find settings and this introduction in the Linklet menu bar icon."), systemImage: "menubar.arrow.up.rectangle")
                .font(.callout).foregroundStyle(.secondary)
            if let message = model.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("You're ready", "Open an example page or find a website with Quick Search.")
            WelcomeArtwork(.search, height: 212) {
                WelcomeSymbolIllustration(primary: "checkmark", leading: "macwindow", trailing: "magnifyingglass")
            }
            if model.linkLibrary.isEnabled {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.blue)
                        .frame(width: 32, height: 32)
                        .background(Color.blue.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Sidebar")).font(.callout.weight(.semibold))
                        Text(L("Move the pointer to the left edge of the screen for open windows, bookmarks, history, and downloads."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16).welcomeCard()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(title)).font(.system(size: 31, weight: .bold)).tracking(-0.8)
                .accessibilityAddTraits(.isHeader)
            Text(L(subtitle)).font(.system(size: 14)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func feature(_ symbol: String, _ tone: WelcomeTone, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone.iconColor)
                .frame(width: 32, height: 32)
                .background(tone.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            Text(L(title)).font(.system(size: 13, weight: .semibold))
            Text(L(detail)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .padding(12).welcomeCard()
    }
}

private struct WelcomeSettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 18) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            configuration.content
        }
    }
}

/// Uses the real native address control without a WKWebView. The sample never
/// visits the network, records history, changes bookmarks, or launches a browser.
struct WelcomeTutorialView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var model: AppModel
    let close: () -> Void
    @StateObject private var session: PreviewSession
    @State private var feedback = "Click the address control or press ⌘L."

    init(model: AppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _session = StateObject(wrappedValue: PreviewSession(
            adBlockService: model.adBlockService,
            siteData: SiteDataService(defaults: UserDefaults(suiteName: "Linklet.Onboarding.Sample")!,
                                      persistentStore: .nonPersistent())))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                HStack(spacing: PreviewLayout.toolbarItemSpacing) {
                    WindowControlButton(imageName: "PreviewClose", help: L("Close preview"), action: { _ in close() })
                    PreviewLocationView(session: session, title: L("Sample page"), isToolbarHovered: true, highlightsAddress: true) { _ in
                        feedback = "Enter a website address or a search query."
                        return true
                    }
                    Button {
                        feedback = "The other browser opens the original link. Sign-ins and page state are not transferred."
                    } label: {
                        HStack(spacing: 7) {
                            if model.showsOpenInButton, let target = model.preferredTarget {
                                Image(nsImage: TargetIconCache.shared.icon(for: target.applicationURL))
                                    .resizable().scaledToFit().frame(width: 14, height: 14)
                                Text(L("Open in %@", target.displayName)).lineLimit(1)
                            } else if model.showsOpenInButton {
                                Label(L("Choose browser"), systemImage: "safari")
                            }
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, model.showsOpenInButton ? 10 : 0)
                        .frame(width: model.showsOpenInButton ? nil : 27, height: PreviewLayout.controlHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Open browser menu"))
                    .overlay(RoundedRectangle(cornerRadius: PreviewLayout.toolbarCornerRadius).strokeBorder(Color.accentColor, lineWidth: 1.5))
                }
                .padding(.horizontal, 10).frame(height: PreviewLayout.topBarHeight)
                .background { PreviewWindowMaterial() }

                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 9) {
                        Image(systemName: "globe").font(.system(size: 19, weight: .medium)).foregroundStyle(Color.accentColor)
                        Text(L("Your first page")).font(.system(size: 24, weight: .semibold))
                        Text(L("Read, search, and save links. Keep browsing here or in another browser."))
                            .font(.callout).foregroundStyle(.secondary)
                        Text("example.com").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    WelcomeMiniCover()
                        .frame(width: 235, height: 126)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(Color.primary.opacity(0.12)).allowsHitTesting(false) }

            HStack(alignment: .top, spacing: 12) {
                coach("magnifyingglass", "Address and search", "Click the address control to enter a link or search query.")
                coach("arrow.up.forward.app", "Another browser", "Choose a browser from the arrow menu to open the original link.")
            }

            Label(L(feedback), systemImage: "lightbulb")
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .onAppear { session.load(URL(string: "https://example.com")!) }
        .onDisappear { session.endSession() }
    }

    private func coach(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(L(title)).font(.callout.weight(.semibold))
                Text(L(detail)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .padding(12).welcomeCard()
    }
}

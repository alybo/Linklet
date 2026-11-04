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
        window.center()
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
                VStack(spacing: 24) {
                    switch step {
                    case .introduction: introduction
                    case .tutorial:
                        heading("Try it yourself", "This is a Linklet window. Try the highlighted controls.")
                        WelcomeTutorialView(model: model, close: { step = .setup })
                    case .setup: setup
                    case .ready: ready
                    }
                }
                .padding(32).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 16) {
                if step == .ready {
                    Spacer()
                    Button(L("Open Settings")) { model.showSettings(page: .general) }
                    Button(L("Open Quick Search"), action: model.openQuickSearch)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(L(step == .introduction ? "Skip" : "Back")) {
                        step = step == .introduction ? .setup : (step == .tutorial ? .introduction : .tutorial)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(0..<3) { index in
                            Circle().fill(index == step.rawValue ? Color.secondary : Color.secondary.opacity(0.25))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("%d of %d", step.rawValue + 1, 3))
                    Spacer()
                    Button(L(step == .introduction ? "Try It" : step == .tutorial ? "Continue" : "Get Started")) {
                        step = WelcomeStep(rawValue: step.rawValue + 1) ?? .ready
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }.padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
        VStack(spacing: 22) {
            appIcon
            heading("Welcome to Linklet", "Open links without losing context.")
            VStack(alignment: .leading, spacing: 22) {
                feature("macwindow", "Links alongside your work", "Pages open in a compact window.")
                feature("magnifyingglass", "Search and bookmarks", "Search, save, and return to what matters.")
                feature("arrow.up.forward.app", "Your other browsers, within reach", "Open the original link in your chosen browser.")
            }.frame(maxWidth: 440).padding(.vertical, 12)
            Text(L("You can skip the introduction.")).font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 8)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Start using Linklet", "You can change these settings later.")
                .frame(maxWidth: .infinity)
            GroupBox { DefaultBrowserSetting(model: model).padding(12) }
            GroupBox {
                Toggle(isOn: Binding(get: { data.isEnabled }, set: { enabled in
                    if enabled { Task { await model.setSavesSiteData(true) } }
                    else { confirmsDeletingData = true }
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Save website data"))
                        Text(L("Stay signed in and keep website preferences.")).font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).padding(12).disabled(data.isBusy)
            }
            Text(L(data.isEnabled
                ? "Website data is stored on this Mac. History has a separate setting."
                : "Website data is temporary. History has a separate setting."))
                .font(.caption).foregroundStyle(.secondary)
            Label(L("Find settings and this introduction in the Linklet menu bar icon."), systemImage: "menubar.arrow.up.rectangle")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 12)
            if let message = model.statusMessage { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(.top, 18)
    }

    private var ready: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle").font(.system(size: 54, weight: .light)).foregroundStyle(.secondary)
            heading("You're ready", "Start with Quick Search or customize Linklet.")
            if !model.isDefaultBrowser {
                Text(L("To open links automatically, make Linklet your default browser in settings."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 70)
    }

    private var appIcon: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage).resizable().scaledToFit().frame(width: 76, height: 76)
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(L(title)).font(.title.bold())
            Text(L(subtitle)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(L(title)).fontWeight(.medium)
                Text(L(detail)).font(.callout).foregroundStyle(.secondary)
            }
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                HStack(spacing: PreviewLayout.toolbarItemSpacing) {
                    WindowControlButton(imageName: "PreviewClose", help: L("Close preview"), action: close)
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
                            } else if model.showsOpenInButton { Label(L("Choose browser"), systemImage: "safari") }
                            Image(systemName: "chevron.down").font(.caption2)
                        }.font(.system(size: 11.5, weight: .medium)).padding(.horizontal, model.showsOpenInButton ? 10 : 0)
                            .frame(width: model.showsOpenInButton ? nil : 27, height: PreviewLayout.controlHeight)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(L("Open browser menu"))
                        .overlay(RoundedRectangle(cornerRadius: PreviewLayout.toolbarCornerRadius).stroke(Color.accentColor, lineWidth: 2))
                        .anchorPreference(key: PreviewControlAnchors.self, value: .bounds) { ["browser": $0] }
                }
                .padding(.horizontal, 10).frame(height: PreviewLayout.topBarHeight)
                .background { PreviewWindowMaterial() }
                VStack(spacing: 24) {
                    HStack(alignment: .top, spacing: 24) {
                        coach("Address and search", "Click the address control to enter a link or search query.")
                            .anchorPreference(key: PreviewControlAnchors.self, value: .bounds) { ["addressHint": $0] }
                        coach("Another browser", "Choose a browser from the arrow menu to open the original link.")
                            .anchorPreference(key: PreviewControlAnchors.self, value: .bounds) { ["browserHint": $0] }
                    }
                    VStack(spacing: 12) {
                        Image(systemName: "globe").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                        Text(L("Your first page")).font(.title3.weight(.medium))
                        Text(L("Read, search, and save links. Keep browsing here or in another browser."))
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text("example.com").font(.caption).foregroundStyle(.tertiary)
                    }.padding(.bottom, 20)
                }.padding(16).frame(maxWidth: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
            Label(L(feedback), systemImage: "lightbulb").font(.callout).foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .overlayPreferenceValue(PreviewControlAnchors.self) { anchors in
            GeometryReader { geometry in
                Path { path in
                    for key in ["address", "browser"] {
                        if let control = anchors[key], let hint = anchors[key + "Hint"] {
                            let target = geometry[control], label = geometry[hint]
                            let point = CGPoint(x: target.midX, y: target.maxY + 4)
                            path.move(to: CGPoint(x: label.midX, y: label.minY + 16))
                            path.addLine(to: CGPoint(x: point.x, y: point.y + 8))
                            path.addLine(to: point)
                            path.move(to: CGPoint(x: point.x - 4, y: point.y + 5))
                            path.addLine(to: point)
                            path.addLine(to: CGPoint(x: point.x + 4, y: point.y + 5))
                        }
                    }
                }.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .onAppear { session.load(URL(string: "https://example.com")!) }
        .onDisappear { session.endSession() }
    }

    private func coach(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.frame(height: 16)
            Text(L(title)).font(.callout.weight(.medium))
            Text(L(detail)).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

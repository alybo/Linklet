import AppKit
import SwiftUI

enum PreviewLayout {
    // Keep the native macOS control target, while drawing compact symbols inside it.
    static let topBarHeight: CGFloat = 36
    static let controlHeight: CGFloat = 28
    static let contentInset: CGFloat = 6
    static let contentCornerRadius: CGFloat = 12
    static let windowControlSymbolSize: CGFloat = 14
    static let windowControlHitSize: CGFloat = 24
}

struct PreviewRootView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var model: AppModel
    @ObservedObject private var session: PreviewSession

    init(model: AppModel) {
        self.model = model
        self.session = model.previewSession
    }

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
        .ignoresSafeArea(.container, edges: .all)
        .alert(
            L("Couldn't open the page"),
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            )
        ) {
            Button(L("OK"), role: .cancel) { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? L("Unknown error"))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            PreviewWindowControls(session: session)

            Text(siteTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(session.currentURL?.absoluteString ?? siteTitle)

            Spacer(minLength: 12)

            if !session.isWelcome && session.isActive {
                PreviewCopyToolbarView(session: session)
                PreviewOpenInToolbarView(model: model)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var webContent: some View {
        ZStack(alignment: .top) {
            if session.isActive {
                WebPreview(session: session)
                    .id(session.navigationID)
                    .background(Color(nsColor: .textBackgroundColor))
            } else {
                Color(nsColor: .windowBackgroundColor)
            }

            if model.isChoosingDataMode {
                SiteDataChoiceView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isPreparingPreview {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if session.isPreparingNewPage {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PreviewLayout.contentCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PreviewLayout.contentCornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.72), lineWidth: 1)
                .allowsHitTesting(false)
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

private struct PreviewWindowMaterial: NSViewRepresentable {
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

private struct WindowControlButton: View {
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

struct PreviewCopyToolbarView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var session: PreviewSession
    @State private var didCopyURL = false
    @State private var isHovered = false

    var body: some View {
        Button(action: copyCurrentURL) {
            Image(systemName: didCopyURL ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: PreviewLayout.controlHeight, height: PreviewLayout.controlHeight)
                .background {
                    Circle()
                        .fill(Color.primary.opacity(isHovered ? 0.09 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(didCopyURL ? Color.green : Color.primary)
        .help(didCopyURL ? L("Copied") : L("Copy current URL"))
        .disabled(session.currentURL == nil)
        .onHover { isHovered = $0 }
    }

    private func copyCurrentURL() {
        guard let url = session.currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)

        withAnimation(.easeOut(duration: 0.14)) {
            didCopyURL = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeIn(duration: 0.14)) {
                didCopyURL = false
            }
        }
    }
}

struct PreviewOpenInToolbarView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var model: AppModel
    @State private var isPickerPresented = false
    @State private var isPrimaryHovered = false
    @State private var isChevronHovered = false

    private var targets: [BrowserTarget] {
        model.previewOpenTargets
    }

    var body: some View {
        if let preferredTarget = targets.first {
            HStack(spacing: 0) {
                primaryButton(for: preferredTarget)

                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1, height: 16)

                pickerButton
            }
            .frame(height: PreviewLayout.controlHeight)
            .background(Color.primary.opacity(0.075))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
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

    private func primaryButton(for target: BrowserTarget) -> some View {
        Button {
            model.openOriginalURL(in: target)
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
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .frame(height: PreviewLayout.controlHeight)
            .background(Color.primary.opacity(isPrimaryHovered ? 0.07 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("1", modifiers: .command)
        .help(L("Open in %@", target.displayName) + " — ⌘1")
        .onHover { isPrimaryHovered = $0 }
    }

    private var pickerButton: some View {
        Button {
            isPickerPresented.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 27, height: PreviewLayout.controlHeight)
                .background(Color.primary.opacity(isChevronHovered ? 0.07 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(targets.count < 2)
        .help(targets.count < 2 ? L("No other browsers") : L("Choose another browser"))
        .onHover { isChevronHovered = $0 }
        .popover(isPresented: $isPickerPresented, arrowEdge: .top) {
            BrowserTargetPicker(
                targets: Array(targets.dropFirst()),
                onOpen: { target in
                    isPickerPresented = false
                    model.openOriginalURL(in: target)
                }
            )
        }
    }
}

private struct BrowserTargetPicker: View {
    @ObservedObject private var language = AppLanguage.shared
    let targets: [BrowserTarget]
    let onOpen: (BrowserTarget) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                BrowserTargetPickerRow(
                    target: target,
                    shortcutNumber: index < 8 ? index + 2 : nil,
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
    }
}


private struct SiteDataChoiceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var language = AppLanguage.shared
    @State private var savesData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Keep website sign-ins?")).font(.title2.bold())
                Text(L("Choose how Linklet handles website data."))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                option(false, title: "Without saving", detail: "For quick link previews. Website data is deleted when the window closes. You will need to sign in again the next time you open websites.")
                option(true, title: "With saving", detail: "For websites you use regularly. Linklet remembers sign-ins and website preferences. Data stays on this Mac; you can delete it manually or set up automatic cleanup.")
            }
            Text(L("This choice applies to all websites in Linklet."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(L("Settings…"), action: model.openDataSettingsFromChoice)
                Spacer()
                Button(L("Continue")) { model.completeDataChoice(save: savesData) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(maxWidth: 560)
    }

    private func option(_ value: Bool, title: String, detail: String) -> some View {
        Button { savesData = value } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: savesData == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(savesData == value ? Color.accentColor : .secondary)
                    .font(.system(size: 17))
                VStack(alignment: .leading, spacing: 6) {
                    Text(L(title)).font(.headline)
                    Text(L(detail)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(savesData == value ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L(title))
        .accessibilityValue(savesData == value ? L("Selected") : L("Not selected"))
        .accessibilityHint(L(detail))
    }
}

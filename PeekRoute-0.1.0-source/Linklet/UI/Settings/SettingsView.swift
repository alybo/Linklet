import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    GroupBox(L("Language")) {
                        Picker(L("Language"), selection: Binding(
                            get: { language.selection },
                            set: model.setLanguage
                        )) {
                            Text(L("System language")).tag("system")
                            Text("Русский").tag("ru")
                            Text("English").tag("en")
                        }
                        .padding(8)
                    }
                    defaultBrowserSection
                    Toggle(L("Enable AdGuard ad blocker"), isOn: Binding(
                        get: { model.isAdBlockingEnabled },
                        set: model.setAdBlockingEnabled
                    ))
                    .toggleStyle(.switch)
                    previewSection
                    browserShelfSection
                    performanceSection
                }
                .padding(28)
            }

            Divider()

            HStack {
                if let statusMessage = model.statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button(L("Welcome to Linklet")) {
                    model.showWelcome()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .onAppear(perform: model.refreshTargets)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 42, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("Linklet")
                    .font(.largeTitle.bold())
                Text(L("Preview first. Choose the right browser second."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var defaultBrowserSection: some View {
        GroupBox(L("Default link handler")) {
            HStack {
                Image(systemName: model.isDefaultBrowser ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.isDefaultBrowser ? .green : .secondary)
                Text(model.isDefaultBrowser
                     ? L("Linklet handles web links on this Mac.")
                     : L("Set Linklet as the default browser to preview external links."))
                Spacer()
                Button(L("Make Linklet Default Browser")) {
                    model.makeDefaultBrowser()
                }
                .disabled(model.isDefaultBrowser)
            }
            .padding(8)
        }
    }

    private var previewSection: some View {
        GroupBox(L("Preview window")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("When switching apps"))
                Picker(L("When switching apps"), selection: Binding(
                    get: { model.previewWindowBehavior },
                    set: model.setPreviewWindowBehavior
                )) {
                    ForEach(PreviewWindowBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                // Recreate native segments when language changes; their labels can be cached.
                .id(language.code)
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(model.previewWindowBehavior.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var browserShelfSection: some View {
        GroupBox(L("Browsers")) {
            VStack(alignment: .leading, spacing: 14) {
                settingToggle(
                    L("Sort browsers by usage"),
                    detail: L("The most-used browser becomes the primary Open in action; the others follow in the menu."),
                    isOn: Binding(
                        get: { model.sortsTargetsByUsage },
                        set: model.setSortTargetsByUsage
                    )
                )

                Divider()

                HStack {
                    Text(L("Shown browsers"))
                        .font(.headline)
                    Text(L("%d of %d", model.visibleTargets.count, model.targets.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Reset usage")) { model.resetTargetUsage() }
                        .disabled(model.targets.allSatisfy { model.targetUsageCount($0) == 0 })
                    Button(L("Refresh")) { model.refreshTargets() }
                }

                if model.targets.isEmpty {
                    Text(L("No compatible browsers or Orion profile apps were found."))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.targets.enumerated()), id: \.element.id) { index, target in
                            browserVisibilityRow(target)
                            if index < model.targets.count - 1 {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var performanceSection: some View {
        GroupBox(L("Performance")) {
            settingToggle(
                L("Launch Linklet when I sign in"),
                detail: L("Keeps the lightweight menu bar process ready and reuses the same preview window."),
                isOn: Binding(
                    get: { model.isLaunchAtLoginEnabled },
                    set: model.setLaunchAtLogin
                )
            )
            .padding(8)
        }
    }

    private func settingToggle(
        _ title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    private func browserVisibilityRow(_ target: BrowserTarget) -> some View {
        Toggle(
            isOn: Binding(
                get: { model.isTargetVisible(target) },
                set: { model.setTargetVisible(target, isVisible: $0) }
            )
        ) {
            HStack(spacing: 10) {
                Image(nsImage: TargetIconCache.shared.icon(for: target.applicationURL))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(target.displayName)
                        .lineLimit(1)
                    Text(target.secondaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                let usageCount = model.targetUsageCount(target)
                if usageCount > 0 {
                    Text(L("Used %d×", usageCount))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 7)
    }
}

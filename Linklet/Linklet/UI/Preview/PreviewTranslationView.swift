import SwiftUI
import Translation

/// Kept in the page window independently of the drawer: closing its controls
/// must not discard an active translation or cancel a model download.
struct PageTranslationEngine: View {
    @ObservedObject var controller: PageTranslationController
    var body: some View {
        if #available(macOS 15, *), controller.usesAppleEngine, let request = controller.request {
            AppleTranslationJob(controller: controller, request: request).id(request)
        }
    }
}

@available(macOS 15, *)
private struct AppleTranslationJob: View {
    @ObservedObject var controller: PageTranslationController
    let request: UUID
    @State private var activeSession: TranslationSession?

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(source: Locale.Language(identifier: controller.requestedSource),
                             target: Locale.Language(identifier: controller.requestedTarget)) { session in
                activeSession = session
                defer { activeSession = nil }
                do {
                    try await session.prepareTranslation()
                    try Task.checkCancellation()
                    guard controller.request == request else { return }
                    await controller.performTranslation { texts in
                        let requests = texts.enumerated().map {
                            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                        }
                        let responses = try await session.translations(from: requests)
                        let values = Dictionary(responses.compactMap { response -> (Int, String)? in
                            guard let id = response.clientIdentifier.flatMap(Int.init) else { return nil }
                            return (id, response.targetText)
                        }, uniquingKeysWith: { first, _ in first })
                        return texts.indices.compactMap { values[$0] }
                    }
                } catch {
                    controller.translationFailed(error, request: request)
                }
            }
            .onDisappear {
                if #available(macOS 26, *) { activeSession?.cancel() }
            }
    }
}

struct PreviewTranslationDrawer: View {
    @ObservedObject var controller: PageTranslationController
    @ObservedObject private var language = AppLanguage.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BrowserDrawerHost(isPresented: controller.isPresented, content: AnyView(
            content
                .modifier(BrowserDrawerSlide(progress: controller.isPresented ? 1 : 0))
                .clipped()
                .animation(reduceMotion ? nil : .easeOut(duration: BrowserDrawerLayout.animationDuration), value: controller.isPresented)
                .allowsHitTesting(controller.isPresented)
                .disabled(!controller.isPresented)
                .accessibilityHidden(!controller.isPresented)
        )).fixedSize().padding(.top, PreviewLayout.topBarHeight)
    }

    private func languagePicker(source: Bool) -> some View {
        let value = source ? controller.source : controller.target
        let title = value == "auto" ? L("Detect automatically") : (value.isEmpty ? L("Loading languages…") : controller.languageName(value))
        let choices = (source ? [TranslationLanguageChoice(id: "auto", title: L("Detect automatically"))] : [])
            + controller.languages.map { TranslationLanguageChoice(id: $0, title: controller.languageName($0)) }
        return TranslationLanguagePicker(title: title, caption: L(source ? "From language" : "To language"),
            value: value, choices: choices, choose: source ? controller.setSource : controller.setTarget)
            .accessibilityIdentifier(source ? "preview-translation-source" : "preview-translation-target")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Translate page")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { controller.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22)
                }.buttonStyle(.plain).help(L("Close translation"))
                    .accessibilityIdentifier("preview-translation-close")
            }
            if !controller.isSupported {
                Text(L("Page translation requires macOS 15 or later.")).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("From language")).font(.system(size: 10)).foregroundStyle(.secondary)
                    languagePicker(source: true)
                    if controller.source == "auto", let detected = controller.detectedSource {
                        Text(L("Detected: %@", controller.languageName(detected))).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("To language")).font(.system(size: 10)).foregroundStyle(.secondary)
                    languagePicker(source: false)
                }
                if controller.requiresAppleIntelligence {
                    Text(L("This language pair requires Apple Intelligence."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = controller.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("preview-translation-error")
                }
                if controller.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("Translating…")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Button {
                    if controller.error != nil, !controller.isBusy { controller.requestTranslation() }
                    else { controller.restoreOriginal() }
                } label: {
                    Text(L(controller.isBusy ? "Cancel" : (controller.error != nil ? "Translation failed" : "Show original")))
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .background(Color.primary.opacity(0.88), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
                    .help(controller.error != nil ? L("Retry translation") : L("Show original"))
                    .accessibilityIdentifier("preview-translation-action")
            }
        }
        .padding(14).frame(width: 258)
        .fixedSize(horizontal: false, vertical: true)
        .background { PreviewWindowMaterial(state: .active) }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
        .accessibilityElement(children: .contain).accessibilityIdentifier("preview-translation-panel")
    }
}

private struct TranslationLanguageChoice: Identifiable {
    let id: String
    let title: String
}

private struct TranslationLanguagePicker: View {
    let title: String
    let caption: String
    let value: String
    let choices: [TranslationLanguageChoice]
    let choose: (String) -> Void
    @State private var isOpen = false
    @State private var query = ""

    private var filtered: [TranslationLanguageChoice] {
        query.isEmpty ? choices : choices.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        Button { query = ""; isOpen.toggle() } label: {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7) }
        }
        .buttonStyle(.plain).accessibilityLabel(caption).accessibilityValue(title)
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(spacing: 6) {
                TextField(L("Find a language"), text: $query).textFieldStyle(.roundedBorder).padding(4)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filtered) { language in
                            Button {
                                choose(language.id); isOpen = false
                            } label: {
                                HStack {
                                    Text(language.title).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    if language.id == value { Image(systemName: "checkmark").font(.system(size: 10)) }
                                }.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: min(300, CGFloat(max(1, filtered.count)) * 30))
            }.padding(6).frame(width: 250)
        }
    }
}

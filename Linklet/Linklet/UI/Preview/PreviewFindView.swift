import AppKit
import Combine
import SwiftUI
import WebKit

/// Per-page state. WebKit owns matching, frame traversal, highlights and scrolling;
/// no script rewrites the page or its editable fields.
@MainActor
final class PageFindController: NSObject, ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var query = ""
    @Published private(set) var matchCount: Int?
    @Published private(set) var matchIndex: Int?
    @Published private(set) var isSearching = false
    @Published private(set) var focusRequest = UUID()
    private(set) var usesNativeMatchCounts = false
    private weak var webView: WKWebView?
    private var pendingSearch: Task<Void, Never>?
    private var navigationInProgress = false
    private var generation = UUID()
    private var countIsLimited = false
    private let allowsNativeMatchCounts: Bool
    private static let matchLimit: UInt = 10_000
    private static let findSelector = NSSelectorFromString("_findString:options:maxCount:")
    private static let delegateSelector = NSSelectorFromString("_setFindDelegate:")
    private static let hideSelector = NSSelectorFromString("_hideFindUI")

    init(allowsNativeMatchCounts: Bool = true) {
        self.allowsNativeMatchCounts = allowsNativeMatchCounts
        super.init()
    }

    var counterText: String {
        if query.isEmpty { return "" }
        if isSearching { return "…" }
        guard let matchCount else { return L("Found") }
        if countIsLimited { return L("%d+ matches", matchCount) }
        return L("%d of %d", matchCount == 0 ? 0 : (matchIndex ?? 0) + 1, matchCount)
    }

    func attach(_ view: WKWebView) {
        if webView === view { return }
        detach()
        webView = view
        // Public WKFindResult only exposes a Bool. Isolate the optional native
        // delegate used by WebKit's own MiniBrowser for counts and all highlights.
        // A future WebKit without this SPI keeps public find/next/previous working.
        usesNativeMatchCounts = allowsNativeMatchCounts && [Self.findSelector, Self.delegateSelector, Self.hideSelector]
            .allSatisfy { view.responds(to: $0) }
    }

    func detach() {
        close(returnFocus: false)
        if usesNativeMatchCounts { _ = webView?.perform(Self.delegateSelector, with: nil) }
        webView = nil
        query = ""
        usesNativeMatchCounts = false
        navigationInProgress = false
    }

    func show() {
        guard webView != nil else { return }
        if !isPresented {
            isPresented = true
            scheduleSearch()
        }
        focusRequest = UUID()
    }

    func close(returnFocus: Bool = true) {
        pendingSearch?.cancel()
        pendingSearch = nil
        generation = UUID()
        isPresented = false
        isSearching = false
        matchCount = nil
        matchIndex = nil
        hideHighlights()
        if returnFocus, let webView, webView.window?.isKeyWindow == true {
            webView.window?.makeFirstResponder(webView)
        }
    }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        scheduleSearch()
    }

    func navigate(backwards: Bool = false) {
        guard isPresented, !query.isEmpty, !navigationInProgress else { return }
        pendingSearch?.cancel()
        pendingSearch = nil
        runSearch(backwards: backwards)
    }

    func navigationStarted() {
        navigationInProgress = true
        pendingSearch?.cancel()
        generation = UUID()
        matchCount = nil
        matchIndex = nil
        isSearching = isPresented && !query.isEmpty
        hideHighlights()
    }

    func navigationFinished() {
        navigationInProgress = false
        if isPresented { scheduleSearch() }
    }

    private func scheduleSearch() {
        pendingSearch?.cancel()
        generation = UUID()
        matchCount = nil
        matchIndex = nil
        countIsLimited = false
        hideHighlights()
        isSearching = isPresented && !query.isEmpty
        guard isSearching, !navigationInProgress else { return }
        pendingSearch = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.runSearch(backwards: false)
        }
    }

    private func runSearch(backwards: Bool) {
        guard let webView, isPresented, !query.isEmpty, !navigationInProgress else { return }
        isSearching = true
        if usesNativeMatchCounts {
            _ = webView.perform(Self.delegateSelector, with: self)
            // Case-insensitive, wrap, native selected indicator, all highlights,
            // and a match index. Deliberately omit the page-dimming overlay.
            let options: UInt = 1 | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 9) | (backwards ? 1 << 3 : 0)
            typealias Find = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
            let find = unsafeBitCast(webView.method(for: Self.findSelector), to: Find.self)
            find(webView, Self.findSelector, query as NSString, options, Self.matchLimit)
        } else {
            let requestGeneration = generation
            let searchedQuery = query
            let configuration = WKFindConfiguration()
            configuration.caseSensitive = false
            configuration.wraps = true
            configuration.backwards = backwards
            webView.find(query, configuration: configuration) { [weak self, weak webView] result in
                guard let self, self.webView === webView, isPresented,
                      generation == requestGeneration, query == searchedQuery, !navigationInProgress else { return }
                isSearching = false
                matchCount = result.matchFound ? nil : 0
            }
        }
    }

    private func hideHighlights() {
        guard let webView else { return }
        if usesNativeMatchCounts { _ = webView.perform(Self.hideSelector) }
        else { webView.find("", configuration: WKFindConfiguration()) { _ in } }
    }

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func didFind(_ view: WKWebView, matches: UInt, string: String, index: Int) {
        guard view === webView else { return }
        guard isPresented, !navigationInProgress, string == query else {
            if !isPresented || navigationInProgress { hideHighlights() }
            return
        }
        isSearching = false
        countIsLimited = matches >= Self.matchLimit
        matchCount = Int(min(matches, Self.matchLimit))
        matchIndex = max(0, index)
    }

    @objc(_webView:didFailToFindString:)
    func didFail(_ view: WKWebView, string: String) {
        guard view === webView, isPresented, !navigationInProgress, string == query else { return }
        isSearching = false
        matchCount = 0
        matchIndex = nil
    }
}

struct PreviewFindOverlay: View {
    @ObservedObject var controller: PageFindController
    @ObservedObject private var language = AppLanguage.shared

    var body: some View {
        PreviewFindPanel(controller: controller)
            .frame(width: 340, height: 38)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .padding(10)
            .opacity(controller.isPresented ? 1 : 0)
            .allowsHitTesting(controller.isPresented)
            .accessibilityHidden(!controller.isPresented)
    }
}

private struct PreviewFindPanel: NSViewRepresentable {
    let controller: PageFindController
    func makeNSView(context: Context) -> PreviewFindControlView { PreviewFindControlView(controller: controller) }
    func updateNSView(_ view: PreviewFindControlView, context: Context) { view.update() }
    static func dismantleNSView(_ view: PreviewFindControlView, coordinator: ()) { view.stopObserving() }
}

@MainActor
final class PreviewFindControlView: NSView, NSSearchFieldDelegate {
    override var mouseDownCanMoveWindow: Bool { false }
    let controller: PageFindController
    let searchField = NSSearchField()
    let counter = NSTextField(labelWithString: "")
    let previousButton = NSButton()
    let nextButton = NSButton()
    let closeButton = NSButton()
    private var eventMonitor: Any?
    private var observations = Set<AnyCancellable>()
    private var lastFocusRequest: UUID?

    init(controller: PageFindController) {
        self.controller = controller
        super.init(frame: .zero)
        setAccessibilityIdentifier("preview-find-panel")
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 12)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.recentsAutosaveName = nil
        searchField.maximumRecents = 0
        searchField.setAccessibilityIdentifier("preview-find-query")
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .center
        counter.setAccessibilityIdentifier("preview-find-count")
        for (button, image, action) in [
            (previousButton, "chevron.up", #selector(previous)),
            (nextButton, "chevron.down", #selector(next)),
            (closeButton, "xmark", #selector(closeFind))
        ] {
            button.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.target = self
            button.action = action
        }
        [searchField, counter, previousButton, nextButton, closeButton].forEach { addSubview($0) }
        // Read published values after the mutation, never during objectWillChange.
        controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.update() }
        }.store(in: &observations)
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let buttonWidth: CGFloat = 25
        closeButton.frame = NSRect(x: bounds.width - 30, y: 5, width: buttonWidth, height: 28)
        nextButton.frame = closeButton.frame.offsetBy(dx: -buttonWidth, dy: 0)
        previousButton.frame = nextButton.frame.offsetBy(dx: -buttonWidth, dy: 0)
        let counterWidth = min(110, max(50, ceil((counter.stringValue as NSString)
            .size(withAttributes: [.font: counter.font!]).width) + 4))
        counter.frame = NSRect(x: previousButton.frame.minX - counterWidth - 3, y: 11, width: counterWidth, height: 16)
        searchField.frame = NSRect(x: 7, y: 7, width: max(60, counter.frame.minX - 11), height: 24)
    }

    func update() {
        isHidden = !controller.isPresented
        if searchField.currentEditor() == nil, searchField.stringValue != controller.query {
            searchField.stringValue = controller.query
        }
        searchField.placeholderString = L("Find on page")
        searchField.setAccessibilityLabel(L("Find on page"))
        if counter.stringValue != controller.counterText {
            counter.stringValue = controller.counterText
            needsLayout = true
            NSAccessibility.post(element: counter, notification: .valueChanged)
        }
        counter.setAccessibilityLabel(controller.matchCount == 0 ? L("No matches") : controller.counterText)
        previousButton.toolTip = L("Previous match") + " — ⇧Enter"
        nextButton.toolTip = L("Next match") + " — Enter"
        closeButton.toolTip = L("Close search") + " — Esc"
        previousButton.setAccessibilityLabel(L("Previous match"))
        nextButton.setAccessibilityLabel(L("Next match"))
        closeButton.setAccessibilityLabel(L("Close search"))
        let canNavigate = !controller.query.isEmpty && !controller.isSearching && controller.matchCount != 0
        previousButton.isEnabled = canNavigate
        nextButton.isEnabled = canNavigate
        if controller.isPresented, window?.isKeyWindow == true, lastFocusRequest != controller.focusRequest {
            lastFocusRequest = controller.focusRequest
            searchField.selectText(nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return handle(event) ? nil : event
        }
        update()
    }

    func stopObserving() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    func handle(_ event: NSEvent) -> Bool {
        guard event.window === window, window?.isKeyWindow == true, event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 3, modifiers == .command { // Physical F, also in Russian layouts.
            controller.show()
            return true
        }
        if event.keyCode == 5, modifiers == .command || modifiers == [.command, .shift] {
            controller.show()
            controller.navigate(backwards: modifiers.contains(.shift))
            return true
        }
        guard controller.isPresented else { return false }
        if event.keyCode == 53, modifiers.isEmpty {
            if (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return false }
            // Another native editor (for example, the expanded address) owns Esc.
            if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
               searchField.currentEditor() !== editor { return false }
            controller.close()
            return true
        }
        if [36,76].contains(event.keyCode), modifiers.isEmpty || modifiers == .shift,
           searchField.currentEditor() != nil {
            if (searchField.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
            controller.navigate(backwards: modifiers.contains(.shift))
            return true
        }
        return false
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        controller.setQuery(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() {
            controller.close(); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() {
            controller.navigate(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        }
        return false
    }

    @objc private func previous() { controller.navigate(backwards: true) }
    @objc private func next() { controller.navigate() }
    @objc private func closeFind() { controller.close() }
}

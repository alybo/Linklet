import AppKit
import SwiftUI

private final class SearchPanel: NSPanel {
    let showsFavorites: Bool
    var onCancel: (() -> Void)?
    var handlesKeyEvent: ((NSEvent) -> Bool)?
    init(contentRect: NSRect, showsFavorites: Bool) {
        self.showsFavorites = showsFavorites
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if handlesKeyEvent?(event) == true { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handlesKeyEvent?(event) == true || super.performKeyEquivalent(with: event)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class FavoriteSelection: ObservableObject {
    @Published var siteID: UUID?
}

/// A shadow carrier behind Glass. The window itself stays transparent, so the
/// shadow path can match the rounded surface instead of the NSPanel rectangle.
private final class RoundedGlassShadowView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // shadowPath supplies the silhouette. A fill would add a second,
        // faint outline around the Glass surface.
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.19
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        layer?.shadowRadius = 14
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 26, cornerHeight: 26, transform: nil)
    }
}

@MainActor
final class SearchWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let settings: SearchSettings
    private let openURL: (URL) -> Void
    let input = NSTextField()
    let selection = SearchEngineSelection()
    private let favoriteSelection = FavoriteSelection()
    private var engineControl: NSView!
    var isVisible: Bool { window?.isVisible == true }
    private var panel: SearchPanel { window as! SearchPanel }

    init(settings: SearchSettings, openURL: @escaping (URL) -> Void) {
        self.settings = settings
        self.openURL = openURL
        let panel = Self.makePanel(showsFavorites: settings.shouldShowFavoriteSites)
        super.init(window: panel)
        configure(panel: panel)
    }

    private static func makePanel(showsFavorites: Bool) -> SearchPanel {
        // Both variants use the same transparent perimeter, rounded shadow path,
        // and Glass construction. Only the visible card height differs.
        let size = NSSize(width: 744, height: showsFavorites ? 220 : 140)
        let panel = SearchPanel(contentRect: NSRect(origin: .zero, size: size), showsFavorites: showsFavorites)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        return panel
    }

    private func configure(panel: SearchPanel) {
        let panelBounds = panel.contentView?.bounds ?? .zero
        let content = NSView(frame: panelBounds.insetBy(dx: 32, dy: 32))
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.handlesKeyEvent = { [weak self] event in self?.handlePanelKeyEvent(event) ?? false }
        let root = NSView(frame: panelBounds)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.layer?.masksToBounds = false
        root.autoresizingMask = [.width, .height]
        let shadow = RoundedGlassShadowView(frame: content.frame)
        shadow.autoresizingMask = [.width, .height]
        root.addSubview(shadow)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.style = .regular
            glass.cornerRadius = 26
            glass.contentView = content
            glass.autoresizingMask = [.width, .height]
            root.addSubview(glass)
        } else {
            let material = NSVisualEffectView(frame: content.frame)
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 22
            material.layer?.masksToBounds = true
            material.autoresizingMask = [.width, .height]
            material.addSubview(content)
            root.addSubview(material)
        }
        panel.contentView = root
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 23, weight: .regular)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .systemFont(ofSize: 24, weight: .regular)
        input.textColor = .labelColor
        input.cell?.usesSingleLineMode = true
        input.cell?.isScrollable = true
        input.delegate = self
        input.target = self
        input.action = #selector(submit)
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        engineControl = NSHostingView(rootView: SearchEngineControl(
            selection: selection,
            submit: { [weak self] in self?.submit() },
            didChoose: { [weak self] in self?.focusInput() },
            didDismiss: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.isVisible else { return }
                    if self.window?.isKeyWindow != true { self.close() }
                }
            }
        ))
        var views = [icon, input, engineControl!]
        var favoritesControl: NSView?
        if panel.showsFavorites {
            let favorites = NSHostingView(rootView: FavoriteSitesStrip(
                settings: settings,
                open: { [weak self] site in self?.openFavorite(site) },
                selection: favoriteSelection
            ))
            favoritesControl = favorites
            views.append(favorites)
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 28),
            input.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            input.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            input.trailingAnchor.constraint(equalTo: engineControl.leadingAnchor, constant: -16),
            engineControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            engineControl.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            engineControl.widthAnchor.constraint(equalToConstant: 174),
            engineControl.heightAnchor.constraint(equalToConstant: 38)
        ])
        if let favoritesControl {
            NSLayoutConstraint.activate([
                favoritesControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                favoritesControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                favoritesControl.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 22),
                // The SwiftUI strip has 8 pt of its own trailing space; 12 pt
                // here makes the visual padding to the glass edge 20 pt.
                favoritesControl.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
                favoritesControl.heightAnchor.constraint(equalToConstant: 70)
            ])
        }
        panel.initialFirstResponder = input
        input.nextKeyView = engineControl
        engineControl.nextKeyView = input
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toggle() {
        if window?.isVisible == true { close() } else { present() }
    }

    func present() {
        replacePanelIfNeeded()
        guard let window else { return }
        reset()
        window.title = L("Quick Search")
        input.placeholderString = L("Search or enter address")
        input.setAccessibilityLabel(L("Search or enter address"))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                          y: frame.minY + frame.height * 0.7 - window.frame.height / 2))
        }
        // A nonactivating panel borrows keyboard focus and returns it to the
        // previous app when dismissed, including in full-screen Spaces.
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
    }

    override func close() {
        selection.isPresented = false
        window?.orderOut(nil)
        reset()
    }

    private func reset() {
        input.stringValue = ""
        selection.engine = settings.engine
        favoriteSelection.siteID = nil
    }

    private func replacePanelIfNeeded() {
        guard panel.showsFavorites != settings.shouldShowFavoriteSites else { return }
        let replacement = Self.makePanel(showsFavorites: settings.shouldShowFavoriteSites)
        panel.orderOut(nil)
        panel.delegate = nil
        window = replacement
        configure(panel: replacement)
    }

    func openFavorite(_ site: FavoriteSite) {
        close()
        openURL(site.url)
    }

    private func focusInput() {
        favoriteSelection.siteID = nil
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(input)
        (input.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: input.stringValue.utf16.count, length: 0))
    }

    @objc func submit() {
        guard let url = SearchInput.destination(for: input.stringValue, engine: selection.engine) else { return }
        close()
        openURL(url)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() {
            close()
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)), !textView.hasMarkedText(), selectFavorite(at: 0) {
            return true
        }
        return false
    }

    @discardableResult
    private func selectFavorite(at index: Int) -> Bool {
        let sites = visibleFavoriteSites
        guard sites.indices.contains(index) else { return false }
        favoriteSelection.siteID = sites[index].id
        window?.makeFirstResponder(panel)
        return true
    }

    private var visibleFavoriteSites: [FavoriteSite] {
        panel.showsFavorites ? settings.favoriteSites : []
    }

    func handlePanelKeyEvent(_ event: NSEvent) -> Bool {
        guard isVisible, !selection.isPresented else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command], let number = event.charactersIgnoringModifiers.flatMap({ Int($0) }), number > 0 {
            let sites = visibleFavoriteSites
            guard sites.indices.contains(number - 1) else { return false }
            openFavorite(sites[number - 1])
            return true
        }
        guard let selectedID = favoriteSelection.siteID,
              let index = visibleFavoriteSites.firstIndex(where: { $0.id == selectedID }) else { return false }
        switch event.keyCode {
        case 123: return selectFavorite(at: max(0, index - 1))
        case 124: return selectFavorite(at: min(visibleFavoriteSites.count - 1, index + 1))
        case 125: return selectFavorite(at: min(visibleFavoriteSites.count - 1, index + 1))
        case 126: focusInput(); return true
        case 36, 76: openFavorite(visibleFavoriteSites[index]); return true
        default: return false
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !selection.isPresented { close() }
    }
}

private struct FavoriteSitesStrip: View {
    @ObservedObject var settings: SearchSettings
    let open: (FavoriteSite) -> Void
    @ObservedObject var selection: FavoriteSelection
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !settings.favoriteSites.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Favorite websites"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(settings.favoriteSites) { site in
                                Button { open(site) } label: {
                                    HStack(spacing: 4) {
                                        FavoriteSiteIcon(site: site)
                                        Text(site.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1)
                                    }
                                    .padding(8)
                                    .frame(height: 32)
                                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .background(
                                    selection.siteID == site.id ? selectedFill : Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .overlay {
                                    if selection.siteID == site.id {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(selectedBorder, lineWidth: 1)
                                            .shadow(color: selectedGlow, radius: 2, y: 1)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .help(site.address)
                                .accessibilityLabel(site.name)
                                .id(site.id)
                            }
                        }
                    }
                    .onChange(of: selection.siteID) { selectedID in
                        guard let selectedID else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(selectedID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var selectedFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.accentColor.opacity(0.24)
    }

    private var selectedBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.30) : Color.accentColor.opacity(0.55)
    }

    private var selectedGlow: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.accentColor.opacity(0.18)
    }
}

private struct FavoriteSiteIcon: View {
    let site: FavoriteSite

    var body: some View {
        Group {
            if let data = site.faviconData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "globe").font(.system(size: 14, weight: .medium))
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

import AppKit
import Combine
import SwiftUI

private final class SearchPanel: NSPanel {
    let showsFavorites: Bool
    let design: SearchPanelDesign
    var onCancel: (() -> Void)?
    var handlesKeyEvent: ((NSEvent) -> Bool)?
    init(contentRect: NSRect, showsFavorites: Bool, design: SearchPanelDesign) {
        self.showsFavorites = showsFavorites
        self.design = design
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        design == .notch ? frameRect : super.constrainFrameRect(frameRect, to: screen)
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
    @Published var scrollResetID = UUID()
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
    private let reduceMotion: () -> Bool
    private let openURL: (URL) -> Void
    let input = NSTextField()
    let selection = SearchEngineSelection()
    private let favoriteSelection = FavoriteSelection()
    private let notchReveal = SearchNotchReveal()
    private let notchContentMask = CAShapeLayer()
    private weak var notchContent: NSView?
    private weak var notchSearchRow: NSView?
    private weak var notchFavorites: NSView?
    private var notchSearchTop: NSLayoutConstraint?
    private var animationTimer: Timer?
    private var notchResizeTimer: Timer?
    private var notchResize: (width: CGFloat, destination: CGRect, lastTick: TimeInterval)?
    private var isDismissing = false
    private var designObservation: AnyCancellable?
    private var engineIconObservation: AnyCancellable?
    private var screensObservation: AnyCancellable?
    private var hoverTimer: Timer?
    private var hoverPlacements: [SearchNotchPlacement] = []
    private var hoverEntry: (placement: SearchNotchPlacement, time: TimeInterval)?
    private var hoverExitTime: TimeInterval?
    private var openedByHover = false
    private var waitsForHoverExit = false
    var isVisible: Bool { window?.isVisible == true && !isDismissing }
    private var panel: SearchPanel { window as! SearchPanel }

    init(settings: SearchSettings,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         openURL: @escaping (URL) -> Void) {
        self.settings = settings
        self.reduceMotion = reduceMotion
        self.openURL = openURL
        let panel = Self.makePanel(settings: settings)
        super.init(window: panel)
        configure(panel: panel)
    }

    private static func makePanel(settings: SearchSettings) -> SearchPanel {
        let showsFavorites = settings.shouldShowFavoriteSites
        let design = settings.panelDesign
        let size: NSSize
        switch design {
        case .floating:
            size = NSSize(width: 744, height: showsFavorites ? 220 : 140)
        case .notch:
            size = NSSize(width: SearchNotchLayout.compactWindowWidth, height: NSStatusBar.system.thickness
                          + SearchNotchLayout.bodyHeight(showsFavorites: showsFavorites) + SearchNotchLayout.animationClearance)
        }
        let panel = SearchPanel(contentRect: NSRect(origin: .zero, size: size), showsFavorites: showsFavorites, design: design)
        panel.isFloatingPanel = true
        panel.level = design == .notch ? .statusBar : .floating
        if design == .notch { panel.appearance = NSAppearance(named: .darkAqua) }
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
        let isNotch = panel.design == .notch
        let content = NSView(frame: isNotch ? panelBounds : panelBounds.insetBy(dx: 32, dy: 32))
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.handlesKeyEvent = { [weak self] event in self?.handlePanelKeyEvent(event) ?? false }
        let root = NSView(frame: panelBounds)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.layer?.masksToBounds = false
        root.autoresizingMask = [.width, .height]
        if isNotch {
            let surface = NSHostingView(rootView: SearchNotchSurface(reveal: notchReveal))
            surface.sizingOptions = []
            surface.frame = panelBounds
            surface.autoresizingMask = [.width, .height]
            root.addSubview(surface)
            content.wantsLayer = true
            content.autoresizingMask = [.width, .height]
            root.addSubview(content)
            notchContent = content
        } else {
            installFloatingMaterial(around: content, in: root)
        }
        panel.contentView = root
        configureControls(in: content, for: panel)
    }

    private func installFloatingMaterial(around content: NSView, in root: NSView) {
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
    }

    private func configureControls(in content: NSView, for panel: SearchPanel) {
        let isNotch = panel.design == .notch
        let row = isNotch ? makeNotchSearchRow(in: content) : content
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: isNotch ? 20 : 23, weight: .regular)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .systemFont(ofSize: isNotch ? 20 : 24, weight: .regular)
        input.textColor = .labelColor
        input.contentType = .URL
        input.cell?.usesSingleLineMode = true
        input.cell?.isScrollable = true
        input.delegate = self
        input.target = self
        input.action = #selector(submit)
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, input] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: isNotch ? SearchNotchLayout.magnifierInset : 24),
            isNotch ? icon.centerYAnchor.constraint(equalTo: row.centerYAnchor)
                : icon.topAnchor.constraint(equalTo: row.topAnchor, constant: 24),
            icon.widthAnchor.constraint(equalToConstant: SearchNotchLayout.magnifierWidth),
            icon.heightAnchor.constraint(equalToConstant: 28),
            input.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: isNotch ? SearchNotchLayout.textGap : 16),
            input.centerYAnchor.constraint(equalTo: icon.centerYAnchor)
        ])
        installEngineControl(in: row, alignedTo: icon, isNotch: isNotch)
        if panel.showsFavorites {
            let favorites = NSHostingView(rootView: FavoriteSitesStrip(
                settings: settings,
                open: { [weak self] site in self?.openFavorite(site) },
                selection: favoriteSelection,
                design: panel.design
            ))
            favorites.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(favorites)
            if isNotch { notchFavorites = favorites }
            let inset = isNotch ? SearchNotchLayout.contentInset : 20
            NSLayoutConstraint.activate([
                favorites.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
                favorites.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
                isNotch ? favorites.topAnchor.constraint(equalTo: row.bottomAnchor, constant: SearchNotchLayout.rowGap)
                    : favorites.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 22),
                favorites.heightAnchor.constraint(equalToConstant: isNotch ? SearchNotchLayout.favoritesHeight : 70)
            ])
            if !isNotch { favorites.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12).isActive = true }
        }
        panel.initialFirstResponder = input
    }

    private func installEngineControl(in row: NSView, alignedTo icon: NSView, isNotch: Bool) {
        let control = NSHostingView(rootView: SearchEngineControl(
            selection: selection,
            didChoose: { [weak self] in self?.focusInput() },
            didDismiss: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.isVisible else { return }
                    if self.window?.isKeyWindow != true { self.close() }
                }
            }
        ))
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(control)
        NSLayoutConstraint.activate([
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: isNotch ? -SearchNotchLayout.engineControlInset : -19),
            control.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            control.widthAnchor.constraint(equalToConstant: SearchNotchLayout.engineControlSize),
            control.heightAnchor.constraint(equalToConstant: SearchNotchLayout.engineControlSize)
        ])
        let withIcon = input.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -SearchNotchLayout.engineControlGap)
        let withoutIcon = input.trailingAnchor.constraint(equalTo: row.trailingAnchor,
                                                           constant: isNotch ? -SearchNotchLayout.textTrailingInset : -24)
        engineIconObservation = settings.$showsEngineIcon.removeDuplicates().sink { [weak self, weak control] visible in
            guard let self, let control else { return }
            if !visible, self.selection.isPresented {
                self.selection.isPresented = false
                if self.isVisible, self.window?.isKeyWindow == true { self.focusInput() }
            }
            control.isHidden = !visible
            (visible ? withoutIcon : withIcon).isActive = false
            (visible ? withIcon : withoutIcon).isActive = true
            self.input.nextKeyView = visible ? control : nil
            control.nextKeyView = visible ? self.input : nil
            self.resizeNotchToFitText(showsEngineIcon: visible)
        }
    }

    private func makeNotchSearchRow(in content: NSView) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.075).cgColor
        row.layer?.borderColor = NSColor.white.withAlphaComponent(0.11).cgColor
        row.layer?.borderWidth = 1
        row.layer?.cornerRadius = 14
        row.layer?.cornerCurve = .continuous
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        notchSearchRow = row
        let top = row.topAnchor.constraint(equalTo: content.topAnchor, constant: NSStatusBar.system.thickness)
        notchSearchTop = top
        NSLayoutConstraint.activate([
            top,
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SearchNotchLayout.contentInset),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -SearchNotchLayout.contentInset),
            row.heightAnchor.constraint(equalToConstant: SearchNotchLayout.searchHeight)
        ])
        return row
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        animationTimer?.invalidate()
        notchResizeTimer?.invalidate()
        hoverTimer?.invalidate()
    }

    func startNotchHover() {
        guard designObservation == nil else { return }
        designObservation = settings.$panelDesign.removeDuplicates().sink { [weak self] design in
            guard let self else { return }
            if self.panel.design != design { self.dismiss(animated: false) }
            self.configureNotchHover(enabled: design == .notch)
        }
        screensObservation = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, self.settings.panelDesign == .notch else { return }
                if self.panel.design == .notch { self.dismiss(animated: false) }
                self.configureNotchHover(enabled: true)
            }
    }

    private func configureNotchHover(enabled: Bool) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverPlacements = enabled ? NSScreen.screens.map(SearchNotchPlacement.init(screen:)).filter { $0.hardwareNotch != nil } : []
        hoverEntry = nil
        hoverExitTime = nil
        waitsForHoverExit = false
        guard !hoverPlacements.isEmpty else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] tick in
            MainActor.assumeIsolated {
                guard let self, self.hoverTimer === tick else { return }
                self.pollNotchHover(at: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime,
                                    placements: self.hoverPlacements)
            }
        }
        timer.tolerance = 0.015
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func pollNotchHover(at point: CGPoint, now: TimeInterval, placements: [SearchNotchPlacement]) {
        guard settings.panelDesign == .notch else { return }
        let hovered = placements.first { $0.containsHoverPoint(point) }
        if hovered == nil { waitsForHoverExit = false }

        if isVisible {
            hoverEntry = nil
            let editor = input.currentEditor() as? NSTextView
            guard openedByHover, hovered == nil, window?.frame.insetBy(dx: -2, dy: -2).contains(point) == false,
                  (editor?.string ?? input.stringValue).isEmpty, editor?.hasMarkedText() != true,
                  favoriteSelection.siteID == nil, !selection.isPresented else {
                hoverExitTime = nil
                return
            }
            if let hoverExitTime {
                if now - hoverExitTime >= 0.25 { close() }
            } else {
                hoverExitTime = now
            }
            return
        }

        guard !isDismissing, !waitsForHoverExit, let hovered else {
            hoverEntry = nil
            return
        }
        if let hoverEntry, hoverEntry.placement == hovered {
            if now - hoverEntry.time >= 0.15 { present(notch: hovered, byHover: true) }
        } else {
            hoverEntry = (hovered, now)
        }
    }

    func toggle() {
        if isVisible { close() } else { present() }
    }

    func present() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        present(notch: screen.map(SearchNotchPlacement.init(screen:)), byHover: false, floatingFrame: screen?.visibleFrame)
    }

    private func present(notch: SearchNotchPlacement?, byHover: Bool, floatingFrame: NSRect? = nil) {
        replacePanelIfNeeded()
        guard let window, panel.design != .notch || notch != nil else { return }
        animationTimer?.invalidate()
        animationTimer = nil
        stopNotchResize()
        isDismissing = false
        openedByHover = byHover
        hoverExitTime = nil
        window.ignoresMouseEvents = false
        reset()
        window.title = L("Quick Search")
        updatePlaceholder()
        let animatesNotch = panel.design == .notch && notch != nil
        if animatesNotch, let notch {
            let frame = notch.panelFrame(showsFavorites: panel.showsFavorites)
            let startsFromClosed = !window.isVisible || notchReveal.placement != notch
            if startsFromClosed { notchReveal.motion = .closed }
            notchReveal.placement = notch
            notchSearchTop?.constant = notch.menuBarHeight
            if startsFromClosed { setNotchFrame(frame) }
            else { animateNotchFrame(to: frame) }
            updateNotchMotion(reduceMotion() ? .open : notchReveal.motion)
        } else if let frame = floatingFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                          y: frame.minY + frame.height * 0.7 - window.frame.height / 2))
        }
        // A nonactivating panel borrows keyboard focus and returns it to the
        // previous app when dismissed, including in full-screen Spaces.
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
        if animatesNotch { animateNotch(to: .open) }
    }

    private func updatePlaceholder() {
        let prompt = L("Search or enter address")
        if panel.design == .notch, let font = input.font {
            let opacity: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.72 : 0.44
            input.placeholderAttributedString = NSAttributedString(string: prompt, attributes: [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(opacity)
            ])
        } else {
            input.placeholderString = prompt
        }
        input.setAccessibilityLabel(prompt)
    }

    override func close() { dismiss(animated: true) }

    private func dismiss(animated: Bool) {
        guard window?.isVisible == true, !isDismissing || !animated else { return }
        isDismissing = true
        stopNotchResize()
        openedByHover = false
        waitsForHoverExit = true
        hoverEntry = nil
        hoverExitTime = nil
        selection.isPresented = false
        window?.ignoresMouseEvents = true
        if animated, panel.design == .notch { animateNotch(to: .closed) }
        else { finishDismissal() }
    }

    private func finishDismissal() {
        animationTimer?.invalidate()
        animationTimer = nil
        window?.orderOut(nil)
        updateNotchMotion(.closed)
        reset()
        isDismissing = false
    }

    private func animateNotch(to destination: SearchNotchMotion) {
        animationTimer?.invalidate()
        animationTimer = nil
        let origin = notchReveal.motion
        let distance = origin.distance(to: destination)
        guard !reduceMotion(), distance > 0.001 else {
            updateNotchMotion(destination)
            if destination == .closed { finishDismissal() }
            return
        }
        let opening = destination == .open
        let fullDuration = opening ? SearchNotchMotion.openingDuration : SearchNotchMotion.closingDuration
        let duration = fullDuration * sqrt(min(1, distance))
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] tick in
            MainActor.assumeIsolated {
                guard let self, self.animationTimer === tick else { return }
                let t = min(1, (ProcessInfo.processInfo.systemUptime - started) / duration)
                self.updateNotchMotion(origin.moving(toward: destination, fraction: t))
                guard t >= 1, self.animationTimer === tick else { return }
                tick.invalidate()
                self.animationTimer = nil
                if !opening { self.finishDismissal() }
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateNotchMotion(_ motion: SearchNotchMotion) {
        notchReveal.motion = motion
        guard let content = notchContent, let layer = content.layer, let placement = notchReveal.placement else { return }
        notchSearchRow?.alphaValue = motion.searchOpacity
        notchFavorites?.alphaValue = motion.favoritesOpacity
        guard motion != .open else { layer.mask = nil; return }
        let (rect, contour) = placement.outline(in: content.bounds.size, motion: motion)
        let path = contour.path(in: rect).cgPath
        var flip = CGAffineTransform(translationX: 0, y: content.bounds.height).scaledBy(x: 1, y: -1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notchContentMask.frame = content.bounds
        notchContentMask.path = layer.isGeometryFlipped ? path : path.copy(using: &flip)
        layer.mask = notchContentMask
        CATransaction.commit()
    }

    private func resizeNotchToFitText(showsEngineIcon: Bool) {
        guard isVisible, panel.design == .notch, let placement = notchReveal.placement, let font = input.font else { return }
        let text = (input.currentEditor() as? NSTextView)?.string ?? input.stringValue
        // The panel is capped at a single short line. Bound the work for very large pastes.
        let textSample = String(decoding: text.utf16.prefix(1024), as: UTF16.self)
        let textWidth = (textSample as NSString).size(withAttributes: [.font: font]).width
        let preferred = SearchNotchLayout.preferredWidth(textWidth: textWidth, showsEngineIcon: showsEngineIcon)
        animateNotchFrame(to: placement.panelFrame(showsFavorites: panel.showsFavorites, preferredWidth: preferred))
    }

    private func animateNotchFrame(to destination: CGRect) {
        guard let window else { return }
        if reduceMotion() || window.frame == destination {
            stopNotchResize()
            setNotchFrame(destination)
            return
        }
        if notchResizeTimer != nil {
            notchResize?.destination = destination
            return
        }
        notchResize = (window.frame.width, destination, ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] tick in
            MainActor.assumeIsolated {
                guard let self, self.notchResizeTimer === tick, var resize = self.notchResize else { return }
                let remaining = resize.destination.width - resize.width
                if abs(remaining) <= 1 {
                    self.stopNotchResize()
                    self.setNotchFrame(resize.destination)
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                let progress = 1 - exp(-22 * (now - resize.lastTick))
                // AppKit rounds window frames. Keep the unrounded width so small steps still accumulate.
                resize.width += remaining * progress
                resize.lastTick = now
                self.notchResize = resize
                var frame = resize.destination
                frame.origin.x = frame.midX - resize.width / 2
                frame.size.width = resize.width
                self.setNotchFrame(frame)
            }
        }
        notchResizeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func setNotchFrame(_ frame: CGRect) {
        guard let window, window.frame != frame else { return }
        window.setFrame(frame, display: false)
        notchContent?.layoutSubtreeIfNeeded()
        // The controls and the glass contour must agree while a query arrives during the reveal.
        if notchReveal.motion != .open { updateNotchMotion(notchReveal.motion) }
    }

    private func stopNotchResize() {
        notchResizeTimer?.invalidate()
        notchResizeTimer = nil
        notchResize = nil
    }

    private func reset() {
        input.stringValue = ""
        selection.engine = settings.engine
        favoriteSelection.siteID = nil
        favoriteSelection.scrollResetID = UUID()
    }

    private func replacePanelIfNeeded() {
        guard panel.showsFavorites != settings.shouldShowFavoriteSites || panel.design != settings.panelDesign else { return }
        let replacement = Self.makePanel(settings: settings)
        dismiss(animated: false)
        engineIconObservation = nil
        panel.delegate = nil
        panel.makeFirstResponder(nil)
        input.removeFromSuperview()
        notchSearchTop = nil
        notchReveal.placement = nil
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

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === input else { return }
        resizeNotchToFitText(showsEngineIcon: settings.showsEngineIcon)
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
        guard !selection.isPresented, let panel = notification.object as? SearchPanel else { return }
        if panel.design == .floating {
            close()
        } else {
            // AppKit can report the old focus change after the same panel has reopened.
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel, self.window === panel, !panel.isKeyWindow, !self.selection.isPresented else { return }
                self.close()
            }
        }
    }
}

private struct FavoriteSitesStrip: View {
    @ObservedObject var settings: SearchSettings
    let open: (FavoriteSite) -> Void
    @ObservedObject var selection: FavoriteSelection
    let design: SearchPanelDesign
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isNotch: Bool { design == .notch }
    private var cornerRadius: CGFloat { isNotch ? 10 : 8 }

    var body: some View {
        if !settings.favoriteSites.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !isNotch {
                    Text(L("Favorite websites"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: isNotch ? 10 : 8) {
                            ForEach(settings.favoriteSites) { site in
                                Button { open(site) } label: {
                                    HStack(spacing: 4) {
                                        SiteIcon(settings: settings, url: site.url, size: FavoriteSiteLayout.iconSize)
                                        Text(site.name)
                                            .font(FavoriteSiteLayout.labelFont)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, isNotch ? 12 : 8)
                                    .padding(.vertical, 8)
                                    .frame(height: isNotch ? SearchNotchLayout.favoritesHeight : 32)
                                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                                .background(
                                    selection.siteID == site.id ? selectedFill : idleFill,
                                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                )
                                .overlay {
                                    if selection.siteID == site.id {
                                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
                    .id(selection.scrollResetID)
                    .onChange(of: selection.siteID) { selectedID in
                        guard let selectedID else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            proxy.scrollTo(selectedID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var idleFill: Color {
        isNotch ? Color.black.opacity(0.30) : Color.primary.opacity(0.08)
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

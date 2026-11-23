import AppKit
import SwiftUI

struct SearchNotchPlacement: Equatable {
    let screenFrame: CGRect
    let menuBarHeight: CGFloat
    let hardwareNotch: CGRect?

    init(screen: NSScreen) {
        let frame = screen.frame
        let safeTop = screen.safeAreaInsets.top
        let systemHeight = NSStatusBar.system.thickness
        var notch: CGRect?
        if safeTop > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            notch = CGRect(x: left.maxX, y: frame.maxY - safeTop, width: right.minX - left.maxX, height: safeTop)
        }
        self.init(screenFrame: frame, menuBarHeight: max(systemHeight, safeTop), hardwareNotch: notch)
    }

    init(screenFrame: CGRect, menuBarHeight: CGFloat, hardwareNotch: CGRect?) {
        self.screenFrame = screenFrame
        self.menuBarHeight = menuBarHeight
        self.hardwareNotch = hardwareNotch
    }

    func containsHoverPoint(_ point: CGPoint) -> Bool {
        guard let hardwareNotch else { return false }
        let bottom = max(screenFrame.minY, hardwareNotch.minY - 6)
        // The pointer can report the exact top coordinate, which CGRect.contains excludes.
        return point.x >= hardwareNotch.minX && point.x <= hardwareNotch.maxX
            && point.y >= bottom && point.y <= screenFrame.maxY
    }

    var collapsedWidth: CGFloat { hardwareNotch?.width ?? 136 }

    func panelFrame(showsFavorites: Bool, preferredWidth: CGFloat = SearchNotchLayout.compactWindowWidth) -> CGRect {
        let center = hardwareNotch?.midX ?? screenFrame.midX
        let space = 2 * min(center - screenFrame.minX, screenFrame.maxX - center)
        let width = min(preferredWidth, SearchNotchLayout.maximumWindowWidth, max(1, space - 32))
        let height = menuBarHeight + SearchNotchLayout.bodyHeight(showsFavorites: showsFavorites)
            + SearchNotchLayout.animationClearance
        return CGRect(x: center - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    func outline(in size: CGSize, motion: SearchNotchMotion) -> (rect: CGRect, contour: SearchNotchContour) {
        let shoulderReserve = min(SearchNotchLayout.shoulderRadius, size.width / 4)
        let openBodyWidth = size.width - 2 * shoulderReserve
        let startWidth = min(openBodyWidth, collapsedWidth)
        let startHeight = min(size.height, menuBarHeight)
        let bodyHeight = max(0, size.height - startHeight - SearchNotchLayout.animationClearance)
        let bodyWidth = startWidth + (openBodyWidth - startWidth) * motion.width
        let height = min(size.height, startHeight + bodyHeight * motion.depth)
        let expansion = min(1, motion.depth + 0.25 * motion.width * (1 - motion.depth))
        let radius = min(bodyWidth / 2, height, 6 + (SearchNotchLayout.radius - 6) * expansion)
        let shoulder = min(shoulderReserve * motion.width, startHeight, height - radius)
        let width = bodyWidth + 2 * shoulder
        let rect = CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
        return (rect, SearchNotchContour(radius: radius, shoulder: shoulder))
    }
}

enum SearchNotchLayout {
    static let shoulderRadius: CGFloat = 24
    static let contentInset: CGFloat = shoulderRadius + 24
    static let compactWindowWidth: CGFloat = 408 + 2 * contentInset
    static let maximumWindowWidth: CGFloat = 612 + 2 * contentInset
    static let magnifierInset: CGFloat = 14
    static let magnifierWidth: CGFloat = 26
    static let textGap: CGFloat = 10
    static let engineControlSize: CGFloat = 36
    static let engineControlInset: CGFloat = 9
    static let engineControlGap: CGFloat = 8
    static let textTrailingInset: CGFloat = 16
    static let searchHeight: CGFloat = 48
    static let rowGap: CGFloat = 12
    static let favoritesHeight: CGFloat = 38
    static let bottomInset: CGFloat = 22
    static let radius: CGFloat = 26
    static let animationClearance: CGFloat = 10

    static func bodyHeight(showsFavorites: Bool) -> CGFloat {
        searchHeight + bottomInset + (showsFavorites ? rowGap + favoritesHeight : 0)
    }

    static func preferredWidth(textWidth: CGFloat, showsEngineIcon: Bool) -> CGFloat {
        let trailing = showsEngineIcon ? engineControlGap + engineControlSize + engineControlInset : textTrailingInset
        let reserved = 2 * contentInset + magnifierInset + magnifierWidth + textGap + trailing
        return max(compactWindowWidth, ceil(textWidth + reserved + 22))
    }
}

struct SearchNotchMotion: Equatable {
    let width: CGFloat
    let depth: CGFloat
    let searchOpacity: CGFloat
    let favoritesOpacity: CGFloat

    static let closed = Self(width: 0, depth: 0, searchOpacity: 0, favoritesOpacity: 0)
    static let open = Self(width: 1, depth: 1, searchOpacity: 1, favoritesOpacity: 1)
    static let openingDuration: TimeInterval = 0.42
    static let closingDuration: TimeInterval = 0.23

    func distance(to destination: Self) -> CGFloat {
        max(abs(width - destination.width), abs(depth - destination.depth),
            abs(searchOpacity - destination.searchOpacity), abs(favoritesOpacity - destination.favoritesOpacity))
    }

    func moving(toward destination: Self, fraction: CGFloat) -> Self {
        if fraction <= 0 { return self }
        if fraction >= 1 { return destination }
        func ease(from start: CGFloat, to end: CGFloat) -> CGFloat {
            let t = min(1, max(0, (fraction - start) / (end - start)))
            return t * t * (3 - 2 * t)
        }
        func mix(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
            start + (end - start) * progress
        }

        if destination == .open {
            let spread = ease(from: 0, to: 0.60)
            let drop = ease(from: 0.10, to: 0.65)
            let rebound = 0.062 * ease(from: 0.42, to: 0.66) * (1 - ease(from: 0.66, to: 1))
            return Self(
                width: mix(width, 1, spread),
                depth: mix(depth, 1, drop + rebound),
                searchOpacity: mix(searchOpacity, 1, ease(from: 0.27, to: 0.63)),
                favoritesOpacity: mix(favoritesOpacity, 1, ease(from: 0.47, to: 0.82))
            )
        }

        return Self(
            width: mix(width, 0, ease(from: 0.13, to: 1)),
            depth: mix(depth, 0, ease(from: 0, to: 0.87)),
            searchOpacity: mix(searchOpacity, 0, ease(from: 0.09, to: 0.55)),
            favoritesOpacity: mix(favoritesOpacity, 0, ease(from: 0, to: 0.34))
        )
    }
}

@MainActor
final class SearchNotchReveal: ObservableObject {
    @Published var placement: SearchNotchPlacement?
    @Published var motion: SearchNotchMotion = .closed
}

struct SearchNotchSurface: View {
    @ObservedObject var reveal: SearchNotchReveal
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            if let placement = reveal.placement {
                let (rect, contour) = placement.outline(in: geometry.size, motion: reveal.motion)

                ZStack(alignment: .top) {
                    // The opaque shoulders share the clip with the glass body.
                    Color.black.frame(width: rect.width, height: contour.shoulder)
                    surface(topHeight: min(rect.height, placement.menuBarHeight), radius: contour.radius, height: rect.height)
                        .frame(width: rect.width - 2 * contour.shoulder, height: rect.height)
                }
                .frame(width: rect.width, height: rect.height)
                .clipShape(contour)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(placement.hardwareNotch == nil ? min(1, reveal.motion.width * 4) : 1)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func surface(topHeight: CGFloat, radius: CGFloat, height: CGFloat) -> some View {
        if reduceTransparency {
            Color.black
        } else {
            ZStack(alignment: .top) {
                if #available(macOS 26.0, *) {
                    ScreenEdgeSmokeTint(layer: .backing, axis: .vertical)
                    // Extend the glass beyond the screen edge so the contour owns the top edge.
                    Color.clear.overlay(alignment: .top) {
                        ScreenEdgeNativeGlass(shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
                            .frame(height: height + radius + topHeight)
                            .offset(y: -(radius + topHeight))
                    }
                    ScreenEdgeSmokeTint(layer: .correction, axis: .vertical)
                } else {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.96), location: 0.43),
                        .init(color: .black.opacity(0.79), location: 0.76),
                        .init(color: .black.opacity(0.48), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                Color.black.frame(height: topHeight)
            }
        }
    }
}

struct SearchNotchContour: Shape {
    let radius: CGFloat
    let shoulder: CGFloat

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        let r = min(radius, (right - left) / 2, rect.height)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + shoulder),
                              control: CGPoint(x: right, y: rect.minY))
            path.addLine(to: CGPoint(x: right, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: right - r, y: rect.maxY),
                              control: CGPoint(x: right, y: rect.maxY))
            path.addLine(to: CGPoint(x: left + r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - r),
                              control: CGPoint(x: left, y: rect.maxY))
            path.addLine(to: CGPoint(x: left, y: rect.minY + shoulder))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                              control: CGPoint(x: left, y: rect.minY))
            path.closeSubpath()
        }
    }
}

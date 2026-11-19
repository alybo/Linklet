import SwiftUI

enum WelcomeTone {
    case preview, search, setup

    var accent: Color {
        switch self {
        case .preview: Color(red: 0.24, green: 0.51, blue: 1)
        case .search: Color(red: 0.16, green: 0.77, blue: 0.67)
        case .setup: Color(red: 0.58, green: 0.45, blue: 1)
        }
    }

    var iconColor: Color {
        switch self {
        case .preview: .blue
        case .search: .teal
        case .setup: .purple
        }
    }
}

private struct WelcomeCardSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15)
        content
            .background(scheme == .dark ? Color.white.opacity(0.055) : .white, in: shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.08)) }
    }
}

extension View {
    func welcomeCard() -> some View { modifier(WelcomeCardSurface()) }
}

struct WelcomeArtwork<Content: View>: View {
    let tone: WelcomeTone
    let height: CGFloat
    let content: Content

    init(_ tone: WelcomeTone, height: CGFloat, @ViewBuilder content: () -> Content) {
        self.tone = tone
        self.height = height
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.10, blue: 0.23)
            RadialGradient(colors: [tone.accent, tone.accent.opacity(0)], center: .topTrailing,
                           startRadius: 24, endRadius: 400)
            RadialGradient(colors: [Color(red: 0.18, green: 0.57, blue: 0.85).opacity(0.65), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 280)
            Canvas { context, size in
                for index in 0..<7 {
                    let inset = CGFloat(index) * 19
                    let curve = Path(ellipseIn: CGRect(
                        x: -size.width * 0.27 + inset, y: size.height * 0.26 + inset * 0.48,
                        width: size.width * 1.5 - 2 * inset, height: size.height * 1.46 - inset
                    ))
                    context.stroke(curve, with: .color(.white.opacity(0.11)), lineWidth: 1)
                }
            }.rotationEffect(.degrees(-16)).scaleEffect(1.12)
            content
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.14)) }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// A small, static rendering of Linklet's three working surfaces. The real
/// address control is provided by the separate interactive tutorial.
struct WelcomeInterfaceIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(0.11))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.25)) }
                .frame(width: 318, height: 158)
                .rotationEffect(.degrees(-8)).offset(x: -35, y: -2)
            preview
                .offset(x: 18, y: -3)
            sidebar
                .offset(x: -175, y: 16)
            search
                .offset(x: 120, y: 77)
        }
        .frame(width: 500, height: 224)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                Image(systemName: "chevron.left").font(.system(size: 8, weight: .semibold))
                Spacer()
                Text("example.com").font(.system(size: 8, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color(red: 0.78, green: 0.83, blue: 0.93))
            .padding(.horizontal, 10).frame(height: 26)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    line(70, 7, .white.opacity(0.77))
                    line(84, 4, .white.opacity(0.29))
                    line(67, 4, .white.opacity(0.22))
                    line(79, 4, .white.opacity(0.22))
                    Spacer(minLength: 2)
                    line(42, 9, Color(red: 0.40, green: 0.63, blue: 1))
                }
                Spacer(minLength: 0)
                WelcomeMiniCover().frame(width: 126, height: 86)
            }
            .frame(height: 95)
            .padding(12).background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .bottom], 5)
        }
        .frame(width: 293)
        .background(Color(red: 0.08, green: 0.13, blue: 0.23), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.36)) }
        .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 13)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            sidebarRow("macwindow", "Open Windows")
            sidebarRow("bookmark.fill", "Bookmarks")
            sidebarRow("clock", "History")
            sidebarRow("arrow.down.circle", "Downloads")
        }
        .padding(10)
        .background(Color(red: 0.10, green: 0.18, blue: 0.32), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.22)) }
        .shadow(color: .black.opacity(0.30), radius: 11, x: 0, y: 8)
    }

    private func sidebarRow(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 13)
            Text(L(title)).lineLimit(1)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.blue)
            Text(L("Quick Search")).lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "return").foregroundStyle(.secondary)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color(red: 0.08, green: 0.12, blue: 0.20))
        .padding(.horizontal, 12).frame(width: 190, height: 34)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.30), radius: 12, x: 0, y: 6)
    }

    private func line(_ width: CGFloat, _ height: CGFloat, _ color: Color) -> some View {
        Capsule().fill(color).frame(width: width, height: height)
    }
}

struct WelcomeMiniCover: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(colors: [Color(red: 0.20, green: 0.37, blue: 0.99), Color(red: 0.15, green: 0.79, blue: 0.82)],
                               startPoint: .bottomLeading, endPoint: .topTrailing)
                Circle().fill(.white.opacity(0.24))
                    .frame(width: size.height * 1.4).offset(x: size.width * 0.34, y: -size.height * 0.38)
                Capsule().fill(.white.opacity(0.19)).rotationEffect(.degrees(-28))
                    .frame(width: size.width * 1.48, height: size.height * 0.5)
                    .offset(x: -size.width * 0.16, y: size.height * 0.26)
                Image(systemName: "link").font(.system(size: size.height * 0.30, weight: .medium)).foregroundStyle(.white)
            }
            .frame(width: size.width, height: size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

struct WelcomeSymbolIllustration: View {
    let primary: String
    let leading: String
    let trailing: String

    var body: some View {
        ZStack {
            Capsule().fill(.white.opacity(0.32)).frame(width: 268, height: 1)
            tile(leading, size: 58, strong: false).rotationEffect(.degrees(-10)).offset(x: -101, y: 11)
            tile(trailing, size: 58, strong: false).rotationEffect(.degrees(10)).offset(x: 101, y: -11)
            tile(primary, size: 85, strong: true)
        }
    }

    private func tile(_ symbol: String, size: CGFloat, strong: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24)
        return Image(systemName: symbol)
            .font(.system(size: size * 0.38, weight: .medium))
            .foregroundStyle(strong ? Color(red: 0.10, green: 0.20, blue: 0.40) : .white)
            .frame(width: size, height: size)
            .background(strong ? .white : Color(red: 0.17, green: 0.26, blue: 0.46), in: shape)
            .overlay { shape.strokeBorder(.white.opacity(0.26)) }
            .shadow(color: .black.opacity(0.24), radius: 15, x: 0, y: 8)
    }
}

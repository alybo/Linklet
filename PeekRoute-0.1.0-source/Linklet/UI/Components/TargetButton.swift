import AppKit
import SwiftUI

@MainActor
final class TargetIconCache {
    static let shared = TargetIconCache()

    private let cache = NSCache<NSString, NSImage>()

    func icon(for applicationURL: URL) -> NSImage {
        let key = applicationURL.standardizedFileURL.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

struct TargetButton: View {
    @ObservedObject private var language = AppLanguage.shared
    let target: BrowserTarget
    let shortcutNumber: Int?
    let action: () -> Void

    @State private var isHovered = false

    private var icon: NSImage {
        TargetIconCache.shared.icon(for: target.applicationURL)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 0) {
                    Text(target.displayName)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)

                    if target.kind == .orionProfile {
                        Text(target.browserName)
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if let shortcutNumber {
                    Text("⌘\(shortcutNumber)")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlass(
            tint: isHovered ? Color.accentColor.opacity(0.14) : nil,
            interactive: true,
            in: Capsule()
        )
        .scaleEffect(isHovered ? 1.018 : 1)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .onHover { isHovered = $0 }
        .help(L("Open in %@", target.displayName))
        .applyShortcut(shortcutNumber)
    }
}

extension View {
    @ViewBuilder
    func liquidGlass<S: InsettableShape>(
        tint: Color? = nil,
        interactive: Bool = false,
        in shape: S
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.42), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                }
                .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
        }
    }

    @ViewBuilder
    func applyShortcut(_ number: Int?) -> some View {
        if let number,
           let character = String(number).first {
            keyboardShortcut(KeyEquivalent(character), modifiers: .command)
        } else {
            self
        }
    }
}

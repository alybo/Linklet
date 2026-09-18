import SwiftUI

@MainActor
final class SearchEngineSelection: ObservableObject {
    @Published var engine: SearchEngine = .google
    @Published var isPresented = false
}

/// Matches the split Open in button and its popover in the preview toolbar.
struct SearchEngineControl: View {
    @ObservedObject var selection: SearchEngineSelection
    let submit: () -> Void
    let didChoose: () -> Void
    let didDismiss: () -> Void
    @State private var primaryHovered = false
    @State private var chevronHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: submit) {
                HStack(spacing: 8) {
                    SearchEngineIcon(engine: selection.engine).frame(width: 18, height: 18)
                    Text(selection.engine.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.leading, 12).padding(.trailing, 10)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Color.primary.opacity(primaryHovered ? 0.07 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Search with %@", selection.engine.title))
            .onHover { primaryHovered = $0 }

            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 18)

            Button { selection.isPresented.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 32, height: 38)
                    .background(Color.primary.opacity(chevronHovered ? 0.07 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Choose a search engine for this query"))
            .help(L("Choose a search engine for this query"))
            .onHover { chevronHovered = $0 }
            .popover(isPresented: $selection.isPresented, arrowEdge: .bottom) {
                VStack(spacing: 2) {
                    ForEach(SearchEngine.allCases) { engine in
                        SearchEngineRow(engine: engine, selected: engine == selection.engine) {
                            selection.engine = engine
                            selection.isPresented = false
                            didChoose()
                        }
                    }
                }
                .padding(5)
                .frame(width: 218)
            }
        }
        .frame(height: 38)
        .background(Color.primary.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .onChange(of: selection.isPresented) { _, visible in
            if !visible { didDismiss() }
        }
    }
}

private struct SearchEngineRow: View {
    let engine: SearchEngine
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SearchEngineIcon(engine: engine).frame(width: 18, height: 18)
                Text(engine.title).font(.system(size: 12, weight: .medium))
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(hovered ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Compact monochrome marks inherit the current appearance and contrast.
private struct SearchEngineIcon: View {
    let engine: SearchEngine
    var body: some View {
        Group {
            switch engine {
            case .google: Text("G").font(.system(size: 19, weight: .bold))
            case .yandex: Text("Я").font(.system(size: 19, weight: .medium))
            case .bing: Text("b").font(.system(size: 22, weight: .bold, design: .rounded))
            case .duckDuckGo:
                DuckMark().stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            }
        }
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }
}

private struct DuckMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 1, y: 1, width: 22, height: 22))
        path.move(to: CGPoint(x: 8, y: 21))
        path.addCurve(to: CGPoint(x: 8, y: 9), control1: CGPoint(x: 11, y: 17), control2: CGPoint(x: 5, y: 14))
        path.addCurve(to: CGPoint(x: 16, y: 10), control1: CGPoint(x: 8, y: 3), control2: CGPoint(x: 17, y: 4))
        path.addLine(to: CGPoint(x: 21, y: 11))
        path.addLine(to: CGPoint(x: 15, y: 14))
        path.addLine(to: CGPoint(x: 16, y: 21))
        path.addEllipse(in: CGRect(x: 12, y: 8, width: 1, height: 1))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

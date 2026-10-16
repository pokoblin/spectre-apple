import SwiftUI

/// The sizes and timing every control floating over the remote desktop
/// shares, so that the two corners mirror each other (docs/ipad-layout.md).
enum FloatingKeyBar {
    /// The round toggles in the bottom corners. A horizontal bar is centred
    /// on their middle line; a vertical bar is as wide as they are.
    static let toggleSize: CGFloat = 52
    /// From the safe area's edges to the toggles and the bars.
    static let margin: CGFloat = 12
    /// Between a toggle and its bar, and between two bars.
    static let spacing: CGFloat = 8
    /// Every toggle opening or closing.
    static let animation = Animation.smooth(duration: 0.35)

    /// A key cap's smallest size, and its padding either side.
    static let keyMinWidth: CGFloat = 40
    static let keyMinHeight: CGFloat = 36
    static let keyHorizontalPadding: CGFloat = 10
    /// Inside a bar's capsule, and between its keys.
    static let barPadding: CGFloat = 6
    static let keySpacing: CGFloat = 2
    /// A group separator's length, and the room either side of it.
    static let separatorLength: CGFloat = 22
    static let separatorInset: CGFloat = 4

    /// Large glass cards: the connection status, the prompt panel.
    static let cardCornerRadius = SessionGlass.cardCornerRadius
    /// Small notices at the top of the screen.
    static let noticePadding = SessionGlass.noticePadding
    /// The row of keys above the touch keyboard.
    static let accessoryHeight: CGFloat = 60
    /// Bars of fixed height stop growing here, as the system's tab bar does;
    /// a long press on a key shows it large instead.
    static let maxTypeSize = DynamicTypeSize.xxLarge
}

// MARK: - Toggle

/// A round glass button in a bottom corner that opens and closes a bar.
/// Its symbol turns away as an `xmark` turns in, and back.
struct FloatingToggle: View {
    var symbol: String
    var isExpanded: Bool
    /// The glass's tint: a faint white, or the accent color to point out
    /// something held while the bar is closed (a locked modifier).
    var tint: Color = .white.opacity(0.25)
    var accessibilityLabel: Text
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: symbol)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(isExpanded ? 0 : 1)
                Image(systemName: "xmark")
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .opacity(isExpanded ? 1 : 0)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: FloatingKeyBar.toggleSize, height: FloatingKeyBar.toggleSize)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive().tint(tint), in: .circle)
        .dynamicTypeSize(...FloatingKeyBar.maxTypeSize)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Opening a bar

/// Shows or hides a bar next to its toggle. The bar always keeps its place
/// in the layout (inserting and removing it would resize its host and make
/// the toggle jump); a capsule mask grows out of the toggle's end and
/// shrinks back into a dot half the bar's thickness, while the bar fades.
/// Closed, it takes no touches and is skipped by VoiceOver.
struct CapsuleReveal: ViewModifier {
    var isRevealed: Bool
    /// The end next to the toggle, where the bar grows from.
    var edge: Edge

    func body(content: Content) -> some View {
        content
            .mask {
                GeometryReader { proxy in
                    let size = proxy.size
                    let dot = min(size.width, size.height) / 2
                    Capsule()
                        .frame(width: isRevealed ? size.width : dot, height: isRevealed ? size.height : dot)
                        // The dot sits a little inside the bar's end, centred across it.
                        .padding(Edge.Set(edge), isRevealed ? 0 : dot / 2)
                        .frame(width: size.width, height: size.height, alignment: alignment)
                }
            }
            .opacity(isRevealed ? 1 : 0)
            .allowsHitTesting(isRevealed)
            .accessibilityHidden(!isRevealed)
    }

    private var alignment: Alignment {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }
}

extension View {
    func capsuleReveal(_ isRevealed: Bool, from edge: Edge) -> some View {
        modifier(CapsuleReveal(isRevealed: isRevealed, edge: edge))
    }
}

// MARK: - Key caps

/// A key on a floating bar: clear, letting the glass show; a faint capsule
/// while pressed; filled with the accent color when lit (a locked
/// modifier, the keyboard shown, dictation running).
struct KeyCap: ViewModifier {
    var isLit: Bool
    var isPressed: Bool

    func body(content: Content) -> some View {
        content
            .lineLimit(1)
            .padding(.horizontal, FloatingKeyBar.keyHorizontalPadding)
            .frame(minWidth: FloatingKeyBar.keyMinWidth, minHeight: FloatingKeyBar.keyMinHeight)
            .foregroundStyle(isLit ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                if isLit {
                    Capsule().fill(.tint)
                } else if isPressed {
                    Capsule().fill(Color.primary.opacity(0.18))
                }
            }
            .contentShape(.capsule)
            .accessibilityShowsLargeContentViewer()
            .accessibilityAddTraits(isLit ? .isSelected : [])
    }
}

/// ``KeyCap`` for a button that acts on release.
struct KeyCapStyle: ButtonStyle {
    var isLit = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(KeyCap(isLit: isLit, isPressed: configuration.isPressed))
    }
}

extension View {
    func keyCap(isLit: Bool = false, isPressed: Bool = false) -> some View {
        modifier(KeyCap(isLit: isLit, isPressed: isPressed))
    }
}

/// Between groups of keys: a short hairline across the bar.
struct KeyBarSeparator: View {
    /// The bar's direction: a horizontal bar gets an upright line.
    var axis: Axis

    var body: some View {
        let upright = axis == .horizontal
        Rectangle()
            .fill(.separator)
            .frame(width: upright ? 1 : FloatingKeyBar.separatorLength,
                   height: upright ? FloatingKeyBar.separatorLength : 1)
            .padding(upright ? .horizontal : .vertical, FloatingKeyBar.separatorInset)
            .accessibilityHidden(true)
    }
}

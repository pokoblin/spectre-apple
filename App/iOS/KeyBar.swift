import SpectreKit
import SwiftUI

/// The key bar in the bottom-right corner (docs/ipad-layout.md): a round
/// toggle, a column of arrows above it and a row of keys to its left, an L
/// within thumb's reach. Its state, shared by the three pieces (each in its
/// own hosting controller, see ``RemoteScreenController``) and, through
/// ``TextTyper``, with the row above the touch keyboard.
@MainActor
@Observable
final class KeyBarModel {
    /// The session's input; nil until there is a session to type into.
    var input: SessionInput?
    /// Every session starts with the bar closed.
    var isExpanded = false
    /// Show the bar at all (More › Show Key Bar); remembered.
    var isShown = UserDefaults.standard.object(forKey: KeyBarModel.isShownKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(isShown, forKey: Self.isShownKey) }
    }
    /// Where the session toolbar in the bottom-left corner ends, from the
    /// screen's left edge: the row never reaches further left than that.
    var leadingObstruction: CGFloat = FloatingKeyBar.margin + FloatingKeyBar.toggleSize
    /// The prompt panel is open: both corners' controls make way for it.
    var isPromptOpen = false
    /// A region to watch is being chosen: the corners make way for that too.
    var isSelectingRegion = false

    private static let isShownKey = "showsKeyBar"

    /// Whether the floating bar is on screen: not while the touch keyboard
    /// is up, which carries the same keys above it, nor while the prompt
    /// panel is open or a region is chosen.
    var isVisible: Bool {
        isShown && input != nil && input?.showsTouchKeyboard != true && !isPromptOpen && !isSelectingRegion
    }

    /// Locked modifiers while the bar is closed tint its toggle.
    var hasLockedModifiers: Bool { !(input?.typer.locked.isEmpty ?? true) }

    func toggle() { isExpanded.toggle() }
}

// MARK: - Toggle

struct KeyBarToggle: View {
    let model: KeyBarModel

    var body: some View {
        FloatingToggle(symbol: "keyboard", isExpanded: model.isExpanded,
                       tint: !model.isExpanded && model.hasLockedModifiers ? .accentColor : .white.opacity(0.25),
                       accessibilityLabel: model.isExpanded ? Text("Close Key Bar") : Text("Open Key Bar"),
                       action: model.toggle)
            .animation(FloatingKeyBar.animation, value: model.isExpanded)
    }
}

// MARK: - Column

/// Above the toggle, as wide as it: the arrows, and the prompt panel's key.
struct FloatingKeyColumn: View {
    let model: KeyBarModel

    var body: some View {
        ViewThatFits(in: .vertical) {
            keys.padding(FloatingKeyBar.barPadding)
            ScrollView(.vertical, showsIndicators: false) { keys.padding(FloatingKeyBar.barPadding) }
                .clipShape(.capsule)
        }
        .frame(width: FloatingKeyBar.toggleSize)
        .glassEffect(.regular, in: .capsule)
        .capsuleReveal(model.isExpanded, from: .bottom)
        .animation(FloatingKeyBar.animation, value: model.isExpanded)
        .dynamicTypeSize(...FloatingKeyBar.maxTypeSize)
    }

    @ViewBuilder private var keys: some View {
        if let typer = model.input?.typer {
            VStack(spacing: FloatingKeyBar.keySpacing) {
                HeldKey(typer: typer, usage: HIDUsage.upArrow, label: "Up Arrow") { Image(systemName: "arrow.up") }
                HeldKey(typer: typer, usage: HIDUsage.leftArrow, label: "Left Arrow") { Image(systemName: "arrow.left") }
                HeldKey(typer: typer, usage: HIDUsage.rightArrow, label: "Right Arrow") { Image(systemName: "arrow.right") }
                HeldKey(typer: typer, usage: HIDUsage.downArrow, label: "Down Arrow") { Image(systemName: "arrow.down") }
                KeyBarSeparator(axis: .vertical)
                PromptKey(model: model)
            }
        }
    }
}

// MARK: - Row

/// Left of the toggle, on its middle line: the keys a terminal wants, the
/// modifiers, and a menu of combinations. Scrolls sideways where the
/// screen is too narrow for it.
struct FloatingKeyRow: View {
    let model: KeyBarModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            keys.padding(FloatingKeyBar.barPadding)
            ScrollView(.horizontal, showsIndicators: false) { keys.padding(FloatingKeyBar.barPadding) }
                .clipShape(.capsule)
        }
        .glassEffect(.regular, in: .capsule)
        .capsuleReveal(model.isExpanded, from: .trailing)
        .animation(FloatingKeyBar.animation, value: model.isExpanded)
        .dynamicTypeSize(...FloatingKeyBar.maxTypeSize)
    }

    @ViewBuilder private var keys: some View {
        if let typer = model.input?.typer {
            HStack(spacing: FloatingKeyBar.keySpacing) {
                KeyBarKeys.common(typer)
                KeyBarSeparator(axis: .horizontal)
                KeyBarKeys.modifiers(typer)
                KeyBarSeparator(axis: .horizontal)
                MoreKeysMenu(typer: typer)
            }
        }
    }
}

// MARK: - Keys

/// The keys, shared with the row above the touch keyboard.
enum KeyBarKeys {
    /// Esc, Ctrl+C, Tab, Shift+Tab, Backspace, Return.
    @ViewBuilder static func common(_ typer: TextTyper) -> some View {
        HeldKey(typer: typer, usage: HIDUsage.escape, label: "Escape") { Image(systemName: "escape") }
        ComboKey(typer: typer, combo: KeyCombo([.control], HIDUsage.c, title: "Ctrl+C"), label: "Control-C") {
            Text(verbatim: "⌃C").monospaced()
        }
        HeldKey(typer: typer, usage: HIDUsage.tab, label: "Tab") { Image(systemName: "arrow.right.to.line") }
        ComboKey(typer: typer, combo: KeyCombo([.shift], HIDUsage.tab, title: "Shift+Tab"), label: "Shift-Tab") {
            Image(systemName: "arrow.left.to.line")
        }
        HeldKey(typer: typer, usage: HIDUsage.deleteOrBackspace, label: "Backspace") { Image(systemName: "delete.left") }
        HeldKey(typer: typer, usage: HIDUsage.returnOrEnter, label: "Return") { Image(systemName: "return") }
    }

    /// Ctrl, Alt, Super, Shift: by their names, as Linux calls them.
    @ViewBuilder static func modifiers(_ typer: TextTyper) -> some View {
        ModifierKey(typer: typer, modifier: .control, title: "Ctrl")
        ModifierKey(typer: typer, modifier: .alt, title: "Alt")
        ModifierKey(typer: typer, modifier: .superKey, title: "Super")
        ModifierKey(typer: typer, modifier: .shift, title: "Shift")
    }
}

/// Down on the host while the finger is on it (the host repeats it, as it
/// would a physical key), with the locked modifiers.
///
/// A bar that scrolls must still scroll when a swipe starts on a key, so a
/// key doesn't go down the moment it is touched: a finger resting on it
/// for ``holdDelay`` holds it; one lifted sooner presses it once. It is a
/// button underneath, so a scroll view can take the touch back from it
/// (a gesture of its own would keep the bar from scrolling), and then
/// nothing is sent.
struct HeldKey<Label: View>: View {
    let typer: TextTyper
    let usage: UInt32
    let label: LocalizedStringKey
    @ViewBuilder let content: () -> Label
    @State private var holdTask: Task<Void, Never>?
    @State private var isHolding = false

    static var holdDelay: Duration { .milliseconds(150) }

    var body: some View {
        Button {
            if !isHolding { typer.press(usage) } // a tap, or VoiceOver
        } label: {
            content()
        }
        .buttonStyle(PressReportingKeyStyle(onPressChange: pressChanged))
        .accessibilityLabel(Text(label))
        .onDisappear {
            holdTask?.cancel()
            if isHolding { typer.endHold() }
        }
    }

    private func pressChanged(_ pressed: Bool) {
        holdTask?.cancel()
        if pressed {
            isHolding = false
            holdTask = Task {
                guard (try? await Task.sleep(for: Self.holdDelay)) != nil else { return }
                isHolding = true
                typer.beginHold(usage)
            }
        } else if isHolding {
            // Stays set until the next touch, so the button's action,
            // whichever side of this it comes, doesn't press it again.
            typer.endHold()
        }
    }
}

/// ``KeyCap`` that tells when the finger comes down and lifts (or a scroll
/// takes the touch).
struct PressReportingKeyStyle: ButtonStyle {
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .keyCap(isPressed: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in onPressChange(pressed) }
    }
}

/// A combination, sent on release.
struct ComboKey<Label: View>: View {
    let typer: TextTyper
    let combo: KeyCombo
    let label: LocalizedStringKey
    @ViewBuilder let content: () -> Label

    var body: some View {
        Button { typer.press(combo) } label: { content() }
            .buttonStyle(KeyCapStyle())
            .accessibilityLabel(Text(label))
    }
}

/// Tap: down on the host and locked (lit); again: released.
struct ModifierKey: View {
    let typer: TextTyper
    let modifier: TextTyper.Modifier
    let title: String

    var body: some View {
        Button { typer.toggle(modifier) } label: { Text(verbatim: title) }
            .buttonStyle(KeyCapStyle(isLit: typer.isLocked(modifier)))
    }
}

/// The combinations iPadOS keeps for itself and the rest of a PC keyboard
/// (``KeyCombo/menu``).
struct MoreKeysMenu: View {
    let typer: TextTyper

    var body: some View {
        Menu {
            ForEach(KeyCombo.menu) { group in
                if let submenu = group.submenu {
                    Menu(submenu) { items(group.combos) }
                } else {
                    Section { items(group.combos) }
                }
            }
        } label: {
            Image(systemName: "ellipsis").keyCap()
        }
        .menuIndicator(.hidden)
        .tint(.primary)
        .accessibilityLabel("More Keys")
    }

    private func items(_ combos: [KeyCombo]) -> some View {
        ForEach(combos) { combo in
            Button { typer.press(combo) } label: {
                Text(verbatim: combo.title)
                if let purpose = combo.purpose { Text(verbatim: purpose) }
            }
        }
    }
}

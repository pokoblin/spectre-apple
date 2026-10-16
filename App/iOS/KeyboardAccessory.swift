import SpectreKit
import SwiftUI
import UIKit

/// Above the touch keyboard (alone at the bottom with a hardware keyboard):
/// the floating key bar's keys, all in one row, while the floating bar
/// itself is hidden. A keyboard-style input view, so its background is the
/// keyboard's; the keys are in a glass capsule hosted in it. It shares the
/// floating bar's ``KeyBarModel``, so a modifier locked on one is lit on
/// the other.
final class KeyboardAccessory: UIInputView {
    private let host: UIHostingController<AgentKeyBarView>

    init(model: KeyBarModel) {
        host = UIHostingController(rootView: AgentKeyBarView(model: model))
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: FloatingKeyBar.accessoryHeight),
                   inputViewStyle: .keyboard)
        allowsSelfSizing = true
        host.view.backgroundColor = .clear
        host.overrideUserInterfaceStyle = .dark
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: FloatingKeyBar.accessoryHeight)
    }
}

/// Every key of the floating bar in one capsule, centred, 12 pt from the
/// sides, scrolling sideways where it doesn't fit: the prompt panel, the
/// keys a terminal wants, the arrows, the modifiers, the combinations, and
/// a key that puts the keyboard away.
struct AgentKeyBarView: View {
    let model: KeyBarModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            capsule
            ScrollView(.horizontal, showsIndicators: false) { capsule }
                .scrollClipDisabled()
        }
        .padding(.horizontal, FloatingKeyBar.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dynamicTypeSize(...FloatingKeyBar.maxTypeSize)
    }

    @ViewBuilder private var capsule: some View {
        if let input = model.input {
            let typer = input.typer
            HStack(spacing: FloatingKeyBar.keySpacing) {
                PromptKey(model: model)
                KeyBarSeparator(axis: .horizontal)
                KeyBarKeys.common(typer)
                KeyBarSeparator(axis: .horizontal)
                HeldKey(typer: typer, usage: HIDUsage.leftArrow, label: "Left Arrow") { Image(systemName: "arrow.left") }
                HeldKey(typer: typer, usage: HIDUsage.upArrow, label: "Up Arrow") { Image(systemName: "arrow.up") }
                HeldKey(typer: typer, usage: HIDUsage.downArrow, label: "Down Arrow") { Image(systemName: "arrow.down") }
                HeldKey(typer: typer, usage: HIDUsage.rightArrow, label: "Right Arrow") { Image(systemName: "arrow.right") }
                KeyBarSeparator(axis: .horizontal)
                KeyBarKeys.modifiers(typer)
                KeyBarSeparator(axis: .horizontal)
                MoreKeysMenu(typer: typer)
                Button { input.showsTouchKeyboard = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .buttonStyle(KeyCapStyle())
                .accessibilityLabel("Hide Keyboard")
            }
            .padding(FloatingKeyBar.barPadding)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

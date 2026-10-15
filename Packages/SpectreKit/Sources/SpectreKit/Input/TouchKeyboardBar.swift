#if os(iOS)
import UIKit

/// The row above the touch keyboard: the keys it lacks. Esc and Tab; Ctrl,
/// Shift, Alt and Super as sticky modifiers (tap: the next key, double tap:
/// locked); the arrows, held down for as long as the finger is (the host
/// repeats them); the rest of a PC keyboard in a menu; and a key that puts
/// the keyboard away. Scrolls sideways where the screen is narrow.
@MainActor
final class TouchKeyboardBar: UIInputView {
    private let typer: TextTyper
    private let onHide: () -> Void
    private var modifierButtons: [(TextTyper.Modifier, UIButton)] = []
    private var lastModifierTap: [TextTyper.Modifier: TimeInterval] = [:]
    private static let doubleTapInterval: TimeInterval = 0.35

    init(typer: TextTyper, onHide: @escaping () -> Void) {
        self.typer = typer
        self.onHide = onHide
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 48) }

    /// Shows the modifiers' latches (typing a key ends a one-shot latch).
    func refresh() {
        for (modifier, button) in modifierButtons {
            var config: UIButton.Configuration
            switch typer.latch(modifier) {
            case .off: config = .gray()
            case .once: config = .tinted()
            case .locked: config = .filled()
            }
            config.title = button.configuration?.title
            config.cornerStyle = .medium
            button.configuration = config
        }
    }

    // MARK: Building

    // Key caps (Esc, Tab, Ctrl, Shift, Alt, Super, F1…) read the same in
    // every language, as on a keyboard; names and menus are localized.
    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        row.addArrangedSubview(key("Esc", HIDUsage.escape))
        row.addArrangedSubview(key("Tab", HIDUsage.tab))
        for (modifier, title) in [(TextTyper.Modifier.control, "Ctrl"), (.shift, "Shift"), (.alt, "Alt"),
                                  (.superKey, "Super")] {
            let button = modifierButton(title, modifier)
            modifierButtons.append((modifier, button))
            row.addArrangedSubview(button)
        }
        row.addArrangedSubview(key(symbol: "arrow.left", HIDUsage.leftArrow, label: String(localized: "Left Arrow", bundle: .module)))
        row.addArrangedSubview(key(symbol: "arrow.up", HIDUsage.upArrow, label: String(localized: "Up Arrow", bundle: .module)))
        row.addArrangedSubview(key(symbol: "arrow.down", HIDUsage.downArrow, label: String(localized: "Down Arrow", bundle: .module)))
        row.addArrangedSubview(key(symbol: "arrow.right", HIDUsage.rightArrow, label: String(localized: "Right Arrow", bundle: .module)))
        row.addArrangedSubview(moreButton())
        row.addArrangedSubview(hideButton())
        refresh()
    }

    private func baseButton(title: String? = nil, symbol: String? = nil, label: String? = nil) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.image = symbol.map { UIImage(systemName: $0) } ?? nil
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label ?? title
        return button
    }

    /// A key held while the finger is on it.
    private func key(_ title: String? = nil, symbol: String? = nil, _ usage: UInt32, label: String? = nil) -> UIButton {
        let button = baseButton(title: title, symbol: symbol, label: label)
        button.addAction(UIAction { [weak self] _ in self?.typer.beginHold(usage) }, for: .touchDown)
        let up = UIAction { [weak self] _ in
            self?.typer.endHold()
            self?.refresh()
        }
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            button.addAction(up, for: event)
        }
        return button
    }

    private func modifierButton(_ title: String, _ modifier: TextTyper.Modifier) -> UIButton {
        let button = baseButton(title: title)
        button.addAction(UIAction { [weak self] _ in self?.modifierTapped(modifier) }, for: .touchUpInside)
        return button
    }

    /// Tap: for the next key; tapped again quickly: locked.
    private func modifierTapped(_ modifier: TextTyper.Modifier) {
        let now = ProcessInfo.processInfo.systemUptime
        let quick = lastModifierTap[modifier].map { now - $0 < Self.doubleTapInterval } ?? false
        lastModifierTap[modifier] = now
        if quick, typer.latch(modifier) == .once {
            // The first tap latched it once; the second makes it stick.
            typer.lock(modifier)
        } else {
            typer.tap(modifier)
        }
        refresh()
    }

    private func moreButton() -> UIButton {
        let button = baseButton(symbol: "ellipsis", label: String(localized: "More Keys", bundle: .module))
        func item(_ title: String, _ usage: UInt32) -> UIAction {
            UIAction(title: title) { [weak self] _ in
                self?.typer.press(usage)
                self?.refresh()
            }
        }
        let functionKeys: [UInt32] = [HIDUsage.f1, HIDUsage.f2, HIDUsage.f3, HIDUsage.f4, HIDUsage.f5, HIDUsage.f6,
                                      HIDUsage.f7, HIDUsage.f8, HIDUsage.f9, HIDUsage.f10, HIDUsage.f11, HIDUsage.f12]
        button.menu = UIMenu(children: [
            UIMenu(title: String(localized: "Function Keys", bundle: .module),
                   children: functionKeys.enumerated().map { item("F\($0.offset + 1)", $0.element) }),
            UIMenu(options: .displayInline, children: [
                item(String(localized: "Home", bundle: .module, comment: "A key on a PC keyboard"), HIDUsage.home),
                item(String(localized: "End", bundle: .module, comment: "A key on a PC keyboard"), HIDUsage.end),
                item(String(localized: "Page Up", bundle: .module, comment: "A key on a PC keyboard"), HIDUsage.pageUp),
                item(String(localized: "Page Down", bundle: .module, comment: "A key on a PC keyboard"), HIDUsage.pageDown),
            ]),
            UIMenu(options: .displayInline, children: [
                item(String(localized: "Delete", bundle: .module, comment: "A key on a PC keyboard"), HIDUsage.deleteForward),
                item(String(localized: "Insert", bundle: .module, comment: "A key on a PC keyboard"), HIDUsage.insert),
                item(String(localized: "Print Screen", bundle: .module, comment: "A key on a PC keyboard"), HIDUsage.printScreen),
                item(String(localized: "Menu", bundle: .module, comment: "A key on a PC keyboard"), HIDUsage.application),
            ]),
        ])
        button.showsMenuAsPrimaryAction = true
        return button
    }

    private func hideButton() -> UIButton {
        let button = baseButton(symbol: "keyboard.chevron.compact.down", label: String(localized: "Hide Keyboard", bundle: .module))
        button.addAction(UIAction { [weak self] _ in self?.onHide() }, for: .touchUpInside)
        return button
    }
}
#endif

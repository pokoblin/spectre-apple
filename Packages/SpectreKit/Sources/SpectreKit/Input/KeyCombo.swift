import Foundation

/// A key or a combination sent from a menu, for what a touch screen has no
/// key for: the combinations iPadOS keeps for itself even on a hardware
/// keyboard (Cmd+Tab, Cmd+Space; the iPad's Cmd is the host's Super), and
/// ones often wanted on a Linux desktop or in a terminal.
public struct KeyCombo: Hashable, Sendable, Identifiable {
    public var modifiers: [TextTyper.Modifier]
    /// None: the modifiers alone, tapped (Super opens the overview).
    public var key: UInt32?
    /// As the menu shows it. Key caps read the same in every language, as
    /// on a keyboard (docs/localization.md); key names are localized.
    public var title: String
    /// What it does on a usual Linux desktop, localized.
    public var purpose: String?

    public var id: String { title }

    public init(_ modifiers: [TextTyper.Modifier], _ key: UInt32?, title: String, purpose: String? = nil) {
        self.modifiers = modifiers
        self.key = key
        self.title = title
        self.purpose = purpose
    }

    public struct Group: Sendable, Identifiable {
        /// Nil: listed inline; otherwise a submenu with this title.
        public var submenu: String?
        public var combos: [KeyCombo]
        public var id: String { combos.first?.id ?? "" }
    }

    /// The key bar's menu of combinations, in groups.
    public static var menu: [Group] {
        func name(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .module) }
        let functionKeys: [UInt32] = [HIDUsage.f1, HIDUsage.f2, HIDUsage.f3, HIDUsage.f4, HIDUsage.f5, HIDUsage.f6,
                                      HIDUsage.f7, HIDUsage.f8, HIDUsage.f9, HIDUsage.f10, HIDUsage.f11, HIDUsage.f12]
        return [
            Group(combos: [
                KeyCombo([.superKey], nil, title: "Super", purpose: name("Overview or app menu")),
                KeyCombo([.superKey], HIDUsage.tab, title: "Super+Tab", purpose: name("Switch apps")),
                KeyCombo([.alt], HIDUsage.tab, title: "Alt+Tab", purpose: name("Switch windows")),
                KeyCombo([.control, .alt], HIDUsage.t, title: "Ctrl+Alt+T", purpose: name("Open a terminal")),
            ]),
            Group(combos: [
                KeyCombo([.control, .shift], HIDUsage.c, title: "Ctrl+Shift+C", purpose: name("Copy in a terminal")),
                KeyCombo([.control, .shift], HIDUsage.v, title: "Ctrl+Shift+V", purpose: name("Paste in a terminal")),
                KeyCombo([.control], HIDUsage.d, title: "Ctrl+D", purpose: name("End of input")),
                KeyCombo([.control], HIDUsage.z, title: "Ctrl+Z", purpose: name("Suspend")),
                KeyCombo([.control], HIDUsage.l, title: "Ctrl+L", purpose: name("Clear the screen")),
                KeyCombo([.control], HIDUsage.r, title: "Ctrl+R", purpose: name("Search history")),
            ]),
            Group(combos: [
                KeyCombo(HIDUsage.home, title: String(localized: "Home", bundle: .module, comment: "A key on a PC keyboard")),
                KeyCombo(HIDUsage.end, title: String(localized: "End", bundle: .module, comment: "A key on a PC keyboard")),
                KeyCombo(HIDUsage.pageUp, title: String(localized: "Page Up", bundle: .module, comment: "A key on a PC keyboard")),
                KeyCombo(HIDUsage.pageDown, title: String(localized: "Page Down", bundle: .module, comment: "A key on a PC keyboard")),
            ]),
            Group(submenu: name("Other Keys"), combos: [
                KeyCombo(HIDUsage.deleteForward, title: String(localized: "Delete", bundle: .module, comment: "A key on a PC keyboard")),
                KeyCombo(HIDUsage.insert, title: String(localized: "Insert", bundle: .module, comment: "A key on a PC keyboard")),
                KeyCombo(HIDUsage.printScreen, title: String(localized: "Print Screen", bundle: .module, comment: "A key on a PC keyboard")),
                KeyCombo(HIDUsage.application, title: String(localized: "Menu", bundle: .module, comment: "A key on a PC keyboard")),
            ]),
            Group(submenu: name("Function Keys"),
                  combos: functionKeys.enumerated().map { KeyCombo($0.element, title: "F\($0.offset + 1)") }),
        ]
    }
}

extension KeyCombo {
    public init(_ key: UInt32, title: String) { self.init([], key, title: title) }
}

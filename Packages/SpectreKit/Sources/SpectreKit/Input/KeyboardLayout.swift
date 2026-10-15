/// Which key, with or without Shift, types a character on the host
/// (gdp-spec.md §8.2: keys are physical positions and the host applies its
/// own layout). A client that only has characters, such as the touch
/// keyboard on iOS, has to assume the host's layout to turn them back into
/// keys.
public struct KeyboardLayout: Sendable {
    public struct Stroke: Sendable, Equatable {
        /// The key's HID usage (Keyboard/Keypad page 0x07).
        public var usage: UInt32
        public var shift: Bool

        public init(_ usage: UInt32, shift: Bool = false) {
            self.usage = usage
            self.shift = shift
        }
    }

    public let name: String
    private let strokes: [Character: Stroke]

    public init(name: String, strokes: [Character: Stroke]) {
        self.name = name
        self.strokes = strokes
    }

    /// The key that types `character`, or nil if this layout has none.
    public func stroke(for character: Character) -> Stroke? { strokes[character] }

    /// US QWERTY (ANSI): what a Linux desktop uses unless set otherwise.
    public static let usQWERTY: KeyboardLayout = {
        typealias U = HIDUsage
        var s: [Character: Stroke] = [:]
        let letters: [UInt32] = [U.a, U.b, U.c, U.d, U.e, U.f, U.g, U.h, U.i, U.j, U.k, U.l, U.m,
                                 U.n, U.o, U.p, U.q, U.r, U.s, U.t, U.u, U.v, U.w, U.x, U.y, U.z]
        for (i, usage) in letters.enumerated() {
            let lower = Character(Unicode.Scalar(UInt8(ascii: "a") + UInt8(i)))
            s[lower] = Stroke(usage)
            s[Character(lower.uppercased())] = Stroke(usage, shift: true)
        }
        // Each key: its character, then the shifted one.
        let pairs: [(UInt32, Character, Character)] = [
            (U.digit1, "1", "!"), (U.digit2, "2", "@"), (U.digit3, "3", "#"), (U.digit4, "4", "$"),
            (U.digit5, "5", "%"), (U.digit6, "6", "^"), (U.digit7, "7", "&"), (U.digit8, "8", "*"),
            (U.digit9, "9", "("), (U.digit0, "0", ")"),
            (U.graveAccentAndTilde, "`", "~"), (U.hyphen, "-", "_"), (U.equalSign, "=", "+"),
            (U.openBracket, "[", "{"), (U.closeBracket, "]", "}"), (U.backslash, "\\", "|"),
            (U.semicolon, ";", ":"), (U.quote, "'", "\""),
            (U.comma, ",", "<"), (U.period, ".", ">"), (U.slash, "/", "?"),
        ]
        for (usage, plain, shifted) in pairs {
            s[plain] = Stroke(usage)
            s[shifted] = Stroke(usage, shift: true)
        }
        s[" "] = Stroke(U.spacebar)
        s["\t"] = Stroke(U.tab)
        // "\r\n" is one Character in Swift.
        for newline: Character in ["\n", "\r", "\r\n"] { s[newline] = Stroke(U.returnOrEnter) }
        return KeyboardLayout(name: "US", strokes: s)
    }()
}

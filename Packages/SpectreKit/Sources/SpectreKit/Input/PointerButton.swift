/// Pointer buttons as gdp-spec.md §8.2 numbers them: Linux `BTN_*` codes
/// from `input-event-codes.h`.
public enum PointerButton {
    public static let left: UInt32 = 0x110
    public static let right: UInt32 = 0x111
    public static let middle: UInt32 = 0x112
    /// The thumb buttons: back and forward.
    public static let side: UInt32 = 0x113
    public static let extra: UInt32 = 0x114

    /// A platform's button number (0 primary, 1 secondary, 2 middle, 3 and
    /// up the others, as both AppKit's `buttonNumber` and UIKit's button
    /// mask count them) as a `BTN_*` code.
    public static func code(forButtonNumber n: Int) -> UInt32? {
        switch n {
        case 0: left
        case 1: right
        case 2: middle
        case 3: side
        case 4: extra
        // BTN_FORWARD, BTN_BACK, BTN_TASK follow BTN_EXTRA.
        case 5...7: extra + UInt32(n - 4)
        default: nil
        }
    }
}

#if os(macOS)
import Carbon.HIToolbox
#endif

/// macOS virtual key codes (`NSEvent.keyCode`, Carbon's `kVK_*`) as HID
/// usages. Both name physical key positions, so the mapping ignores the
/// active layout. Plain literals keep this compiling (and testable) off
/// macOS; the tests cross-check every one against Carbon's constants.
public enum MacKeyCodes {
    /// The HID usage for a virtual key code, or nil for codes with no
    /// Keyboard/Keypad-page equivalent (fn, unknown codes).
    ///
    /// `isISO` resolves the one layout-dependent pair. macOS's virtual key
    /// codes descend from ADB scan codes, and on ISO keyboards the HID
    /// driver hands out 0x0A and 0x32 the other way round from their
    /// physical HID positions:
    ///
    /// | key                          | HID  | ANSI/JIS code | ISO code |
    /// |------------------------------|------|---------------|----------|
    /// | left of 1 (`` ` `` / `§`)    | 0x35 | 0x32 Grave    | 0x0A     |
    /// | right of left Shift (ISO)    | 0x64 | 0x0A Section  | 0x32     |
    ///
    /// So `kVK_ISO_Section` is the key left of 1 on an ISO keyboard (it is
    /// labelled `§` there), and `kVK_ANSI_Grave` is the extra key by left
    /// Shift (labelled `` `~ `` on Apple ISO). The caller must say which
    /// kind of keyboard produced the event; see `currentKeyboardIsISO`.
    public static func hidUsage(forKeyCode keyCode: UInt16, isISO: Bool = false) -> UInt32? {
        switch keyCode {
        case 0x0A: isISO ? HIDUsage.graveAccentAndTilde : HIDUsage.nonUSBackslash // kVK_ISO_Section
        case 0x32: isISO ? HIDUsage.nonUSBackslash : HIDUsage.graveAccentAndTilde // kVK_ANSI_Grave
        default: fixed(keyCode)
        }
    }

    /// Every layout-independent code.
    private static func fixed(_ keyCode: UInt16) -> UInt32? {
        switch keyCode {
        // Letters.
        case 0x00: HIDUsage.a // kVK_ANSI_A
        case 0x0B: HIDUsage.b // kVK_ANSI_B
        case 0x08: HIDUsage.c // kVK_ANSI_C
        case 0x02: HIDUsage.d // kVK_ANSI_D
        case 0x0E: HIDUsage.e // kVK_ANSI_E
        case 0x03: HIDUsage.f // kVK_ANSI_F
        case 0x05: HIDUsage.g // kVK_ANSI_G
        case 0x04: HIDUsage.h // kVK_ANSI_H
        case 0x22: HIDUsage.i // kVK_ANSI_I
        case 0x26: HIDUsage.j // kVK_ANSI_J
        case 0x28: HIDUsage.k // kVK_ANSI_K
        case 0x25: HIDUsage.l // kVK_ANSI_L
        case 0x2E: HIDUsage.m // kVK_ANSI_M
        case 0x2D: HIDUsage.n // kVK_ANSI_N
        case 0x1F: HIDUsage.o // kVK_ANSI_O
        case 0x23: HIDUsage.p // kVK_ANSI_P
        case 0x0C: HIDUsage.q // kVK_ANSI_Q
        case 0x0F: HIDUsage.r // kVK_ANSI_R
        case 0x01: HIDUsage.s // kVK_ANSI_S
        case 0x11: HIDUsage.t // kVK_ANSI_T
        case 0x20: HIDUsage.u // kVK_ANSI_U
        case 0x09: HIDUsage.v // kVK_ANSI_V
        case 0x0D: HIDUsage.w // kVK_ANSI_W
        case 0x07: HIDUsage.x // kVK_ANSI_X
        case 0x10: HIDUsage.y // kVK_ANSI_Y
        case 0x06: HIDUsage.z // kVK_ANSI_Z

        // Digit row.
        case 0x12: HIDUsage.digit1 // kVK_ANSI_1
        case 0x13: HIDUsage.digit2 // kVK_ANSI_2
        case 0x14: HIDUsage.digit3 // kVK_ANSI_3
        case 0x15: HIDUsage.digit4 // kVK_ANSI_4
        case 0x17: HIDUsage.digit5 // kVK_ANSI_5
        case 0x16: HIDUsage.digit6 // kVK_ANSI_6
        case 0x1A: HIDUsage.digit7 // kVK_ANSI_7
        case 0x1C: HIDUsage.digit8 // kVK_ANSI_8
        case 0x19: HIDUsage.digit9 // kVK_ANSI_9
        case 0x1D: HIDUsage.digit0 // kVK_ANSI_0
        case 0x1B: HIDUsage.hyphen // kVK_ANSI_Minus
        case 0x18: HIDUsage.equalSign // kVK_ANSI_Equal

        // Punctuation. The ISO key left of Return (HID nonUSPound) also
        // arrives as kVK_ANSI_Backslash, so nonUSPound is never produced.
        case 0x21: HIDUsage.openBracket // kVK_ANSI_LeftBracket
        case 0x1E: HIDUsage.closeBracket // kVK_ANSI_RightBracket
        case 0x2A: HIDUsage.backslash // kVK_ANSI_Backslash
        case 0x29: HIDUsage.semicolon // kVK_ANSI_Semicolon
        case 0x27: HIDUsage.quote // kVK_ANSI_Quote
        case 0x2B: HIDUsage.comma // kVK_ANSI_Comma
        case 0x2F: HIDUsage.period // kVK_ANSI_Period
        case 0x2C: HIDUsage.slash // kVK_ANSI_Slash

        // Editing and whitespace.
        case 0x24: HIDUsage.returnOrEnter // kVK_Return
        case 0x30: HIDUsage.tab // kVK_Tab
        case 0x31: HIDUsage.spacebar // kVK_Space
        case 0x33: HIDUsage.deleteOrBackspace // kVK_Delete
        case 0x35: HIDUsage.escape // kVK_Escape
        case 0x75: HIDUsage.deleteForward // kVK_ForwardDelete

        // Modifiers.
        case 0x3B: HIDUsage.leftControl // kVK_Control
        case 0x38: HIDUsage.leftShift // kVK_Shift
        case 0x3A: HIDUsage.leftAlt // kVK_Option
        case 0x37: HIDUsage.leftGUI // kVK_Command
        case 0x3E: HIDUsage.rightControl // kVK_RightControl
        case 0x3C: HIDUsage.rightShift // kVK_RightShift
        case 0x3D: HIDUsage.rightAlt // kVK_RightOption
        case 0x36: HIDUsage.rightGUI // kVK_RightCommand
        case 0x39: HIDUsage.capsLock // kVK_CapsLock

        // Function keys. PC keyboards' Print Screen, Scroll Lock and Pause
        // reach macOS as F13, F14 and F15 and are sent as such.
        case 0x7A: HIDUsage.f1 // kVK_F1
        case 0x78: HIDUsage.f2 // kVK_F2
        case 0x63: HIDUsage.f3 // kVK_F3
        case 0x76: HIDUsage.f4 // kVK_F4
        case 0x60: HIDUsage.f5 // kVK_F5
        case 0x61: HIDUsage.f6 // kVK_F6
        case 0x62: HIDUsage.f7 // kVK_F7
        case 0x64: HIDUsage.f8 // kVK_F8
        case 0x65: HIDUsage.f9 // kVK_F9
        case 0x6D: HIDUsage.f10 // kVK_F10
        case 0x67: HIDUsage.f11 // kVK_F11
        case 0x6F: HIDUsage.f12 // kVK_F12
        case 0x69: HIDUsage.f13 // kVK_F13
        case 0x6B: HIDUsage.f14 // kVK_F14
        case 0x71: HIDUsage.f15 // kVK_F15
        case 0x6A: HIDUsage.f16 // kVK_F16
        case 0x40: HIDUsage.f17 // kVK_F17
        case 0x4F: HIDUsage.f18 // kVK_F18
        case 0x50: HIDUsage.f19 // kVK_F19
        case 0x5A: HIDUsage.f20 // kVK_F20

        // Navigation. Apple's Help key sits where PC keyboards have Insert,
        // and PC Insert arrives as kVK_Help.
        case 0x72: HIDUsage.insert // kVK_Help
        case 0x73: HIDUsage.home // kVK_Home
        case 0x77: HIDUsage.end // kVK_End
        case 0x74: HIDUsage.pageUp // kVK_PageUp
        case 0x79: HIDUsage.pageDown // kVK_PageDown
        case 0x7B: HIDUsage.leftArrow // kVK_LeftArrow
        case 0x7C: HIDUsage.rightArrow // kVK_RightArrow
        case 0x7D: HIDUsage.downArrow // kVK_DownArrow
        case 0x7E: HIDUsage.upArrow // kVK_UpArrow

        // Keypad. Clear sits where PC keypads have Num Lock.
        case 0x47: HIDUsage.keypadNumLock // kVK_ANSI_KeypadClear
        case 0x51: HIDUsage.keypadEqualSign // kVK_ANSI_KeypadEquals
        case 0x4B: HIDUsage.keypadSlash // kVK_ANSI_KeypadDivide
        case 0x43: HIDUsage.keypadAsterisk // kVK_ANSI_KeypadMultiply
        case 0x4E: HIDUsage.keypadHyphen // kVK_ANSI_KeypadMinus
        case 0x45: HIDUsage.keypadPlus // kVK_ANSI_KeypadPlus
        case 0x4C: HIDUsage.keypadEnter // kVK_ANSI_KeypadEnter
        case 0x41: HIDUsage.keypadPeriod // kVK_ANSI_KeypadDecimal
        case 0x52: HIDUsage.keypad0 // kVK_ANSI_Keypad0
        case 0x53: HIDUsage.keypad1 // kVK_ANSI_Keypad1
        case 0x54: HIDUsage.keypad2 // kVK_ANSI_Keypad2
        case 0x55: HIDUsage.keypad3 // kVK_ANSI_Keypad3
        case 0x56: HIDUsage.keypad4 // kVK_ANSI_Keypad4
        case 0x57: HIDUsage.keypad5 // kVK_ANSI_Keypad5
        case 0x58: HIDUsage.keypad6 // kVK_ANSI_Keypad6
        case 0x59: HIDUsage.keypad7 // kVK_ANSI_Keypad7
        case 0x5B: HIDUsage.keypad8 // kVK_ANSI_Keypad8
        case 0x5C: HIDUsage.keypad9 // kVK_ANSI_Keypad9

        // Media and PC extras.
        case 0x48: HIDUsage.volumeUp // kVK_VolumeUp
        case 0x49: HIDUsage.volumeDown // kVK_VolumeDown
        case 0x4A: HIDUsage.mute // kVK_Mute
        case 0x6E: HIDUsage.application // kVK_ContextualMenu

        // JIS.
        case 0x5D: HIDUsage.international3 // kVK_JIS_Yen
        case 0x5E: HIDUsage.international1 // kVK_JIS_Underscore
        case 0x5F: HIDUsage.keypadComma // kVK_JIS_KeypadComma
        case 0x66: HIDUsage.lang2 // kVK_JIS_Eisu
        case 0x68: HIDUsage.lang1 // kVK_JIS_Kana

        // kVK_Function (0x3F) and anything unknown: fn has no usage on the
        // Keyboard/Keypad page and never reaches the host.
        default: nil
        }
    }

    /// The modifier keys: a `flagsChanged` event carries one of these.
    public static let modifierKeyCodes: Set<UInt16> = [
        0x38, 0x3C, // kVK_Shift, kVK_RightShift
        0x3B, 0x3E, // kVK_Control, kVK_RightControl
        0x3A, 0x3D, // kVK_Option, kVK_RightOption
        0x37, 0x36, // kVK_Command, kVK_RightCommand
        0x39, // kVK_CapsLock
        0x3F, // kVK_Function
    ]

    /// The device-dependent `NSEvent.modifierFlags` bit (IOLLEvent.h's
    /// `NX_DEVICE*KEYMASK`) for a side-specific modifier: `flags & mask != 0`
    /// means that key is down after a `flagsChanged`. Nil for Caps Lock (its
    /// flag tracks the lock, not the key: send press and release on each
    /// change), fn and non-modifiers.
    public static func deviceFlagMask(forKeyCode keyCode: UInt16) -> UInt? {
        switch keyCode {
        case 0x3B: 0x0000_0001 // kVK_Control: NX_DEVICELCTLKEYMASK
        case 0x38: 0x0000_0002 // kVK_Shift: NX_DEVICELSHIFTKEYMASK
        case 0x3C: 0x0000_0004 // kVK_RightShift: NX_DEVICERSHIFTKEYMASK
        case 0x37: 0x0000_0008 // kVK_Command: NX_DEVICELCMDKEYMASK
        case 0x36: 0x0000_0010 // kVK_RightCommand: NX_DEVICERCMDKEYMASK
        case 0x3A: 0x0000_0020 // kVK_Option: NX_DEVICELALTKEYMASK
        case 0x3D: 0x0000_0040 // kVK_RightOption: NX_DEVICERALTKEYMASK
        case 0x3E: 0x0000_2000 // kVK_RightControl: NX_DEVICERCTLKEYMASK
        default: nil
        }
    }

    /// The side-specific modifiers: key code, HID usage, device-dependent
    /// flag (``deviceFlagMask(forKeyCode:)``) and the device-independent
    /// flag of their kind (`NSEvent.ModifierFlags` raw values).
    private static let modifiers: [(keyCode: UInt16, usage: UInt32, device: UInt, kind: UInt)] = [
        (0x38, HIDUsage.leftShift, 0x0000_0002, 0x0002_0000), (0x3C, HIDUsage.rightShift, 0x0000_0004, 0x0002_0000),
        (0x3B, HIDUsage.leftControl, 0x0000_0001, 0x0004_0000), (0x3E, HIDUsage.rightControl, 0x0000_2000, 0x0004_0000),
        (0x3A, HIDUsage.leftAlt, 0x0000_0020, 0x0008_0000), (0x3D, HIDUsage.rightAlt, 0x0000_0040, 0x0008_0000),
        (0x37, HIDUsage.leftGUI, 0x0000_0008, 0x0010_0000), (0x36, HIDUsage.rightGUI, 0x0000_0010, 0x0010_0000),
    ]

    /// Which of the eight side-specific modifiers are down, from an event's
    /// `modifierFlags`: the whole state, not just the key that changed. A
    /// `flagsChanged` can go missing (macOS's screenshot UI takes the
    /// keyboard and later sends one with key code 0 and no flags at all),
    /// so every event that carries flags re-states them.
    ///
    /// A kind's device-independent flag clear: both sides up. Set, with
    /// device bits: those say which side. Set without any (an event
    /// synthesized without them): the sides keep `held`, and the key that
    /// changed (`changedKeyCode`, for a `flagsChanged`) is down.
    public static func modifierStates(flags: UInt, changedKeyCode: UInt16?, held: Set<UInt32>)
        -> [(usage: UInt32, pressed: Bool)] {
        modifiers.map { m in
            guard flags & m.kind != 0 else { return (m.usage, false) }
            let kindDevice = modifiers.filter { $0.kind == m.kind }.reduce(UInt(0)) { $0 | $1.device }
            if flags & kindDevice != 0 { return (m.usage, flags & m.device != 0) }
            return (m.usage, held.contains(m.usage) || changedKeyCode == m.keyCode)
        }
    }

    #if os(macOS)
    /// Whether the keyboard that last typed is ISO, for `hidUsage(forKeyCode:isISO:)`.
    public static var currentKeyboardIsISO: Bool {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
    }
    #endif
}

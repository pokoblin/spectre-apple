/// USB HID usages on the Keyboard/Keypad page (0x07), as the HID Usage
/// Tables number them. Keys are physical positions named after their US
/// legend, not characters. Names follow UIKit's `UIKeyboardHIDUsage` without
/// its `keyboard` prefix.
public enum HIDUsage {
    public static let a: UInt32 = 0x04
    public static let b: UInt32 = 0x05
    public static let c: UInt32 = 0x06
    public static let d: UInt32 = 0x07
    public static let e: UInt32 = 0x08
    public static let f: UInt32 = 0x09
    public static let g: UInt32 = 0x0A
    public static let h: UInt32 = 0x0B
    public static let i: UInt32 = 0x0C
    public static let j: UInt32 = 0x0D
    public static let k: UInt32 = 0x0E
    public static let l: UInt32 = 0x0F
    public static let m: UInt32 = 0x10
    public static let n: UInt32 = 0x11
    public static let o: UInt32 = 0x12
    public static let p: UInt32 = 0x13
    public static let q: UInt32 = 0x14
    public static let r: UInt32 = 0x15
    public static let s: UInt32 = 0x16
    public static let t: UInt32 = 0x17
    public static let u: UInt32 = 0x18
    public static let v: UInt32 = 0x19
    public static let w: UInt32 = 0x1A
    public static let x: UInt32 = 0x1B
    public static let y: UInt32 = 0x1C
    public static let z: UInt32 = 0x1D

    public static let digit1: UInt32 = 0x1E
    public static let digit2: UInt32 = 0x1F
    public static let digit3: UInt32 = 0x20
    public static let digit4: UInt32 = 0x21
    public static let digit5: UInt32 = 0x22
    public static let digit6: UInt32 = 0x23
    public static let digit7: UInt32 = 0x24
    public static let digit8: UInt32 = 0x25
    public static let digit9: UInt32 = 0x26
    public static let digit0: UInt32 = 0x27

    public static let returnOrEnter: UInt32 = 0x28
    public static let escape: UInt32 = 0x29
    /// Backspace (Mac "delete").
    public static let deleteOrBackspace: UInt32 = 0x2A
    public static let tab: UInt32 = 0x2B
    public static let spacebar: UInt32 = 0x2C
    public static let hyphen: UInt32 = 0x2D
    public static let equalSign: UInt32 = 0x2E
    public static let openBracket: UInt32 = 0x2F
    public static let closeBracket: UInt32 = 0x30
    public static let backslash: UInt32 = 0x31
    /// ISO: the key left of Return (`#~` on UK layouts). Hosts usually treat
    /// it like `backslash`.
    public static let nonUSPound: UInt32 = 0x32
    public static let semicolon: UInt32 = 0x33
    public static let quote: UInt32 = 0x34
    /// The key left of 1 (`` ` `` on ANSI, `§` on Apple ISO, 半角/全角 on JIS).
    public static let graveAccentAndTilde: UInt32 = 0x35
    public static let comma: UInt32 = 0x36
    public static let period: UInt32 = 0x37
    public static let slash: UInt32 = 0x38
    public static let capsLock: UInt32 = 0x39

    public static let f1: UInt32 = 0x3A
    public static let f2: UInt32 = 0x3B
    public static let f3: UInt32 = 0x3C
    public static let f4: UInt32 = 0x3D
    public static let f5: UInt32 = 0x3E
    public static let f6: UInt32 = 0x3F
    public static let f7: UInt32 = 0x40
    public static let f8: UInt32 = 0x41
    public static let f9: UInt32 = 0x42
    public static let f10: UInt32 = 0x43
    public static let f11: UInt32 = 0x44
    public static let f12: UInt32 = 0x45

    public static let printScreen: UInt32 = 0x46
    public static let scrollLock: UInt32 = 0x47
    public static let pause: UInt32 = 0x48
    public static let insert: UInt32 = 0x49
    public static let home: UInt32 = 0x4A
    public static let pageUp: UInt32 = 0x4B
    /// Forward delete (Mac fn-delete / ⌦).
    public static let deleteForward: UInt32 = 0x4C
    public static let end: UInt32 = 0x4D
    public static let pageDown: UInt32 = 0x4E
    public static let rightArrow: UInt32 = 0x4F
    public static let leftArrow: UInt32 = 0x50
    public static let downArrow: UInt32 = 0x51
    public static let upArrow: UInt32 = 0x52

    /// Num Lock, or Clear on Apple keypads.
    public static let keypadNumLock: UInt32 = 0x53
    public static let keypadSlash: UInt32 = 0x54
    public static let keypadAsterisk: UInt32 = 0x55
    public static let keypadHyphen: UInt32 = 0x56
    public static let keypadPlus: UInt32 = 0x57
    public static let keypadEnter: UInt32 = 0x58
    public static let keypad1: UInt32 = 0x59
    public static let keypad2: UInt32 = 0x5A
    public static let keypad3: UInt32 = 0x5B
    public static let keypad4: UInt32 = 0x5C
    public static let keypad5: UInt32 = 0x5D
    public static let keypad6: UInt32 = 0x5E
    public static let keypad7: UInt32 = 0x5F
    public static let keypad8: UInt32 = 0x60
    public static let keypad9: UInt32 = 0x61
    public static let keypad0: UInt32 = 0x62
    public static let keypadPeriod: UInt32 = 0x63

    /// ISO: the extra key right of left Shift (`\|` on UK, `<>` on German,
    /// `` `~ `` on Apple ISO).
    public static let nonUSBackslash: UInt32 = 0x64
    /// The PC context-menu key.
    public static let application: UInt32 = 0x65
    public static let power: UInt32 = 0x66
    public static let keypadEqualSign: UInt32 = 0x67

    public static let f13: UInt32 = 0x68
    public static let f14: UInt32 = 0x69
    public static let f15: UInt32 = 0x6A
    public static let f16: UInt32 = 0x6B
    public static let f17: UInt32 = 0x6C
    public static let f18: UInt32 = 0x6D
    public static let f19: UInt32 = 0x6E
    public static let f20: UInt32 = 0x6F
    public static let f21: UInt32 = 0x70
    public static let f22: UInt32 = 0x71
    public static let f23: UInt32 = 0x72
    public static let f24: UInt32 = 0x73

    public static let help: UInt32 = 0x75
    public static let menu: UInt32 = 0x76
    public static let mute: UInt32 = 0x7F
    public static let volumeUp: UInt32 = 0x80
    public static let volumeDown: UInt32 = 0x81
    /// JIS / Brazilian keypad comma.
    public static let keypadComma: UInt32 = 0x85

    /// JIS `ろ` / `_` (left of right Shift).
    public static let international1: UInt32 = 0x87
    /// JIS カタカナ/ひらがな.
    public static let international2: UInt32 = 0x88
    /// JIS `¥` / `|` (left of Backspace).
    public static let international3: UInt32 = 0x89
    /// JIS 変換 (henkan).
    public static let international4: UInt32 = 0x8A
    /// JIS 無変換 (muhenkan).
    public static let international5: UInt32 = 0x8B

    /// Kana (Mac JIS かな) / Korean Hangul.
    public static let lang1: UInt32 = 0x90
    /// Eisu (Mac JIS 英数) / Korean Hanja.
    public static let lang2: UInt32 = 0x91
    /// JIS Katakana.
    public static let lang3: UInt32 = 0x92
    /// JIS Hiragana.
    public static let lang4: UInt32 = 0x93
    /// JIS 半角/全角 (Zenkaku/Hankaku).
    public static let lang5: UInt32 = 0x94

    public static let leftControl: UInt32 = 0xE0
    public static let leftShift: UInt32 = 0xE1
    /// Option on Apple keyboards.
    public static let leftAlt: UInt32 = 0xE2
    /// Command on Apple keyboards, Super/Windows elsewhere.
    public static let leftGUI: UInt32 = 0xE3
    public static let rightControl: UInt32 = 0xE4
    public static let rightShift: UInt32 = 0xE5
    public static let rightAlt: UInt32 = 0xE6
    public static let rightGUI: UInt32 = 0xE7

    /// The eight modifier usages, 0xE0 through 0xE7.
    public static func isModifier(_ usage: UInt32) -> Bool {
        (leftControl...rightGUI).contains(usage)
    }
}

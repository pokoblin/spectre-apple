#if canImport(Carbon)
import Carbon.HIToolbox
#endif
#if os(iOS)
import UIKit
#endif
import Testing
@testable import SpectreKit

@Suite("HID usages")
struct HIDUsageTests {
    /// Spot checks against the HID Usage Tables, Keyboard/Keypad page.
    @Test func matchesUsageTables() {
        #expect(HIDUsage.a == 0x04)
        #expect(HIDUsage.z == 0x1D)
        #expect(HIDUsage.digit1 == 0x1E)
        #expect(HIDUsage.digit0 == 0x27)
        #expect(HIDUsage.returnOrEnter == 0x28)
        #expect(HIDUsage.spacebar == 0x2C)
        #expect(HIDUsage.graveAccentAndTilde == 0x35)
        #expect(HIDUsage.capsLock == 0x39)
        #expect(HIDUsage.f1 == 0x3A)
        #expect(HIDUsage.f12 == 0x45)
        #expect(HIDUsage.f13 == 0x68)
        #expect(HIDUsage.f24 == 0x73)
        #expect(HIDUsage.deleteForward == 0x4C)
        #expect(HIDUsage.upArrow == 0x52)
        #expect(HIDUsage.keypadNumLock == 0x53)
        #expect(HIDUsage.keypad0 == 0x62)
        #expect(HIDUsage.nonUSBackslash == 0x64)
        #expect(HIDUsage.keypadEqualSign == 0x67)
        #expect(HIDUsage.mute == 0x7F)
        #expect(HIDUsage.keypadComma == 0x85)
        #expect(HIDUsage.international1 == 0x87)
        #expect(HIDUsage.international3 == 0x89)
        #expect(HIDUsage.lang1 == 0x90)
        #expect(HIDUsage.lang2 == 0x91)
        #expect(HIDUsage.leftControl == 0xE0)
        #expect(HIDUsage.leftGUI == 0xE3)
        #expect(HIDUsage.rightAlt == 0xE6)
        #expect(HIDUsage.rightGUI == 0xE7)
    }

    @Test func modifiers() {
        #expect((0xE0...0xE7).allSatisfy(HIDUsage.isModifier))
        #expect(!HIDUsage.isModifier(0xDF))
        #expect(!HIDUsage.isModifier(0xE8))
        #expect(!HIDUsage.isModifier(HIDUsage.capsLock))
    }

    #if os(iOS)
    @Test func matchesUIKit() {
        let pairs: [(UInt32, UIKeyboardHIDUsage)] = [
            (HIDUsage.a, .keyboardA), (HIDUsage.digit0, .keyboard0),
            (HIDUsage.returnOrEnter, .keyboardReturnOrEnter),
            (HIDUsage.nonUSPound, .keyboardNonUSPound),
            (HIDUsage.graveAccentAndTilde, .keyboardGraveAccentAndTilde),
            (HIDUsage.f24, .keyboardF24), (HIDUsage.printScreen, .keyboardPrintScreen),
            (HIDUsage.deleteForward, .keyboardDeleteForward),
            (HIDUsage.keypadNumLock, .keypadNumLock), (HIDUsage.keypadPeriod, .keypadPeriod),
            (HIDUsage.nonUSBackslash, .keyboardNonUSBackslash),
            (HIDUsage.application, .keyboardApplication),
            (HIDUsage.keypadEqualSign, .keypadEqualSign), (HIDUsage.menu, .keyboardMenu),
            (HIDUsage.volumeDown, .keyboardVolumeDown), (HIDUsage.keypadComma, .keypadComma),
            (HIDUsage.international5, .keyboardInternational5),
            (HIDUsage.lang1, .keyboardLANG1), (HIDUsage.lang5, .keyboardLANG5),
            (HIDUsage.leftGUI, .keyboardLeftGUI), (HIDUsage.rightGUI, .keyboardRightGUI),
        ]
        for (usage, uikit) in pairs { #expect(usage == UInt32(uikit.rawValue)) }
    }
    #endif
}

@Suite("Mac key codes")
struct MacKeyCodeTests {
    /// Every code that maps, for either keyboard kind.
    func table(isISO: Bool) -> [UInt16: UInt32] {
        var out: [UInt16: UInt32] = [:]
        for code in UInt16(0)...0xFF {
            if let usage = MacKeyCodes.hidUsage(forKeyCode: code, isISO: isISO) { out[code] = usage }
        }
        return out
    }

    /// No two keys send the same usage. There are no intentional duplicates:
    /// keys macOS itself merges (ISO nonUSPound into Backslash, PC Print
    /// Screen into F13) arrive as one code, so they cannot collide here.
    @Test(arguments: [false, true])
    func usagesAreUnique(isISO: Bool) {
        let t = table(isISO: isISO)
        #expect(Set(t.values).count == t.count)
        #expect(t.count == 119)
    }

    @Test func isoSwap() {
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0x32) == HIDUsage.graveAccentAndTilde)
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0x0A) == HIDUsage.nonUSBackslash)
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0x32, isISO: true) == HIDUsage.nonUSBackslash)
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0x0A, isISO: true) == HIDUsage.graveAccentAndTilde)
        // Only that pair moves.
        let ansi = table(isISO: false), iso = table(isISO: true)
        #expect(Set(ansi.keys) == Set(iso.keys))
        #expect(ansi.keys.filter { ansi[$0] != iso[$0] }.sorted() == [0x0A, 0x32])
    }

    @Test func unmapped() {
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0x3F) == nil) // fn
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0x34) == nil)
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0x7F) == nil)
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0xFFFF) == nil)
    }

    @Test func modifierKeys() {
        #expect(MacKeyCodes.modifierKeyCodes.count == 10)
        for code in MacKeyCodes.modifierKeyCodes where code != 0x3F && code != 0x39 {
            #expect(MacKeyCodes.hidUsage(forKeyCode: code).map(HIDUsage.isModifier) == true)
            #expect(MacKeyCodes.deviceFlagMask(forKeyCode: code) != nil)
        }
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0x39) == HIDUsage.capsLock)
        // Only modifier keys are in the set.
        for (code, usage) in table(isISO: false) where HIDUsage.isModifier(usage) {
            #expect(MacKeyCodes.modifierKeyCodes.contains(code))
        }
    }

    @Test func deviceFlagMasks() {
        #expect(MacKeyCodes.deviceFlagMask(forKeyCode: 0x3B) == 0x01)   // left control
        #expect(MacKeyCodes.deviceFlagMask(forKeyCode: 0x38) == 0x02)   // left shift
        #expect(MacKeyCodes.deviceFlagMask(forKeyCode: 0x3C) == 0x04)   // right shift
        #expect(MacKeyCodes.deviceFlagMask(forKeyCode: 0x37) == 0x08)   // left command
        #expect(MacKeyCodes.deviceFlagMask(forKeyCode: 0x36) == 0x10)   // right command
        #expect(MacKeyCodes.deviceFlagMask(forKeyCode: 0x3A) == 0x20)   // left option
        #expect(MacKeyCodes.deviceFlagMask(forKeyCode: 0x3D) == 0x40)   // right option
        #expect(MacKeyCodes.deviceFlagMask(forKeyCode: 0x3E) == 0x2000) // right control
        #expect(MacKeyCodes.deviceFlagMask(forKeyCode: 0x39) == nil)    // caps lock
        #expect(MacKeyCodes.deviceFlagMask(forKeyCode: 0x3F) == nil)    // fn
        #expect(MacKeyCodes.deviceFlagMask(forKeyCode: 0x00) == nil)
    }

    #if canImport(Carbon)
    /// Cross-checks the literal table against Carbon's kVK_* constants.
    @Test func matchesCarbon() {
        let expected: [(Int, UInt32)] = [
            (kVK_ANSI_A, HIDUsage.a), (kVK_ANSI_B, HIDUsage.b), (kVK_ANSI_C, HIDUsage.c),
            (kVK_ANSI_D, HIDUsage.d), (kVK_ANSI_E, HIDUsage.e), (kVK_ANSI_F, HIDUsage.f),
            (kVK_ANSI_G, HIDUsage.g), (kVK_ANSI_H, HIDUsage.h), (kVK_ANSI_I, HIDUsage.i),
            (kVK_ANSI_J, HIDUsage.j), (kVK_ANSI_K, HIDUsage.k), (kVK_ANSI_L, HIDUsage.l),
            (kVK_ANSI_M, HIDUsage.m), (kVK_ANSI_N, HIDUsage.n), (kVK_ANSI_O, HIDUsage.o),
            (kVK_ANSI_P, HIDUsage.p), (kVK_ANSI_Q, HIDUsage.q), (kVK_ANSI_R, HIDUsage.r),
            (kVK_ANSI_S, HIDUsage.s), (kVK_ANSI_T, HIDUsage.t), (kVK_ANSI_U, HIDUsage.u),
            (kVK_ANSI_V, HIDUsage.v), (kVK_ANSI_W, HIDUsage.w), (kVK_ANSI_X, HIDUsage.x),
            (kVK_ANSI_Y, HIDUsage.y), (kVK_ANSI_Z, HIDUsage.z),

            (kVK_ANSI_1, HIDUsage.digit1), (kVK_ANSI_2, HIDUsage.digit2),
            (kVK_ANSI_3, HIDUsage.digit3), (kVK_ANSI_4, HIDUsage.digit4),
            (kVK_ANSI_5, HIDUsage.digit5), (kVK_ANSI_6, HIDUsage.digit6),
            (kVK_ANSI_7, HIDUsage.digit7), (kVK_ANSI_8, HIDUsage.digit8),
            (kVK_ANSI_9, HIDUsage.digit9), (kVK_ANSI_0, HIDUsage.digit0),
            (kVK_ANSI_Minus, HIDUsage.hyphen), (kVK_ANSI_Equal, HIDUsage.equalSign),

            (kVK_ANSI_LeftBracket, HIDUsage.openBracket),
            (kVK_ANSI_RightBracket, HIDUsage.closeBracket),
            (kVK_ANSI_Backslash, HIDUsage.backslash),
            (kVK_ANSI_Semicolon, HIDUsage.semicolon), (kVK_ANSI_Quote, HIDUsage.quote),
            (kVK_ANSI_Comma, HIDUsage.comma), (kVK_ANSI_Period, HIDUsage.period),
            (kVK_ANSI_Slash, HIDUsage.slash), (kVK_ANSI_Grave, HIDUsage.graveAccentAndTilde),

            (kVK_Return, HIDUsage.returnOrEnter), (kVK_Tab, HIDUsage.tab),
            (kVK_Space, HIDUsage.spacebar), (kVK_Delete, HIDUsage.deleteOrBackspace),
            (kVK_Escape, HIDUsage.escape), (kVK_ForwardDelete, HIDUsage.deleteForward),

            (kVK_Control, HIDUsage.leftControl), (kVK_RightControl, HIDUsage.rightControl),
            (kVK_Shift, HIDUsage.leftShift), (kVK_RightShift, HIDUsage.rightShift),
            (kVK_Option, HIDUsage.leftAlt), (kVK_RightOption, HIDUsage.rightAlt),
            (kVK_Command, HIDUsage.leftGUI), (kVK_RightCommand, HIDUsage.rightGUI),
            (kVK_CapsLock, HIDUsage.capsLock),

            (kVK_F1, HIDUsage.f1), (kVK_F2, HIDUsage.f2), (kVK_F3, HIDUsage.f3),
            (kVK_F4, HIDUsage.f4), (kVK_F5, HIDUsage.f5), (kVK_F6, HIDUsage.f6),
            (kVK_F7, HIDUsage.f7), (kVK_F8, HIDUsage.f8), (kVK_F9, HIDUsage.f9),
            (kVK_F10, HIDUsage.f10), (kVK_F11, HIDUsage.f11), (kVK_F12, HIDUsage.f12),
            (kVK_F13, HIDUsage.f13), (kVK_F14, HIDUsage.f14), (kVK_F15, HIDUsage.f15),
            (kVK_F16, HIDUsage.f16), (kVK_F17, HIDUsage.f17), (kVK_F18, HIDUsage.f18),
            (kVK_F19, HIDUsage.f19), (kVK_F20, HIDUsage.f20),

            (kVK_Help, HIDUsage.insert), (kVK_Home, HIDUsage.home), (kVK_End, HIDUsage.end),
            (kVK_PageUp, HIDUsage.pageUp), (kVK_PageDown, HIDUsage.pageDown),
            (kVK_LeftArrow, HIDUsage.leftArrow), (kVK_RightArrow, HIDUsage.rightArrow),
            (kVK_DownArrow, HIDUsage.downArrow), (kVK_UpArrow, HIDUsage.upArrow),

            (kVK_ANSI_KeypadClear, HIDUsage.keypadNumLock),
            (kVK_ANSI_KeypadEquals, HIDUsage.keypadEqualSign),
            (kVK_ANSI_KeypadDivide, HIDUsage.keypadSlash),
            (kVK_ANSI_KeypadMultiply, HIDUsage.keypadAsterisk),
            (kVK_ANSI_KeypadMinus, HIDUsage.keypadHyphen),
            (kVK_ANSI_KeypadPlus, HIDUsage.keypadPlus),
            (kVK_ANSI_KeypadEnter, HIDUsage.keypadEnter),
            (kVK_ANSI_KeypadDecimal, HIDUsage.keypadPeriod),
            (kVK_ANSI_Keypad0, HIDUsage.keypad0), (kVK_ANSI_Keypad1, HIDUsage.keypad1),
            (kVK_ANSI_Keypad2, HIDUsage.keypad2), (kVK_ANSI_Keypad3, HIDUsage.keypad3),
            (kVK_ANSI_Keypad4, HIDUsage.keypad4), (kVK_ANSI_Keypad5, HIDUsage.keypad5),
            (kVK_ANSI_Keypad6, HIDUsage.keypad6), (kVK_ANSI_Keypad7, HIDUsage.keypad7),
            (kVK_ANSI_Keypad8, HIDUsage.keypad8), (kVK_ANSI_Keypad9, HIDUsage.keypad9),

            (kVK_VolumeUp, HIDUsage.volumeUp), (kVK_VolumeDown, HIDUsage.volumeDown),
            (kVK_Mute, HIDUsage.mute), (kVK_ContextualMenu, HIDUsage.application),

            (kVK_ISO_Section, HIDUsage.nonUSBackslash),
            (kVK_JIS_Yen, HIDUsage.international3),
            (kVK_JIS_Underscore, HIDUsage.international1),
            (kVK_JIS_KeypadComma, HIDUsage.keypadComma),
            (kVK_JIS_Eisu, HIDUsage.lang2), (kVK_JIS_Kana, HIDUsage.lang1),
        ]
        for (code, usage) in expected {
            #expect(MacKeyCodes.hidUsage(forKeyCode: UInt16(code)) == usage, "kVK 0x\(String(code, radix: 16))")
        }
        // Every mapped code is one of Carbon's.
        #expect(Set(expected.map { UInt16($0.0) }) == Set(table(isISO: false).keys))
        #expect(MacKeyCodes.hidUsage(forKeyCode: UInt16(kVK_Function)) == nil)
        #expect(MacKeyCodes.hidUsage(forKeyCode: UInt16(kVK_ISO_Section), isISO: true)
                == HIDUsage.graveAccentAndTilde)
        #expect(MacKeyCodes.hidUsage(forKeyCode: UInt16(kVK_ANSI_Grave), isISO: true)
                == HIDUsage.nonUSBackslash)

        let modifiers = [kVK_Shift, kVK_RightShift, kVK_Control, kVK_RightControl, kVK_Option,
                         kVK_RightOption, kVK_Command, kVK_RightCommand, kVK_CapsLock, kVK_Function]
        #expect(Set(modifiers.map { UInt16($0) }) == MacKeyCodes.modifierKeyCodes)
    }

    @Test func keyboardTypeQueryRuns() {
        _ = MacKeyCodes.currentKeyboardIsISO
    }
    #endif
}

import GDPKit
import Testing
@testable import SpectreKit

@Suite("US layout (§8.2)")
struct KeyboardLayoutTests {
    let us = KeyboardLayout.usQWERTY

    @Test func everyPrintableASCIICharacterHasAKey() {
        for scalar in UInt8(0x20)...UInt8(0x7E) {
            #expect(us.stroke(for: Character(Unicode.Scalar(scalar))) != nil, "no key for \(Unicode.Scalar(scalar))")
        }
    }

    @Test func lettersDigitsAndSymbols() {
        typealias S = KeyboardLayout.Stroke
        #expect(us.stroke(for: "a") == S(HIDUsage.a))
        #expect(us.stroke(for: "Z") == S(HIDUsage.z, shift: true))
        #expect(us.stroke(for: "1") == S(HIDUsage.digit1))
        #expect(us.stroke(for: "!") == S(HIDUsage.digit1, shift: true))
        #expect(us.stroke(for: ")") == S(HIDUsage.digit0, shift: true))
        #expect(us.stroke(for: "~") == S(HIDUsage.graveAccentAndTilde, shift: true))
        #expect(us.stroke(for: "\"") == S(HIDUsage.quote, shift: true))
        #expect(us.stroke(for: "?") == S(HIDUsage.slash, shift: true))
        #expect(us.stroke(for: " ") == S(HIDUsage.spacebar))
        #expect(us.stroke(for: "\n") == S(HIDUsage.returnOrEnter))
        #expect(us.stroke(for: "\r\n") == S(HIDUsage.returnOrEnter))
        #expect(us.stroke(for: "\t") == S(HIDUsage.tab))
    }

    @Test func charactersOutsideTheLayoutHaveNone() {
        for character: Character in ["é", "中", "😀", "€", "\u{7F}"] {
            #expect(us.stroke(for: character) == nil)
        }
    }
}

@MainActor
@Suite("Touch keyboard typing (§8.2)")
struct TextTyperTests {
    let sink = RecordingSink()
    let typer: TextTyper
    let sender: InputSender

    init() {
        sender = InputSender(sink: sink)
        typer = TextTyper(sender: sender)
    }

    typealias E = RecordingSink.Event
    static let shift = HIDUsage.leftShift, ctrl = HIDUsage.leftControl

    @Test func charactersBecomeStrokes() {
        #expect(typer.type("aB!") == 0)
        #expect(sink.events == [
            .key(HIDUsage.a, true), .key(HIDUsage.a, false),
            .key(Self.shift, true), .key(HIDUsage.b, true), .key(HIDUsage.b, false), .key(Self.shift, false),
            .key(Self.shift, true), .key(HIDUsage.digit1, true), .key(HIDUsage.digit1, false), .key(Self.shift, false),
        ])
        #expect(sender.heldKeys.isEmpty)
    }

    @Test func untypableCharactersAreSkippedAndCounted() {
        #expect(typer.type("né中") == 2)
        #expect(sink.events == [.key(HIDUsage.n, true), .key(HIDUsage.n, false)])
    }

    @Test func aTappedModifierAppliesToTheNextStrokeOnly() {
        typer.tap(.control)
        #expect(typer.latch(.control) == .once)
        typer.type("cc")
        #expect(sink.events == [
            .key(Self.ctrl, true), .key(HIDUsage.c, true), .key(HIDUsage.c, false), .key(Self.ctrl, false),
            .key(HIDUsage.c, true), .key(HIDUsage.c, false),
        ])
        #expect(typer.latch(.control) == .off)
    }

    @Test func aLockedModifierStaysUntilTapped() {
        typer.lock(.shift)
        typer.press(HIDUsage.rightArrow)
        typer.press(HIDUsage.rightArrow)
        #expect(typer.latch(.shift) == .locked)
        typer.tap(.shift)
        #expect(typer.latch(.shift) == .off)
        #expect(sink.events == [
            .key(Self.shift, true), .key(HIDUsage.rightArrow, true), .key(HIDUsage.rightArrow, false), .key(Self.shift, false),
            .key(Self.shift, true), .key(HIDUsage.rightArrow, true), .key(HIDUsage.rightArrow, false), .key(Self.shift, false),
        ])
    }

    @Test func shiftIsPressedOnceWhenBothTheCharacterAndTheLatchWantIt() {
        typer.tap(.shift)
        typer.tap(.control)
        typer.type("T") // Ctrl+Shift+T
        #expect(sink.events == [
            .key(Self.ctrl, true), .key(Self.shift, true),
            .key(HIDUsage.t, true), .key(HIDUsage.t, false),
            .key(Self.shift, false), .key(Self.ctrl, false),
        ])
    }

    @Test func tappingTwiceTurnsItOffAndLockingTwiceToo() {
        typer.tap(.alt)
        typer.tap(.alt)
        #expect(typer.latch(.alt) == .off)
        typer.lock(.superKey)
        typer.lock(.superKey)
        #expect(typer.latch(.superKey) == .off)
        typer.lock(.alt)
        typer.clearLatches()
        #expect(typer.latch(.alt) == .off)
        #expect(sink.events.isEmpty)
    }

    @Test func aHeldKeyStaysDownUntilLetGo() {
        typer.tap(.control)
        typer.beginHold(HIDUsage.leftArrow)
        #expect(sink.events == [.key(Self.ctrl, true), .key(HIDUsage.leftArrow, true)])
        #expect(typer.latch(.control) == .once) // until the key is let go
        typer.endHold()
        #expect(sink.events.suffix(2) == [.key(HIDUsage.leftArrow, false), .key(Self.ctrl, false)])
        #expect(typer.latch(.control) == .off)
        typer.endHold() // nothing held: nothing sent
        #expect(sink.events.count == 4)
    }

    @Test func typingOrClearingLetsGoOfAHeldKey() {
        typer.beginHold(HIDUsage.upArrow)
        typer.type("a")
        typer.beginHold(HIDUsage.downArrow)
        typer.clearLatches()
        #expect(sink.events == [
            .key(HIDUsage.upArrow, true), .key(HIDUsage.upArrow, false),
            .key(HIDUsage.a, true), .key(HIDUsage.a, false),
            .key(HIDUsage.downArrow, true), .key(HIDUsage.downArrow, false),
        ])
    }

    @Test func sessionInputCountsWhatItCouldNotType() {
        let input = SessionInput(sink: sink)
        input.type("ok")
        #expect(input.untypable == nil)
        input.type("é!")
        #expect(input.untypable == SessionInput.Untypable(count: 1, serial: 1))
        input.type("中文")
        #expect(input.untypable == SessionInput.Untypable(count: 2, serial: 2))
    }

    @Test func hidingTheKeyboardDropsTheLatches() {
        let input = SessionInput(sink: sink)
        input.showsTouchKeyboard = true
        input.typer.lock(.control)
        input.showsTouchKeyboard = false
        #expect(input.typer.latch(.control) == .off)
    }
}

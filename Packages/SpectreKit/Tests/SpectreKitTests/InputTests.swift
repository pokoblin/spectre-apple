import CoreGraphics
import Foundation
import GDPKit
import Synchronization
import Testing
@testable import SpectreKit

/// Records what an InputSender sends.
final class RecordingSink: InputSink {
    enum Event: Equatable {
        case key(UInt32, Bool)
        case motion(Double, Double, Bool)
        case button(UInt32, Bool)
        case axis(Double, Double)
    }

    private let log = Mutex<[Event]>([])
    var events: [Event] { log.withLock { $0 } }

    func sendKey(hidUsage: UInt32, pressed: Bool) { log.withLock { $0.append(.key(hidUsage, pressed)) } }
    func sendPointerMotion(dx: Double, dy: Double, absolute: Bool) {
        log.withLock { $0.append(.motion(dx, dy, absolute)) }
    }
    func sendPointerButton(_ button: UInt32, pressed: Bool) { log.withLock { $0.append(.button(button, pressed)) } }
    func sendPointerAxis(horizontal: Double, vertical: Double) {
        log.withLock { $0.append(.axis(horizontal, vertical)) }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
@MainActor func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("Input sender (gdp-spec.md §8.2)")
@MainActor
struct InputSenderTests {
    @Test func repeatsAndStrayReleasesAreDropped() {
        let sink = RecordingSink()
        let sender = InputSender(sink: sink)
        sender.key(HIDUsage.a, pressed: true)
        sender.key(HIDUsage.a, pressed: true) // auto-repeat
        sender.key(HIDUsage.a, pressed: false)
        sender.key(HIDUsage.a, pressed: false)
        sender.key(HIDUsage.b, pressed: false) // went down before we had focus
        #expect(sink.events == [.key(HIDUsage.a, true), .key(HIDUsage.a, false)])
        #expect(sender.heldKeys.isEmpty)
    }

    @Test func releaseAllLetsGoOfKeysThenModifiersThenButtons() {
        let sink = RecordingSink()
        let sender = InputSender(sink: sink)
        sender.key(HIDUsage.leftGUI, pressed: true)
        sender.key(HIDUsage.leftShift, pressed: true)
        sender.key(HIDUsage.l, pressed: true)
        sender.button(PointerButton.left, pressed: true)
        let before = sink.events.count
        sender.releaseAll()
        #expect(Array(sink.events.dropFirst(before)) == [
            .key(HIDUsage.l, false), .key(HIDUsage.leftShift, false), .key(HIDUsage.leftGUI, false),
            .button(PointerButton.left, false),
        ])
        #expect(sender.heldKeys.isEmpty && sender.heldButtons.isEmpty)
        sender.releaseAll()
        #expect(sink.events.count == before + 4) // nothing left to release
    }

    @Test func capsLockTogglesAreAPressAndARelease() {
        let sink = RecordingSink()
        let sender = InputSender(sink: sink)
        sender.tap(HIDUsage.capsLock)
        sender.tap(HIDUsage.capsLock)
        #expect(sink.events == [.key(HIDUsage.capsLock, true), .key(HIDUsage.capsLock, false),
                                .key(HIDUsage.capsLock, true), .key(HIDUsage.capsLock, false)])
    }
}

@Suite("Pointer mapping")
struct PointerMappingTests {
    /// 1920×1080 in a 1000×1000-point view at 2×: bars above and below.
    let tall = PointerMapping(viewSize: CGSize(width: 1000, height: 1000), backingScale: 2,
                              videoSize: CGSize(width: 1920, height: 1080))

    @Test func barsAboveAndBelow() {
        // 2000×2000 pixels: the picture is 2000×1125, 437.5 px bars rounded like the renderer's.
        let v = VideoRenderer.fitViewport(video: tall.videoSize, drawable: CGSize(width: 2000, height: 2000))
        #expect(tall.videoRect == CGRect(x: 0, y: v.originY / 2, width: 1000, height: v.height / 2))
        let centre = tall.normalized(CGPoint(x: 500, y: 500))
        // 437.5-pixel bars round to 438: the centre is half a pixel off.
        #expect(centre.inside && centre.position.x == 0.5 && abs(centre.position.y - 0.5) < 1.0 / 1125)
        let top = tall.normalized(CGPoint(x: 0, y: tall.videoRect.minY))
        #expect(top.position == .zero && top.inside)
        // In a bar: clamped to the picture's edge, flagged outside.
        let bar = tall.normalized(CGPoint(x: 250, y: 10))
        #expect(bar.position == CGPoint(x: 0.25, y: 0) && !bar.inside)
        let below = tall.normalized(CGPoint(x: 1000, y: 999))
        #expect(below.position == CGPoint(x: 1, y: 1) && !below.inside)
    }

    @Test func barsLeftAndRight() {
        let wide = PointerMapping(viewSize: CGSize(width: 1600, height: 600), backingScale: 1,
                                  videoSize: CGSize(width: 1280, height: 1024))
        // 750×600 picture centred: 425-point bars.
        #expect(wide.videoRect == CGRect(x: 425, y: 0, width: 750, height: 600))
        #expect(wide.normalized(CGPoint(x: 425 + 375, y: 150)).position == CGPoint(x: 0.5, y: 0.25))
        #expect(wide.normalized(CGPoint(x: 100, y: 300)) == (CGPoint(x: 0, y: 0.5), false))
        #expect(wide.viewPoint(CGPoint(x: 1, y: 1)) == CGPoint(x: 1175, y: 600))
        #expect(wide.pointsPerVideoPixel == 750.0 / 1280)
    }

    @Test func roundTrip() {
        for p in [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.75, y: 0.333)] {
            let back = tall.normalized(tall.viewPoint(p)).position
            #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
        }
    }

    @Test func noPictureYet() {
        let none = PointerMapping(viewSize: CGSize(width: 800, height: 600), backingScale: 2, videoSize: .zero)
        #expect(!none.normalized(CGPoint(x: 10, y: 10)).inside)
    }
}

@Suite("Session input state")
@MainActor
struct SessionInputStateTests {
    @Test func cursorShapesAndPictureSize() {
        let input = SessionInput(sink: RecordingSink())
        var changes = 0
        input.onDisplayChange = { changes += 1 }
        input.hostCursorShape(GDPSession.CursorShape(width: 2, height: 2, hotspotX: 1, hotspotY: 1,
                                                     bgra: [UInt8](repeating: 0xff, count: 16)))
        #expect(input.cursor?.width == 2 && changes == 1)
        input.hostCursorShape(GDPSession.CursorShape(width: 2, height: 2, hotspotX: 1, hotspotY: 1,
                                                     bgra: [UInt8](repeating: 0xff, count: 16))) // same
        #expect(changes == 1)
        input.hostCursorShape(GDPSession.CursorShape(width: 0, height: 0, hotspotX: 0, hotspotY: 0, bgra: []))
        #expect(input.cursor?.isHidden == true && changes == 2)
        input.pictureChanged(CGSize(width: 1920, height: 1080))
        input.pictureChanged(CGSize(width: 1920, height: 1080))
        #expect(input.videoSize == CGSize(width: 1920, height: 1080) && changes == 3)
    }
}

@Suite("Scrolling (gdp-spec.md §8.2)")
struct ScrollTests {
    let converter = ScrollConverter(pointsPerNotch: 25)

    @Test func wheelLinesAreNotches() {
        // AppKit: positive Y moves the content down, i.e. scrolls up; §8.2 wants down positive.
        #expect(converter.notches(deltaX: 0, deltaY: 1, precise: false) == (0, -1))
        #expect(converter.notches(deltaX: 0, deltaY: -3, precise: false) == (0, 3))
        #expect(converter.notches(deltaX: 1, deltaY: 0, precise: false) == (-1, 0)) // content right: scroll left
    }

    @Test func smoothScrollingIsFractional() {
        let n = converter.notches(deltaX: -5, deltaY: -12.5, precise: true)
        #expect(n.horizontal == 0.2 && n.vertical == 0.5)
        let zero = converter.notches(deltaX: 0, deltaY: 0, precise: true)
        #expect(zero.horizontal.sign == .plus && zero.vertical.sign == .plus)
    }
}

@Suite("Modifier state from event flags")
struct ModifierSyncTests {
    func down(_ flags: UInt, _ keyCode: UInt16? = nil, held: Set<UInt32> = []) -> Set<UInt32> {
        Set(MacKeyCodes.modifierStates(flags: flags, changedKeyCode: keyCode, held: held).filter(\.pressed).map(\.usage))
    }

    /// The sequence a real Mac produced for Shift+Cmd+Ctrl(+4), the screenshot
    /// shortcut: the screenshot UI then takes the keyboard and the release
    /// arrives as one flagsChanged with key code 0 and no flags.
    @Test func screenshotShortcutReleasesEverything() {
        #expect(down(0x0002_0102, 0x38) == [HIDUsage.leftShift])
        #expect(down(0x0012_010A, 0x37) == [HIDUsage.leftShift, HIDUsage.leftGUI])
        #expect(down(0x0016_210A, 0x3E) == [HIDUsage.leftShift, HIDUsage.leftGUI, HIDUsage.rightControl])
        #expect(down(0x0000_0000, 0, held: [HIDUsage.leftShift, HIDUsage.leftGUI, HIDUsage.rightControl]).isEmpty)
    }

    @Test func cmdAloneAndBothShifts() {
        #expect(down(0x0010_0108, 0x37) == [HIDUsage.leftGUI]) // logged from a real left Cmd
        #expect(down(0x0000_0100, 0x37, held: [HIDUsage.leftGUI]).isEmpty)
        #expect(down(0x0002_0006) == [HIDUsage.leftShift, HIDUsage.rightShift])
        #expect(down(0x0002_0004, 0x38, held: [HIDUsage.leftShift, HIDUsage.rightShift]) == [HIDUsage.rightShift])
        #expect(down(0x0008_0060) == [HIDUsage.leftAlt, HIDUsage.rightAlt])
    }

    /// Flags without device bits (a synthesized event): keep what is held,
    /// add the key that changed; the kind's flag clearing still releases.
    @Test func flagsWithoutDeviceBits() {
        #expect(down(0x0010_0000, 0x36) == [HIDUsage.rightGUI])
        #expect(down(0x0010_0000, nil, held: [HIDUsage.leftGUI]) == [HIDUsage.leftGUI])
        #expect(down(0x0000_0000, nil, held: [HIDUsage.leftGUI]).isEmpty)
    }
}

@MainActor
@Suite("Local shortcuts")
struct LocalShortcutTests {
    @Test func onlyTheReservedCombinationsStayLocal() {
        #expect(LocalShortcut.match(character: "g", modifiers: [.control, .command]) == .toggleCapture)
        #expect(LocalShortcut.match(character: "F", modifiers: [.control, .command]) == .toggleFullScreen)
        #expect(LocalShortcut.match(character: "q", modifiers: [.command]) == .quit)
        // Everything else goes to the remote desktop as Super+…
        #expect(LocalShortcut.match(character: "q", modifiers: [.command, .shift]) == nil)
        #expect(LocalShortcut.match(character: "c", modifiers: [.command]) == nil)
        #expect(LocalShortcut.match(character: "w", modifiers: [.command]) == nil)
        #expect(LocalShortcut.match(character: "g", modifiers: [.command]) == nil)
        #expect(LocalShortcut.match(character: "g", modifiers: [.control, .command, .option]) == nil)
    }
}

@Suite("Input end to end (GDPTestHost)")
@MainActor
struct InputEndToEndTests {
    func connectedSession(_ host: GDPTestHost) async throws -> GDPSession {
        let accepted = Mutex(false)
        var handlers = GDPSession.Handlers()
        handlers.accepted = { _ in accepted.withLock { $0 = true } }
        let session = GDPSession(handlers: handlers)
        try session.connect(host.sessionConfiguration())
        try #require(await eventually { accepted.withLock { $0 } })
        return session
    }

    @Test func keysReachTheHostAndAreReleasedAtTheEnd() async throws {
        let host = try GDPTestHost()
        let session = try await connectedSession(host)
        let input = SessionInput(sink: session)
        input.key(HIDUsage.leftGUI, pressed: true)
        input.key(HIDUsage.c, pressed: true)
        input.key(HIDUsage.c, pressed: true) // repeat: not sent
        input.tapKey(HIDUsage.capsLock)
        input.end()
        #expect(await eventually { host.observed.inputEventCount == 6 })
        #expect(host.inputEvents() == [
            .key(usage: HIDUsage.leftGUI, pressed: true), .key(usage: HIDUsage.c, pressed: true),
            .key(usage: HIDUsage.capsLock, pressed: true), .key(usage: HIDUsage.capsLock, pressed: false),
            .key(usage: HIDUsage.c, pressed: false), .key(usage: HIDUsage.leftGUI, pressed: false),
        ])
        session.close()
    }

    @Test func pointerAndCaptureEndToEnd() async throws {
        var config = GDPTestHost.Configuration()
        config.width = 1000
        config.height = 500
        config.simulatePointer = true
        let host = try GDPTestHost(config)
        let accepted = Mutex(false)
        let box = WeakInput()
        var handlers = GDPSession.Handlers()
        handlers.accepted = { _ in accepted.withLock { $0 = true } }
        handlers.cursorPosition = { x, y in
            Task { @MainActor in box.input?.hostCursorPosition(CGPoint(x: x, y: y)) }
        }
        let session = GDPSession(handlers: handlers)
        try session.connect(host.sessionConfiguration())
        try #require(await eventually { accepted.withLock { $0 } })
        let input = SessionInput(sink: session)
        box.input = input
        var locked = false
        input.captureHandler = { locked = $0; return true }

        input.move(to: CGPoint(x: 0.25, y: 0.5))
        input.move(to: CGPoint(x: 0.25, y: 0.5)) // unchanged: not sent
        input.button(PointerButton.left, pressed: true)
        input.button(PointerButton.left, pressed: false)
        input.scroll(deltaX: 0, deltaY: -1, precise: false) // one notch down
        input.scroll(deltaX: 12.5, deltaY: 0, precise: true) // half a notch left
        input.setCaptured(true)
        #expect(locked && input.isCaptured)
        input.move(by: 100, -50)
        #expect(await eventually { input.hostPosition != nil })
        #expect(abs(input.hostPosition!.x - 0.35) < 1e-9 && abs(input.hostPosition!.y - 0.4) < 1e-9)
        input.focusLost() // releases the capture
        #expect(!locked && !input.isCaptured)
        input.move(to: CGPoint(x: 0.25, y: 0.5)) // sent again: relative motion moved the host's pointer
        #expect(await eventually { host.observed.inputEventCount == 7 })
        #expect(host.inputEvents() == [
            .motion(x: 0.25, y: 0.5, absolute: true), .button(PointerButton.left, pressed: true),
            .button(PointerButton.left, pressed: false), .axis(horizontal: 0, vertical: 1),
            .axis(horizontal: -0.5, vertical: 0), .motion(x: 100, y: -50, absolute: false),
            .motion(x: 0.25, y: 0.5, absolute: true),
        ])
        session.close()
    }
}

/// Lets a session handler reach the input it feeds (used on the main actor only).
final class WeakInput: @unchecked Sendable {
    weak var input: SessionInput?
}

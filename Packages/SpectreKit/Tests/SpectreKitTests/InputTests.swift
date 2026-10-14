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
}

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

import Foundation
import GameController
import GDPKit
import Synchronization
import Testing
@testable import SpectreKit

@MainActor
@Suite("Gamepad mapping (§8.5)")
struct GamepadMappingTests {
    @Test func axesFollowTheWireConventions() throws {
        let pad = try #require(GCController.withExtendedGamepad().extendedGamepad)
        pad.leftThumbstick.setValueForXAxis(0.5, yAxis: 0.25) // GameController: up is positive
        pad.rightThumbstick.setValueForXAxis(-1, yAxis: -1)
        pad.leftTrigger.setValue(0.75)
        pad.rightTrigger.setValue(1)
        let s = GamepadMapping.state(of: pad)
        #expect(s.axes == [0.5, -0.25, -1, 1, 0.75, 1]) // the wire: down is positive
        #expect(s.buttons.allSatisfy { !$0 })
    }

    @Test func eachButtonLandsInItsSlot() throws {
        let pad = try #require(GCController.withExtendedGamepad().extendedGamepad)
        var cases: [(GCControllerButtonInput, GamepadState.Button)] = [
            (pad.buttonA, .south), (pad.buttonB, .east), (pad.buttonX, .west), (pad.buttonY, .north),
            (pad.buttonMenu, .start), (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
        ]
        if let b = pad.buttonOptions { cases.append((b, .back)) }
        if let b = pad.buttonHome { cases.append((b, .guide)) }
        if let b = pad.leftThumbstickButton { cases.append((b, .leftStick)) }
        if let b = pad.rightThumbstickButton { cases.append((b, .rightStick)) }
        for (input, button) in cases {
            input.setValue(1)
            let pressed = GamepadState.Button.allCases.filter { GamepadMapping.state(of: pad)[$0] }
            #expect(pressed == [button], "\(input) should be \(button)")
            input.setValue(0)
        }
        // The d-pad's buttons follow its axes (setting one alone changes nothing).
        let dpad: [(Float, Float, GamepadState.Button)] = [(0, 1, .dpadUp), (0, -1, .dpadDown), (-1, 0, .dpadLeft), (1, 0, .dpadRight)]
        for (x, y, button) in dpad {
            pad.dpad.setValueForXAxis(x, yAxis: y)
            let pressed = GamepadState.Button.allCases.filter { GamepadMapping.state(of: pad)[$0] }
            #expect(pressed == [button])
        }
    }

    @Test func diagonalDpadPressesTwoButtons() throws {
        let pad = try #require(GCController.withExtendedGamepad().extendedGamepad)
        pad.dpad.setValueForXAxis(-1, yAxis: 1)
        let s = GamepadMapping.state(of: pad)
        #expect(s[.dpadLeft] && s[.dpadUp] && !s[.dpadRight] && !s[.dpadDown])
    }
}

/// Records what a GamepadForwarder sends.
final class RecordingGamepadSink: GamepadSink {
    enum Event: Equatable {
        case connect(UInt32, String)
        case state(UInt32, GamepadState)
        case disconnect(UInt32)
    }

    private let log = Mutex<[Event]>([])
    var events: [Event] { log.withLock { $0 } }
    func clear() { log.withLock { $0 = [] } }

    func sendGamepadConnect(slot: UInt32, name: String) { log.withLock { $0.append(.connect(slot, name)) } }
    func sendGamepadState(slot: UInt32, _ state: GamepadState) { log.withLock { $0.append(.state(slot, state)) } }
    func sendGamepadDisconnect(slot: UInt32) { log.withLock { $0.append(.disconnect(slot)) } }
}

@MainActor
final class FakeGamepad: GamepadDevice {
    let name: String
    var state = GamepadState()
    var onChange: (() -> Void)?
    var playerSlot: Int?
    var systemGesturesEnabled = true

    init(_ name: String) { self.name = name }

    func setPlayerSlot(_ slot: Int?) { playerSlot = slot }
    func setSystemGesturesEnabled(_ enabled: Bool) { systemGesturesEnabled = enabled }

    func press(_ button: GamepadState.Button, _ down: Bool = true) {
        state[button] = down
        onChange?()
    }
}

@MainActor
@Suite("Gamepad forwarding (§8.5)")
struct GamepadForwarderTests {
    let defaults: UserDefaults
    let sink = RecordingGamepadSink()

    init() {
        let name = "GamepadForwarderTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    func make(enabled: Bool = true, present: [FakeGamepad] = []) -> GamepadForwarder {
        defaults.set(enabled, forKey: GamepadForwarder.enabledKey)
        let forwarder = GamepadForwarder(sink: sink, defaults: defaults, devices: { present })
        forwarder.start(appIsActive: true) // as if frontmost, whatever the test runner is
        return forwarder
    }

    func pressed(_ buttons: GamepadState.Button...) -> GamepadState {
        var s = GamepadState()
        for b in buttons { s[b] = true }
        return s
    }

    @Test func offByDefault() {
        let forwarder = GamepadForwarder(sink: sink, defaults: defaults, devices: { [FakeGamepad("pad")] })
        forwarder.start(appIsActive: true)
        #expect(!forwarder.isEnabled)
        #expect(sink.events.isEmpty)
        forwarder.stop()
    }

    @Test func controllersPresentAtStartAreAnnounced() {
        let pad = FakeGamepad("Xbox Wireless Controller")
        pad.state[.south] = true
        let forwarder = make(present: [pad])
        #expect(sink.events == [.connect(0, "Xbox Wireless Controller"), .state(0, pressed(.south))])
        #expect(forwarder.slots == [0: "Xbox Wireless Controller"])
        #expect(pad.playerSlot == 0)
        #expect(!pad.systemGesturesEnabled) // Home and Share go to the host
        forwarder.stop()
        #expect(sink.events.last == .disconnect(0))
        #expect(pad.playerSlot == nil && pad.systemGesturesEnabled)
    }

    @Test func everyChangeSendsTheCompleteStateOnce() {
        let pad = FakeGamepad("pad")
        let forwarder = make()
        forwarder.attach(pad)
        sink.clear()
        pad.press(.east)
        pad.onChange?() // nothing changed: not sent again
        pad.press(.dpadUp)
        pad.press(.east, false)
        #expect(sink.events == [.state(0, pressed(.east)), .state(0, pressed(.east, .dpadUp)), .state(0, pressed(.dpadUp))])
        forwarder.stop()
    }

    @Test func slotsAreTheLowestFreeAndAtMostFour() {
        let pads = (0..<5).map { FakeGamepad("pad \($0)") }
        let forwarder = make()
        pads.forEach(forwarder.attach)
        #expect(forwarder.slots.count == 4)
        #expect(pads[4].playerSlot == nil) // the fifth is not forwarded
        forwarder.detach(pads[1])
        #expect(sink.events.last == .disconnect(1))
        forwarder.attach(pads[4])
        #expect(forwarder.slots[1] == "pad 4")
        sink.clear()
        pads[1].press(.south) // detached: no longer forwarded
        #expect(sink.events.isEmpty)
        forwarder.stop()
    }

    @Test func inactiveAppReleasesEverything() {
        let pad = FakeGamepad("pad")
        let forwarder = make()
        forwarder.attach(pad)
        pad.press(.south)
        sink.clear()
        forwarder.setActive(false)
        pad.press(.north) // the system shouldn't deliver this; if it does, it isn't forwarded
        forwarder.setActive(true)
        #expect(sink.events == [.state(0, GamepadState()), .state(0, pressed(.south, .north))])
        forwarder.stop()
    }

    @Test func turningItOnAndOffMidSession() {
        let pad = FakeGamepad("pad")
        let forwarder = make(enabled: false, present: [pad])
        #expect(sink.events.isEmpty)
        forwarder.isEnabled = true
        #expect(defaults.bool(forKey: GamepadForwarder.enabledKey))
        #expect(sink.events == [.connect(0, "pad"), .state(0, GamepadState())])
        forwarder.isEnabled = false
        #expect(sink.events.last == .disconnect(0))
        #expect(pad.systemGesturesEnabled && pad.playerSlot == nil)
        sink.clear()
        pad.press(.south)
        #expect(sink.events.isEmpty)
        forwarder.stop()
    }
}

import Foundation
import GameController
import GDPKit
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where a session's gamepad messages go (gdp-spec.md §8.5).
public protocol GamepadSink: AnyObject, Sendable {
    func sendGamepadConnect(slot: UInt32, name: String)
    func sendGamepadState(slot: UInt32, _ state: GamepadState)
    func sendGamepadDisconnect(slot: UInt32)
}

extension GDPSession: GamepadSink {}

/// A controller as the forwarder sees it; ``ControllerDevice`` wraps a
/// `GCController`, tests use their own.
@MainActor
public protocol GamepadDevice: AnyObject {
    var name: String { get }
    /// The current state, in the spec's layout.
    var state: GamepadState { get }
    /// Called on the main thread whenever an input changed.
    var onChange: (() -> Void)? { get set }
    /// Shows the slot on the controller's player lights; nil turns them off.
    func setPlayerSlot(_ slot: Int?)
    /// Takes the buttons the system would act on (Home, Share) away from
    /// the system while forwarding (false), or gives them back (true).
    func setSystemGesturesEnabled(_ enabled: Bool)
}

/// One session's gamepads (gdp-spec.md §8.5, capability `gamepad`).
///
/// Each controller with an extended gamepad profile takes the lowest free
/// slot of four (a fifth is not forwarded) and is announced with
/// `GamepadConnect`; every change sends its complete state, skipping one
/// identical to the last sent, and it leaves with `GamepadDisconnect`.
/// While the app isn't active the host sees every pad released, as it sees
/// keys released (§8.2), and the current state again on return. Off by
/// default, remembered across sessions; turning it on mid-session announces
/// the controllers already there.
@MainActor
@Observable
public final class GamepadForwarder {
    public static let enabledKey = "gamepadForwarding"

    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            guard isWatching else { return }
            if isEnabled { attachAll() } else { detachAll() }
        }
    }

    /// The forwarded controllers' names, by slot.
    public private(set) var slots: [Int: String] = [:]

    @ObservationIgnored private let sink: GamepadSink
    @ObservationIgnored private let defaults: UserDefaults
    /// nil: the system's `GCController`s.
    @ObservationIgnored private let devicesProvider: (@MainActor () -> [GamepadDevice])?
    @ObservationIgnored private var attached: [ObjectIdentifier: (device: GamepadDevice, slot: Int)] = [:]
    @ObservationIgnored private var lastSent: [Int: GamepadState] = [:]
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var isWatching = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The wrappers of connected `GCController`s, so a disconnect finds its device.
    @ObservationIgnored private var controllers: [ObjectIdentifier: ControllerDevice] = [:]

    /// `devices`: the controllers already connected when forwarding starts
    /// or is turned on; by default every `GCController` with an extended profile.
    public init(sink: GamepadSink, defaults: UserDefaults = .standard,
                devices: (@MainActor () -> [GamepadDevice])? = nil) {
        self.sink = sink
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        devicesProvider = devices
    }

    private var usesSystemControllers: Bool { devicesProvider == nil }

    /// Starts forwarding: once the session is established with `gamepad` in effect.
    public func start() {
        #if os(macOS)
        start(appIsActive: NSApplication.shared.isActive)
        #else
        start(appIsActive: UIApplication.shared.applicationState == .active)
        #endif
    }

    func start(appIsActive: Bool) {
        guard !isWatching else { return }
        isWatching = true
        isActive = appIsActive
        #if os(macOS)
        let resign = NSApplication.didResignActiveNotification, become = NSApplication.didBecomeActiveNotification
        #else
        let resign = UIApplication.willResignActiveNotification, become = UIApplication.didBecomeActiveNotification
        #endif
        let center = NotificationCenter.default
        // `body` gets the notification's object. The queue is the main one,
        // so the object never actually crosses threads.
        func observe(_ name: Notification.Name, _ body: @escaping @MainActor (Any?) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                nonisolated(unsafe) let object = note.object
                MainActor.assumeIsolated { body(object) }
            })
        }
        observe(resign) { [weak self] _ in self?.setActive(false) }
        observe(become) { [weak self] _ in self?.setActive(true) }
        if usesSystemControllers {
            observe(.GCControllerDidConnect) { [weak self] object in
                guard let self, let controller = object as? GCController else { return }
                if isEnabled, let device = systemDevice(controller) { attach(device) }
            }
            observe(.GCControllerDidDisconnect) { [weak self] object in
                guard let self, let controller = object as? GCController else { return }
                if let device = controllers.removeValue(forKey: ObjectIdentifier(controller)) { detach(device) }
            }
        }
        if isEnabled { attachAll() }
    }

    /// Stops forwarding and gives the controllers back (player lights, system buttons).
    public func stop() {
        guard isWatching else { return }
        detachAll()
        isWatching = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    isolated deinit { stop() }

    // MARK: Controllers

    /// A controller appeared (tests call this directly).
    func attach(_ device: GamepadDevice) {
        let id = ObjectIdentifier(device)
        guard attached[id] == nil,
              let slot = (0..<GamepadState.maxSlots).first(where: { slots[$0] == nil }) else { return }
        attached[id] = (device, slot)
        slots[slot] = device.name
        lastSent[slot] = nil
        sink.sendGamepadConnect(slot: UInt32(slot), name: device.name)
        device.setPlayerSlot(slot)
        device.setSystemGesturesEnabled(false)
        device.onChange = { [weak self, weak device] in
            guard let self, let device else { return }
            changed(device)
        }
        send(slot, isActive ? device.state : GamepadState())
    }

    /// A controller went away (tests call this directly).
    func detach(_ device: GamepadDevice) {
        guard let (_, slot) = attached.removeValue(forKey: ObjectIdentifier(device)) else { return }
        device.onChange = nil
        device.setPlayerSlot(nil)
        device.setSystemGesturesEnabled(true)
        slots[slot] = nil
        lastSent[slot] = nil
        sink.sendGamepadDisconnect(slot: UInt32(slot))
    }

    private func attachAll() {
        let devices = devicesProvider?() ?? GCController.controllers().compactMap(systemDevice)
        devices.forEach(attach)
    }

    private func detachAll() {
        attached.values.map(\.device).forEach(detach)
        controllers = [:]
    }

    private func systemDevice(_ controller: GCController) -> GamepadDevice? {
        guard controller.extendedGamepad != nil else { return nil } // a Siri Remote, say
        let id = ObjectIdentifier(controller)
        if let device = controllers[id] { return device }
        let device = ControllerDevice(controller)
        controllers[id] = device
        return device
    }

    private func changed(_ device: GamepadDevice) {
        guard isActive, let slot = attached[ObjectIdentifier(device)]?.slot else { return }
        send(slot, device.state)
    }

    /// The app became active or stopped being active (tests call this directly).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        for (device, slot) in attached.values {
            send(slot, active ? device.state : GamepadState())
        }
    }

    /// Complete states only, and not one the host already has.
    private func send(_ slot: Int, _ state: GamepadState) {
        guard lastSent[slot] != state else { return }
        lastSent[slot] = state
        sink.sendGamepadState(slot: UInt32(slot), state)
    }
}

/// A `GCController` with an extended gamepad profile.
@MainActor
final class ControllerDevice: GamepadDevice {
    let controller: GCController
    var onChange: (() -> Void)?
    /// The system-gesture elements taken over, with what they were set to.
    private var takenGestures: [(GCControllerElement, GCControllerElement.SystemGestureState)] = []

    init(_ controller: GCController) {
        self.controller = controller
        controller.handlerQueue = .main
        controller.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    var name: String { controller.vendorName ?? controller.productCategory }

    var state: GamepadState { controller.extendedGamepad.map(GamepadMapping.state(of:)) ?? GamepadState() }

    func setPlayerSlot(_ slot: Int?) {
        controller.playerIndex = slot.flatMap(GCControllerPlayerIndex.init(rawValue:)) ?? .indexUnset
    }

    func setSystemGesturesEnabled(_ enabled: Bool) {
        if enabled {
            for (element, state) in takenGestures { element.preferredSystemGestureState = state }
            takenGestures = []
        } else if takenGestures.isEmpty {
            // Home (as `guide`) and Share/Options: whatever this controller binds to a system gesture.
            for element in controller.physicalInputProfile.allElements where element.isBoundToSystemGesture {
                takenGestures.append((element, element.preferredSystemGestureState))
                element.preferredSystemGestureState = .disabled
            }
        }
    }
}

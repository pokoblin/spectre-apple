/// One controller's complete state as `GamepadState` carries it
/// (gdp-spec.md §8.5): every axis and every button, in the order the spec
/// fixes (SDL3's `SDL_GamepadAxis` and `SDL_GamepadButton`, pinned in
/// libgdp's `gdp/gamepad.hpp`).
public struct GamepadState: Sendable, Equatable {
    public enum Axis: Int, CaseIterable, Sendable {
        /// Sticks: −1...1, positive right and down.
        case leftX, leftY, rightX, rightY
        /// Triggers: 0...1.
        case leftTrigger, rightTrigger
    }

    /// Face buttons are named by position: south is Xbox A and PlayStation Cross.
    public enum Button: Int, CaseIterable, Sendable {
        case south, east, west, north
        case back, guide, start
        case leftStick, rightStick, leftShoulder, rightShoulder
        case dpadUp, dpadDown, dpadLeft, dpadRight
        /// Xbox share button, Switch capture, ...
        case misc1
        case rightPaddle1, leftPaddle1, rightPaddle2, leftPaddle2
        case touchpad
        case misc2, misc3, misc4, misc5, misc6
    }

    /// The most controllers a client forwards, slots 0...3.
    public static let maxSlots = 4

    public private(set) var axes = [Float](repeating: 0, count: Axis.allCases.count)
    public private(set) var buttons = [Bool](repeating: false, count: Button.allCases.count)

    /// Everything centred and released.
    public init() {}

    public subscript(axis: Axis) -> Float {
        get { axes[axis.rawValue] }
        set { axes[axis.rawValue] = newValue }
    }

    public subscript(button: Button) -> Bool {
        get { buttons[button.rawValue] }
        set { buttons[button.rawValue] = newValue }
    }
}

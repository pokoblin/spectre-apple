import GameController
import GDPKit

/// GameController's extended gamepad profile in the spec's layout
/// (gdp-spec.md §8.5). Both name face buttons by position (GameController's
/// A, B, X, Y form the diamond south, east, west, north on every controller),
/// so a PlayStation Cross is `south` as it is on the host. GameController's
/// stick Y is up-positive; the wire's is down-positive.
public enum GamepadMapping {
    public static func state(of pad: GCExtendedGamepad) -> GamepadState {
        var s = GamepadState()
        s[.leftX] = pad.leftThumbstick.xAxis.value
        s[.leftY] = -pad.leftThumbstick.yAxis.value
        s[.rightX] = pad.rightThumbstick.xAxis.value
        s[.rightY] = -pad.rightThumbstick.yAxis.value
        s[.leftTrigger] = pad.leftTrigger.value
        s[.rightTrigger] = pad.rightTrigger.value

        s[.south] = pad.buttonA.isPressed
        s[.east] = pad.buttonB.isPressed
        s[.west] = pad.buttonX.isPressed
        s[.north] = pad.buttonY.isPressed
        // Options is the secondary menu button (Xbox View, PlayStation Share/Create), Menu the primary.
        s[.back] = pad.buttonOptions?.isPressed ?? false
        s[.guide] = pad.buttonHome?.isPressed ?? false
        s[.start] = pad.buttonMenu.isPressed
        s[.leftStick] = pad.leftThumbstickButton?.isPressed ?? false
        s[.rightStick] = pad.rightThumbstickButton?.isPressed ?? false
        s[.leftShoulder] = pad.leftShoulder.isPressed
        s[.rightShoulder] = pad.rightShoulder.isPressed
        s[.dpadUp] = pad.dpad.up.isPressed
        s[.dpadDown] = pad.dpad.down.isPressed
        s[.dpadLeft] = pad.dpad.left.isPressed
        s[.dpadRight] = pad.dpad.right.isPressed

        if let xbox = pad as? GCXboxGamepad {
            s[.misc1] = xbox.buttonShare?.isPressed ?? false
            // The Elite's P1-P4: P1 and P2 under the right hand (upper,
            // lower), P3 and P4 under the left, as SDL numbers its paddles.
            s[.rightPaddle1] = xbox.paddleButton1?.isPressed ?? false
            s[.rightPaddle2] = xbox.paddleButton2?.isPressed ?? false
            s[.leftPaddle1] = xbox.paddleButton3?.isPressed ?? false
            s[.leftPaddle2] = xbox.paddleButton4?.isPressed ?? false
        } else if let dualSense = pad as? GCDualSenseGamepad {
            s[.touchpad] = dualSense.touchpadButton.isPressed
        } else if let dualShock = pad as? GCDualShockGamepad {
            s[.touchpad] = dualShock.touchpadButton.isPressed
        }
        return s
    }
}

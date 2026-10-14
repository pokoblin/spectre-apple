/// Platform scroll deltas as gdp-spec.md §8.2 wants them: wheel notches,
/// positive right and down, fractions for smooth devices.
///
/// Both AppKit (`scrollingDeltaX/Y`) and UIKit (a scroll pan's
/// translation) report how the *content* should move: positive Y moves it
/// down, which is scrolling up. They already apply the system's
/// natural-scrolling setting, which is what §8.2 asks the client to do, so
/// the conversion only flips the sign and changes the unit.
public struct ScrollConverter: Sendable, Equatable {
    /// Points of smooth scrolling (a trackpad, a Magic Mouse, an iPad
    /// trackpad's pan) per notch. A notch scrolls about three lines on a
    /// Linux desktop, some 50 pixels.
    public var pointsPerNotch: Double

    public init(pointsPerNotch: Double = 25) {
        self.pointsPerNotch = pointsPerNotch
    }

    /// A scroll event's deltas as notches. `precise`: the deltas are points
    /// (AppKit's `hasPreciseScrollingDeltas`); otherwise they are lines,
    /// which a notched wheel reports one (or, accelerated, a few) per detent.
    public func notches(deltaX: Double, deltaY: Double, precise: Bool) -> (horizontal: Double, vertical: Double) {
        let unit = precise ? pointsPerNotch : 1
        return (-deltaX / unit + 0, -deltaY / unit + 0) // + 0: no negative zero
    }
}

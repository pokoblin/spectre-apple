import CoreGraphics
import Foundation

/// The coast after a trackpad scroll on iPadOS. Its scroll pan ends when
/// the fingers lift and leaves the deceleration to each UIScrollView, so a
/// remote desktop would stop dead; AppKit sends momentum events itself.
/// The speed decays like a UIScrollView's: by `decelerationRate` each
/// millisecond.
public struct ScrollMomentum: Sendable, Equatable {
    /// Speed kept per millisecond (UIScrollView's `.normal` rate).
    public var decelerationRate: Double
    /// Points per second below which a flick doesn't coast and a coast stops.
    public var minimumSpeed: Double
    /// Points per second, the content's movement; nil when not coasting.
    public private(set) var velocity: CGPoint?

    public init(decelerationRate: Double = 0.998, minimumSpeed: Double = 20) {
        self.decelerationRate = decelerationRate
        self.minimumSpeed = minimumSpeed
    }

    public var isCoasting: Bool { velocity != nil }

    /// Starts coasting at the speed the scroll ended with.
    public mutating func start(velocity v: CGPoint) {
        velocity = hypot(v.x, v.y) < minimumSpeed ? nil : v
    }

    public mutating func stop() { velocity = nil }

    /// Advances by `seconds` and returns the distance covered in that
    /// time (points, the content's movement), or nil when not coasting.
    public mutating func advance(by seconds: Double) -> CGPoint? {
        guard let v = velocity else { return nil }
        // v(t) = v₀·rᵗ (t in ms), so the distance is v₀·(1 − rᵗ)/k, k = −ln r per second.
        let k = -log(decelerationRate) * 1000
        let kept = exp(-k * max(seconds, 0))
        let distance = CGPoint(x: v.x * (1 - kept) / k, y: v.y * (1 - kept) / k)
        let next = CGPoint(x: v.x * kept, y: v.y * kept)
        velocity = hypot(next.x, next.y) < minimumSpeed ? nil : next
        return distance
    }
}

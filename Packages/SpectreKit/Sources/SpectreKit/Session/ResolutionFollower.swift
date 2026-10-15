import CoreGraphics
import Foundation

/// Keeps the remote output the size of the view that shows it
/// (docs/resolution.md): what to put in SessionHello (gdp-spec.md §6.2) and
/// when to send a ResolutionChange (§7.2).
///
/// The host reopens its encoder for every new size, so a size is only asked
/// for once the view has stopped changing for ``settleDelay``, and never
/// twice in a row: a host that can't resize answers with the size it has,
/// and asking again would get the same answer. Times are the caller's
/// (seconds, any monotonic clock), as with ``TouchPointerMapper``.
public struct ResolutionFollower: Sendable {
    /// What a view's size is counted in.
    public enum Units: String, Sendable, CaseIterable {
        /// The view's points: a Retina view gets half its pixels in each
        /// direction, upscaled by the renderer. Lighter on the host.
        case points
        /// The view's pixels: sharp, at up to four times the encoding work.
        case pixels
    }

    /// An output size in pixels.
    public struct Size: Sendable, Equatable, CustomStringConvertible {
        public var width: UInt32
        public var height: UInt32

        public init(width: UInt32, height: UInt32) {
            self.width = width
            self.height = height
        }

        public var description: String { "\(width)×\(height)" }
    }

    /// How long the view must keep its size before it is asked for.
    public static let settleDelay: TimeInterval = 0.5
    /// §7.2: the sizes a host accepts, per side.
    public static let sides: ClosedRange<UInt32> = 320...8192

    public private(set) var isEnabled: Bool
    public private(set) var units: Units
    /// When ``update(at:)`` has something to decide.
    public private(set) var nextDeadline: TimeInterval?

    private var viewSize: CGSize = .zero
    private var scale: CGFloat = 1
    /// The output's size, as the host last reported it.
    private var outputSize: Size?
    /// The size last asked for, in SessionHello or a ResolutionChange.
    private var requested: Size?

    public init(isEnabled: Bool, units: Units) {
        self.isEnabled = isEnabled
        self.units = units
    }

    /// The output size for a view: whole pixels rounded down to even
    /// numbers (§7.2: subsampled chroma needs even sizes) within ``sides``.
    /// Nil for a view with no area.
    public static func outputSize(viewSize: CGSize, scale: CGFloat, units: Units) -> Size? {
        let factor = units == .pixels ? scale : 1
        guard viewSize.width > 0, viewSize.height > 0, factor > 0 else { return nil }
        func side(_ length: CGFloat) -> UInt32 {
            let whole = UInt32(min(length * factor, CGFloat(sides.upperBound)).rounded(.down))
            return max(whole & ~1, sides.lowerBound)
        }
        return Size(width: side(viewSize.width), height: side(viewSize.height))
    }

    /// The size the view asks for now, if following.
    public var target: Size? {
        isEnabled ? Self.outputSize(viewSize: viewSize, scale: scale, units: units) : nil
    }

    /// The view's size (points) or its scale changed.
    public mutating func viewChanged(_ size: CGSize, scale: CGFloat, at now: TimeInterval) {
        guard size != viewSize || scale != self.scale else { return }
        viewSize = size
        self.scale = scale
        settle(from: now)
    }

    /// SessionAccept or DisplaysChanged reported the output's size.
    public mutating func outputChanged(_ size: Size) {
        outputSize = size
    }

    public mutating func setEnabled(_ on: Bool, at now: TimeInterval) {
        guard on != isEnabled else { return }
        isEnabled = on
        if on { settle(from: now) } else { nextDeadline = nil }
    }

    public mutating func setUnits(_ units: Units, at now: TimeInterval) {
        guard units != self.units else { return }
        self.units = units
        settle(from: now)
    }

    /// What to put in SessionHello for a new connection (or nil: keep the
    /// session's size). It counts as asked for: the host applies it or
    /// keeps its size, and either way there is nothing more to send.
    public mutating func sizeForConnection() -> Size? {
        nextDeadline = nil
        outputSize = nil
        requested = target
        return requested
    }

    /// The size to send in a ResolutionChange now, if the view has settled
    /// on one that is neither the output's size nor already asked for.
    public mutating func update(at now: TimeInterval) -> Size? {
        guard let deadline = nextDeadline, now >= deadline else { return nil }
        nextDeadline = nil
        guard let target, target != outputSize, target != requested else { return nil }
        requested = target
        return target
    }

    private mutating func settle(from now: TimeInterval) {
        if isEnabled { nextDeadline = now + Self.settleDelay }
    }
}

import CoreGraphics
import Foundation

/// Keeps the remote output the size of the view that shows it
/// (docs/resolution.md): what to put in SessionHello (gdp-spec.md §6.2) and
/// when to send a ResolutionChange (§7.2). In pixels, the host's desktop is
/// asked to run at the view's scale too, so that it looks as big as a
/// local app; in points, at none, which a host takes as 100%. The frame
/// rate wanted goes with every request, and a new one is asked for on its
/// own, at the output's size, when the view isn't followed.
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

    /// What is asked for: the output's size, the desktop scale to go with
    /// it (§6.2), 0 for none, and the frame rate, 0 for none.
    public struct Request: Sendable, Equatable, CustomStringConvertible {
        public var size: Size
        public var scale: Double
        public var refreshMillihertz: UInt32

        public init(size: Size, scale: Double = 0, refreshMillihertz: UInt32 = 0) {
            self.size = size
            self.scale = scale
            self.refreshMillihertz = refreshMillihertz
        }

        public var description: String {
            var text = scale > 0 ? "\(size) at \(Int((scale * 100).rounded()))%" : size.description
            if refreshMillihertz > 0 { text += ", \(ResolutionFollower.hertz(refreshMillihertz)) Hz" }
            return text
        }
    }

    /// How long the view must keep its size before it is asked for.
    public static let settleDelay: TimeInterval = 0.5
    /// §7.2: the sizes a host accepts, per side.
    public static let sides: ClosedRange<UInt32> = 320...8192
    /// Widths are asked for in whole 16-pixel blocks. §7.2 only needs them
    /// even, but wraith encoding with VA-API (an Intel N100) sends sheared
    /// pictures at other widths; heights that aren't multiples of 16 are
    /// fine (docs/resolution.md).
    public static let widthAlignment: UInt32 = 16

    public private(set) var isEnabled: Bool
    public private(set) var units: Units
    /// The frame rate wanted (§6.2), 0 for none: the host's own, 60 Hz.
    public private(set) var refreshMillihertz: UInt32 = 0
    /// When ``update(at:)`` has something to decide.
    public private(set) var nextDeadline: TimeInterval?

    private var viewSize: CGSize = .zero
    private var scale: CGFloat = 1
    /// The output's size, scale and rate, as the host last reported them.
    private var output: Request?
    /// What was last asked for, in SessionHello or a ResolutionChange.
    private var requested: Request?
    /// The rate last asked for, also without a size.
    private var requestedRefresh: UInt32 = 0

    public init(isEnabled: Bool, units: Units) {
        self.isEnabled = isEnabled
        self.units = units
    }

    /// The output size for a view: whole pixels rounded down to even
    /// numbers (§7.2: subsampled chroma needs even sizes), widths to
    /// ``widthAlignment``, within ``sides``. Nil for a view with no area.
    public static func outputSize(viewSize: CGSize, scale: CGFloat, units: Units) -> Size? {
        let factor = units == .pixels ? scale : 1
        guard viewSize.width > 0, viewSize.height > 0, factor > 0 else { return nil }
        func side(_ length: CGFloat, multipleOf step: UInt32) -> UInt32 {
            let whole = UInt32(min(length * factor, CGFloat(sides.upperBound)).rounded(.down))
            return max(whole / step * step, sides.lowerBound)
        }
        return Size(width: side(viewSize.width, multipleOf: widthAlignment),
                    height: side(viewSize.height, multipleOf: 2))
    }

    /// What the view asks for now, if following.
    public var target: Request? {
        guard isEnabled, let size = Self.outputSize(viewSize: viewSize, scale: scale, units: units) else { return nil }
        return Request(size: size, scale: units == .pixels ? Double(scale) : 0, refreshMillihertz: refreshMillihertz)
    }

    /// Whole hertz, as a host sets them; none is the host's 60.
    public static func hertz(_ millihertz: UInt32) -> UInt32 {
        millihertz > 0 ? (millihertz + 500) / 1000 : 60
    }

    /// The view's size (points) or its scale changed.
    public mutating func viewChanged(_ size: CGSize, scale: CGFloat, at now: TimeInterval) {
        guard size != viewSize || scale != self.scale else { return }
        viewSize = size
        self.scale = scale
        settle(from: now)
    }

    /// SessionAccept or DisplaysChanged reported the output's size, the
    /// scale the host's desktop runs at (1 from a host that sets none) and
    /// its frame rate (0 if unknown).
    public mutating func outputChanged(_ size: Size, scale: Double = 1, refreshMillihertz: UInt32 = 0) {
        output = Request(size: size, scale: scale, refreshMillihertz: refreshMillihertz)
    }

    public mutating func setEnabled(_ on: Bool, at now: TimeInterval) {
        guard on != isEnabled else { return }
        isEnabled = on
        if on { settle(from: now) } else if !refreshPending { nextDeadline = nil }
    }

    /// A new frame rate wanted (the setting, or the display it is matched
    /// to). It is asked for once it has settled, like a size: a window
    /// dragged across displays doesn't ask for each one's.
    public mutating func setRefresh(_ millihertz: UInt32, at now: TimeInterval) {
        guard millihertz != refreshMillihertz else { return }
        refreshMillihertz = millihertz
        nextDeadline = now + Self.settleDelay
    }

    public mutating func setUnits(_ units: Units, at now: TimeInterval) {
        guard units != self.units else { return }
        self.units = units
        settle(from: now)
    }

    /// What to put in SessionHello for a new connection (or nil: keep the
    /// session's size). It counts as asked for: the host applies it or
    /// keeps its size, and either way there is nothing more to send.
    public mutating func requestForConnection() -> Request? {
        nextDeadline = nil
        output = nil
        requested = target
        requestedRefresh = refreshMillihertz
        return requested
    }

    /// What to send in a ResolutionChange now, if the view has settled on
    /// something that is neither what the output has nor already asked for.
    public mutating func update(at now: TimeInterval) -> Request? {
        guard let deadline = nextDeadline, now >= deadline else { return nil }
        nextDeadline = nil
        guard isEnabled else { return rateChange() }
        guard let target, target != requested else { return nil }
        if let output, Self.matches(target, output) { return nil }
        requested = target
        requestedRefresh = target.refreshMillihertz
        return target
    }

    /// Not following the view: a new rate, at the size and scale the
    /// output has, unless it runs at that rate already.
    private mutating func rateChange() -> Request? {
        guard refreshPending, var change = output else { return nil }
        requestedRefresh = refreshMillihertz
        guard Self.hertz(change.refreshMillihertz) != Self.hertz(refreshMillihertz) else { return nil }
        change.refreshMillihertz = refreshMillihertz
        return change
    }

    private var refreshPending: Bool { refreshMillihertz != requestedRefresh }

    /// Whether the output is what the view asks for: its size, at the scale
    /// asked for (none is 100%, as a host takes it) and the rate. A host may
    /// round or bound them; what it couldn't set isn't asked for again,
    /// being `requested`.
    private static func matches(_ target: Request, _ output: Request) -> Bool {
        func percent(_ scale: Double) -> Int { Int(((scale > 0 ? scale : 1) * 100).rounded()) }
        return target.size == output.size && percent(target.scale) == percent(output.scale)
            && (target.refreshMillihertz == 0 || hertz(target.refreshMillihertz) == hertz(output.refreshMillihertz))
    }

    private mutating func settle(from now: TimeInterval) {
        if isEnabled { nextDeadline = now + Self.settleDelay }
    }
}

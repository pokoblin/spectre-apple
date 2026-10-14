import CoreGraphics
import Foundation

/// What a touch gesture asks the session to send (gdp-spec.md §8.2).
public enum TouchPointerAction: Equatable, Sendable {
    /// Absolute pointer motion, 0...1 over the output, (0, 0) at the top left.
    case move(CGPoint)
    /// A ``PointerButton`` code pressed or released.
    case button(UInt32, pressed: Bool)
    /// Wheel notches, positive right / down. Fractions are meant: the view
    /// passes them on as they come rather than rounding each one away.
    case scroll(horizontal: Double, vertical: Double)
    /// A long press was recognized: the view may play a haptic.
    case longPress
}

/// Fingers to pointer events. The host ignores touch events (gdp-spec.md
/// §8.3), so on iPad and iPhone the client is the one that turns gestures
/// into a pointer: either a touchscreen that points where the finger is
/// (``Mode/direct``) or the screen used as a laptop touchpad
/// (``Mode/trackpad``), with the client drawing the cursor at ``cursor``.
///
/// Pure state machine: the view feeds it touches with their timestamps,
/// sends what comes back, and calls ``update(at:)`` once ``nextDeadline``
/// has passed (the long press fires from a timer, not from a touch event).
/// Every button it presses it releases again on lift, cancel or ``reset()``.
public struct TouchPointerMapper: Sendable {
    public enum Mode: String, Sendable, CaseIterable {
        /// The finger is the pointer: tap to click where you touch, drag to
        /// drag, long press for a right click.
        case direct
        /// The screen is a touchpad: one finger moves the cursor relatively,
        /// taps click wherever the cursor is.
        case trackpad
    }

    public struct Touch: Sendable, Equatable {
        /// Stable for the touch's lifetime (the view hashes its UITouch).
        public var id: Int
        /// In view points, top-left origin.
        public var location: CGPoint

        public init(id: Int, location: CGPoint) {
            self.id = id
            self.location = location
        }
    }

    public struct Tuning: Sendable, Equatable {
        /// Travel (points) below which a finger is still holding still: a
        /// tap or a long press rather than a drag.
        public var slop: CGFloat
        /// Longest touch (first finger down to last finger up) that still
        /// counts as a tap.
        public var tapMaxDuration: TimeInterval
        /// Hold this long without moving for a long press (direct mode).
        public var longPressDuration: TimeInterval
        /// From one tap's lift to the next touch-down: a double tap (direct)
        /// or the start of a tap-and-drag (trackpad).
        public var doubleTapInterval: TimeInterval
        /// How far (points) a double tap's second touch may land from the
        /// first and still be snapped onto it.
        public var doubleTapSlop: CGFloat
        /// Finger travel (points) per wheel notch.
        public var pointsPerNotch: CGFloat
        /// Trackpad gain: the cursor moves this many times the finger's
        /// travel, measured against the picture's size on screen.
        public var trackpadSpeed: CGFloat
        /// After the first finger lands, how long a one-finger drag waits
        /// before committing, so that two fingers landing a little apart
        /// still make a two-finger gesture.
        public var multiTouchGrace: TimeInterval

        public init(slop: CGFloat = 10, tapMaxDuration: TimeInterval = 0.3, longPressDuration: TimeInterval = 0.5,
                    doubleTapInterval: TimeInterval = 0.35, doubleTapSlop: CGFloat = 24, pointsPerNotch: CGFloat = 24,
                    trackpadSpeed: CGFloat = 1.5, multiTouchGrace: TimeInterval = 0.1) {
            self.slop = slop
            self.tapMaxDuration = tapMaxDuration
            self.longPressDuration = longPressDuration
            self.doubleTapInterval = doubleTapInterval
            self.doubleTapSlop = doubleTapSlop
            self.pointsPerNotch = pointsPerNotch
            self.trackpadSpeed = trackpadSpeed
            self.multiTouchGrace = multiTouchGrace
        }
    }

    /// Call ``reset()`` after changing it mid-gesture.
    public var mode: Mode
    public var tuning: Tuning
    /// Updated by the view on layout and picture-size changes.
    public var mapping: PointerMapping
    /// Where the client keeps the pointer (0...1): the last position sent.
    /// In trackpad mode the view draws the cursor here.
    public private(set) var cursor = CGPoint(x: 0.5, y: 0.5)

    public init(mode: Mode, mapping: PointerMapping, tuning: Tuning = .init()) {
        self.mode = mode
        self.mapping = mapping
        self.tuning = tuning
    }

    private struct Finger {
        var start: CGPoint
        var location: CGPoint
        /// Where the trackpad cursor last followed this finger from.
        var anchor: CGPoint
        /// The farthest it has been from `start`.
        var travel: CGFloat
    }

    private struct Tap {
        var location: CGPoint
        var position: CGPoint
        var lift: TimeInterval
    }

    /// Fingers down, nothing decided yet: a tap, a long press, a drag or a
    /// scroll may still come of it.
    private struct Pending {
        var ids: [Int]
        /// Every participant's touch-down point, lifted ones too.
        var starts: [CGPoint]
        var firstDown: TimeInterval
        var maxFingers: Int
        /// Some participant has travelled `slop`: no longer a tap.
        var moved = false
        /// The previous gesture was a one-finger tap that lifted within
        /// `doubleTapInterval` of this one's touch-down.
        var previousTap: Tap?
    }

    private enum Phase {
        case idle
        case pending(Pending)
        /// The left button is held and follows this finger (direct drag,
        /// trackpad tap-and-drag).
        case dragging(Int)
        /// Trackpad: this finger moves the cursor.
        case pointing(Int)
        /// Two-finger pan, last centroid.
        case scrolling([Int], CGPoint)
        /// Done (or given up): nothing more until every finger is up.
        case ignoring
    }

    private var fingers: [Int: Finger] = [:]
    private var phase = Phase.idle
    private var leftHeld = false
    /// The last gesture, if it was a one-finger tap.
    private var lastTap: Tap?

    /// When to call ``update(at:)``: the long press, or the end of the grace
    /// period for a one-finger drag that has already moved.
    public var nextDeadline: TimeInterval? {
        guard case .pending(let p) = phase, p.maxFingers == 1 else { return nil }
        if p.moved { return p.firstDown + tuning.multiTouchGrace }
        return mode == .direct ? p.firstDown + tuning.longPressDuration : nil
    }

    public mutating func began(_ touches: [Touch], at time: TimeInterval) -> [TouchPointerAction] {
        var out = fireTimers(at: time)
        for t in touches {
            fingers[t.id] = Finger(start: t.location, location: t.location, anchor: t.location, travel: 0)
            switch phase {
            case .idle:
                let previous = lastTap.flatMap { time - $0.lift <= tuning.doubleTapInterval ? $0 : nil }
                lastTap = nil
                phase = .pending(Pending(ids: [t.id], starts: [t.location], firstDown: time, maxFingers: 1,
                                         previousTap: previous))
            case .pending(var p):
                // Nothing has committed yet: the finger joins the gesture.
                p.ids.append(t.id)
                p.starts.append(t.location)
                p.maxFingers = max(p.maxFingers, p.ids.count)
                phase = .pending(p)
            default:
                // A committed gesture: extra fingers are ignored.
                break
            }
        }
        out += advance(at: time)
        return out
    }

    public mutating func moved(_ touches: [Touch], at time: TimeInterval) -> [TouchPointerAction] {
        // A long press that came due fires first; a held-back drag commits
        // below, from the new locations.
        var out = fireLongPress(at: time)
        let ids = Set(touches.compactMap { place($0) ? $0.id : nil })
        guard !ids.isEmpty else { return out }
        switch phase {
        case .dragging(let id) where ids.contains(id), .pointing(let id) where ids.contains(id):
            out += follow(id)
        case .scrolling(let pair, let last):
            let c = centroid(pair.map { fingers[$0]!.location })
            phase = .scrolling(pair, c)
            out += scroll(from: last, to: c)
        default:
            out += advance(at: time)
        }
        return out
    }

    public mutating func ended(_ touches: [Touch], at time: TimeInterval) -> [TouchPointerAction] {
        var out = fireLongPress(at: time)
        for t in touches where place(t) {
            out += lift(t.id, at: time, cancelled: false)
        }
        return out
    }

    public mutating func cancelled(_ touches: [Touch], at time: TimeInterval) -> [TouchPointerAction] {
        var out: [TouchPointerAction] = []
        for t in touches where fingers[t.id] != nil {
            out += lift(t.id, at: time, cancelled: true)
        }
        return out
    }

    /// Fires what is due by `time`: the long press, or a drag held back by
    /// the grace period.
    public mutating func update(at time: TimeInterval) -> [TouchPointerAction] {
        fireTimers(at: time)
    }

    /// Ends whatever is in progress (focus lost, mode switch): releases held
    /// buttons and forgets the fingers; their later events are ignored.
    public mutating func reset() -> [TouchPointerAction] {
        var out: [TouchPointerAction] = []
        if leftHeld { out.append(release(PointerButton.left)) }
        fingers = [:]
        phase = .idle
        lastTap = nil
        return out
    }

    // MARK: - State machine

    /// Records a touch's new location; false for a finger it doesn't know.
    private mutating func place(_ t: Touch) -> Bool {
        guard var f = fingers[t.id] else { return false }
        f.location = t.location
        f.travel = max(f.travel, distance(f.start, t.location))
        fingers[t.id] = f
        if case .pending(var p) = phase, p.ids.contains(t.id), f.travel >= tuning.slop, !p.moved {
            p.moved = true
            phase = .pending(p)
        }
        return true
    }

    /// Commits a pending gesture whose fingers have moved: one finger
    /// (after the grace period) drags or points, two scroll, more give up.
    private mutating func advance(at time: TimeInterval) -> [TouchPointerAction] {
        guard case .pending(let p) = phase, p.moved else { return [] }
        if p.maxFingers == 1 {
            return time >= p.firstDown + tuning.multiTouchGrace ? commitOne(p) : []
        }
        if p.maxFingers == 2, p.ids.count == 2 { return commitScroll(p) }
        phase = .ignoring
        return []
    }

    private mutating func fireTimers(at time: TimeInterval) -> [TouchPointerAction] {
        fireLongPress(at: time) + advance(at: time)
    }

    private mutating func fireLongPress(at time: TimeInterval) -> [TouchPointerAction] {
        guard case .pending(let p) = phase, p.maxFingers == 1, !p.moved, mode == .direct,
              time >= p.firstDown + tuning.longPressDuration else { return [] }
        // Long press: a right click where the finger is, then the finger is spent.
        phase = .ignoring
        return [.longPress, moveTo(mapping.normalized(p.starts[0]).position)] + click(PointerButton.right)
    }

    private mutating func commitOne(_ p: Pending) -> [TouchPointerAction] {
        let id = p.ids[0]
        var out: [TouchPointerAction] = []
        switch mode {
        case .direct:
            // Press where the finger came down, then catch up with it.
            out.append(moveTo(mapping.normalized(fingers[id]!.start).position))
            out.append(press(PointerButton.left))
            phase = .dragging(id)
        case .trackpad:
            if p.previousTap != nil {
                out.append(press(PointerButton.left))
                phase = .dragging(id)
            } else {
                phase = .pointing(id)
            }
        }
        return out + follow(id)
    }

    private mutating func commitScroll(_ p: Pending) -> [TouchPointerAction] {
        let start = centroid(p.ids.map { fingers[$0]!.start })
        let now = centroid(p.ids.map { fingers[$0]!.location })
        var out: [TouchPointerAction] = []
        // Scrolling goes to what is under the pointer.
        if mode == .direct { out.append(moveTo(mapping.normalized(start).position)) }
        phase = .scrolling(p.ids, now)
        return out + scroll(from: start, to: now)
    }

    private mutating func lift(_ id: Int, at time: TimeInterval, cancelled: Bool) -> [TouchPointerAction] {
        var out: [TouchPointerAction] = []
        // A flick that lifts inside the grace period still drags or points.
        if !cancelled, case .pending(let p) = phase, p.maxFingers == 1, p.moved {
            out += commitOne(p)
        }
        // The pointer goes as far as the finger did before letting go.
        if !cancelled {
            switch phase {
            case .dragging(let d) where d == id, .pointing(let d) where d == id: out += follow(id)
            default: break
            }
        }
        fingers[id] = nil
        switch phase {
        case .pending(var p):
            p.ids.removeAll { $0 == id }
            if cancelled {
                phase = .ignoring
            } else if p.ids.isEmpty {
                phase = .idle
                out += tap(p, at: time)
            } else {
                phase = .pending(p)
            }
        case .dragging(let d) where d == id:
            out.append(release(PointerButton.left))
            phase = .ignoring
        case .pointing(let d) where d == id:
            phase = .ignoring
        case .scrolling(let pair, _) where pair.contains(id):
            // Fewer than two fingers: the scroll is over.
            phase = .ignoring
        default:
            break
        }
        if fingers.isEmpty { phase = .idle }
        return out
    }

    /// The end of a pending gesture: a click if it was a quick, still tap.
    private mutating func tap(_ p: Pending, at time: TimeInterval) -> [TouchPointerAction] {
        guard !p.moved, time - p.firstDown <= tuning.tapMaxDuration else { return [] }
        let button: UInt32
        switch p.maxFingers {
        case 1: button = PointerButton.left
        case 2: button = PointerButton.right
        case 3: button = PointerButton.middle
        default: return []
        }
        guard mode == .direct else {
            if p.maxFingers == 1 { lastTap = Tap(location: p.starts[0], position: cursor, lift: time) }
            return click(button)
        }
        var tap = Tap(location: centroid(p.starts), position: mapping.normalized(centroid(p.starts)).position, lift: time)
        if p.maxFingers == 1 {
            // A double tap lands exactly on the first, so the host sees a clean double-click.
            if let prev = p.previousTap, distance(prev.location, tap.location) <= tuning.doubleTapSlop {
                tap.location = prev.location
                tap.position = prev.position
            }
            lastTap = tap
        }
        return [moveTo(tap.position)] + click(button)
    }

    /// The pointer catches up with a dragging or pointing finger.
    private mutating func follow(_ id: Int) -> [TouchPointerAction] {
        guard var f = fingers[id] else { return [] }
        let target: CGPoint
        switch mode {
        case .direct:
            target = mapping.normalized(f.location).position
        case .trackpad:
            let r = mapping.videoRect
            guard r.width > 0, r.height > 0 else { return [] }
            let dx = (f.location.x - f.anchor.x) * tuning.trackpadSpeed / r.width
            let dy = (f.location.y - f.anchor.y) * tuning.trackpadSpeed / r.height
            f.anchor = f.location
            fingers[id] = f
            target = CGPoint(x: min(max(cursor.x + dx, 0), 1), y: min(max(cursor.y + dy, 0), 1))
        }
        return target == cursor ? [] : [moveTo(target)]
    }

    /// Content follows the fingers: fingers moving up scroll down.
    private func scroll(from a: CGPoint, to b: CGPoint) -> [TouchPointerAction] {
        guard a != b, tuning.pointsPerNotch > 0 else { return [] }
        // + 0: no negative zero on the axis that didn't move.
        return [.scroll(horizontal: Double((a.x - b.x) / tuning.pointsPerNotch) + 0,
                        vertical: Double((a.y - b.y) / tuning.pointsPerNotch) + 0)]
    }

    // MARK: - Emitting

    private mutating func moveTo(_ position: CGPoint) -> TouchPointerAction {
        cursor = position
        return .move(position)
    }

    private mutating func press(_ button: UInt32) -> TouchPointerAction {
        if button == PointerButton.left { leftHeld = true }
        return .button(button, pressed: true)
    }

    private mutating func release(_ button: UInt32) -> TouchPointerAction {
        if button == PointerButton.left { leftHeld = false }
        return .button(button, pressed: false)
    }

    private func click(_ button: UInt32) -> [TouchPointerAction] {
        [.button(button, pressed: true), .button(button, pressed: false)]
    }
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(b.x - a.x, b.y - a.y)
}

private func centroid(_ points: [CGPoint]) -> CGPoint {
    guard !points.isEmpty else { return .zero }
    let n = CGFloat(points.count)
    return CGPoint(x: points.reduce(0) { $0 + $1.x } / n, y: points.reduce(0) { $0 + $1.y } / n)
}

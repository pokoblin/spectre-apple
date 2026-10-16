import Foundation

/// Decides, from a region's signatures over time, when to alert
/// (docs/ipad-layout.md, region alerts). Times are seconds on any steady clock.
///
/// - ``Condition/stopsChanging``: the region changed and has since been
///   still for ``stillSeconds``, say a build's output that stopped
///   scrolling. A region still from the start doesn't alert: it has to
///   change first. One alert per still spell.
/// - ``Condition/startsChanging``: the region was still for
///   ``stillSeconds`` and then changed. After an alert it has to be still
///   that long again before the next.
public struct RegionWatcher: Sendable {
    public enum Condition: String, Codable, Sendable, CaseIterable {
        case stopsChanging
        case startsChanging
    }

    /// What the region's outline shows.
    public enum State: Sendable, Equatable {
        /// Watching; nothing changed lately.
        case watching
        /// Changed within ``changingWindow``.
        case changing
        /// Alerted within ``alertedDuration`` and not changed since (the
        /// change that alerted aside), until dismissed.
        case alerted
    }

    /// How long after its last change a region still counts as changing.
    public static let changingWindow: TimeInterval = 1
    /// How long an alert is shown (the banner, the green outline).
    public static let alertedDuration: TimeInterval = 5

    public let condition: Condition
    public let stillSeconds: TimeInterval

    private var last: RegionSignature?
    private var lastChange: TimeInterval?
    /// Since when the region has been still, as far as this watcher saw.
    private var stillSince: TimeInterval?
    /// The condition's first half is met: the next still spell
    /// (``Condition/stopsChanging``) or change (``Condition/startsChanging``) alerts.
    private var armed = false
    private var alertedAt: TimeInterval?

    public init(condition: Condition, stillSeconds: TimeInterval) {
        self.condition = condition
        self.stillSeconds = stillSeconds
    }

    /// Takes the region's signature at time `t`; true when that makes an alert.
    public mutating func observe(_ signature: RegionSignature, at t: TimeInterval) -> Bool {
        defer { last = signature }
        guard let last, let stillSince else {
            stillSince = t // the first look: what the region is like now
            return false
        }
        if signature.columns != last.columns || signature.rows != last.rows {
            self.stillSince = t // the picture changed size: compare from here
            return false
        }
        if signature.differs(from: last) {
            lastChange = t
            self.stillSince = t
            switch condition {
            case .stopsChanging:
                armed = true
            case .startsChanging:
                if armed { return alert(at: t) }
            }
            return false
        }
        guard t - stillSince >= stillSeconds else { return false }
        switch condition {
        case .stopsChanging:
            if armed { return alert(at: t) }
        case .startsChanging:
            armed = true
        }
        return false
    }

    private mutating func alert(at t: TimeInterval) -> Bool {
        armed = false
        alertedAt = t
        return true
    }

    public func state(at t: TimeInterval) -> State {
        if let alertedAt, t - alertedAt < Self.alertedDuration, lastChange.map({ $0 <= alertedAt }) ?? true {
            return .alerted
        }
        if let lastChange, t - lastChange < Self.changingWindow { return .changing }
        return .watching
    }

    /// The alert was seen (its banner tapped): the outline goes back to watching.
    public mutating func dismissAlert() { alertedAt = nil }

    /// Looking again after a gap (the app was in the background, no frames
    /// decoded): the region wasn't seen to be still meanwhile, so the still
    /// spell starts over at `t`. The last signature stays, so a change made
    /// in the gap still shows on the next look.
    public mutating func resume(at t: TimeInterval) {
        if stillSince != nil { stillSince = t }
    }
}

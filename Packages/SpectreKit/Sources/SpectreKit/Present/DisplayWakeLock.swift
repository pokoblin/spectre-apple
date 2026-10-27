import Foundation
#if os(iOS)
import UIKit
#endif

/// Keeps this device's display awake (no screensaver, no display sleep)
/// while held: for a remote desktop that an application there holds awake,
/// a video playing or a game (gdp-spec.md §7.13), as the local desktop's
/// own inhibitors would.
///
/// Each session holds its own. On the Mac each is a power assertion of its
/// own; iOS has one switch for the app, `isIdleTimerDisabled`, shared by
/// every session window, so it stays on until the last one lets go.
@MainActor
public final class DisplayWakeLock {
    public private(set) var isHeld = false
    #if os(macOS)
    private var activity: NSObjectProtocol?
    #else
    private static var holders = 0
    #endif

    public init() {}

    public func hold(_ on: Bool) {
        guard on != isHeld else { return }
        isHeld = on
        #if os(macOS)
        if on {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .idleDisplaySleepDisabled, reason: "The remote desktop is held awake")
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #else
        Self.holders += on ? 1 : -1
        UIApplication.shared.isIdleTimerDisabled = Self.holders > 0
        #endif
    }

    isolated deinit { hold(false) }
}

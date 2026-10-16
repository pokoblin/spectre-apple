import SpectreKit
import SwiftUI
import UIKit
import UserNotifications

/// The session's region alert (docs/ipad-layout.md): a region of the
/// remote desktop, chosen by dragging over the picture, that is compared
/// four times a second on the decoded frames, alerting when it stops or
/// starts changing (``RegionWatcher``).
///
/// It watches while the session plays and the app is in front, including
/// an inactive window beside another app or in Stage Manager; then the
/// alert is also a notification. In the background nothing is decoded
/// (VideoToolbox can't, see PlaybackModel), so watching pauses there, as
/// it does while reconnecting, and picks up on return.
@MainActor
@Observable
final class RegionAlertModel {
    /// Dragging out a new region over the picture.
    private(set) var isSelecting = false
    /// What the outline shows; nil while nothing is watched.
    private(set) var state: RegionWatcher.State?
    /// Counts the alerts: the banner shows for each.
    private(set) var alertCount = 0
    /// The condition of the last alert, for the banner's words.
    private(set) var lastAlert = RegionWatcher.Condition.stopsChanging

    /// How often the region is looked at.
    static let interval: Duration = .milliseconds(250)

    @ObservationIgnored private let store = RegionAlertStore.shared
    /// Observed: views read ``alert`` before ``attach(presenter:key:title:isLive:)``
    /// sets it, and must read it again then.
    private var key = ""
    @ObservationIgnored private var title = ""
    @ObservationIgnored private weak var presenter: VideoPresenter?
    @ObservationIgnored private var isLive: () -> Bool = { false }
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private var watcher: RegionWatcher?
    /// The frame the last signature is of: an unchanged picture isn't read again.
    @ObservationIgnored private var last: (sequence: UInt64, signature: RegionSignature)?
    @ObservationIgnored private var wasPaused = false

    /// The session's alert, if it has one.
    var alert: RegionAlert? { store[key] }

    /// Starts watching the session's region, if it has one. `isLive`: the
    /// session is playing (not connecting or reconnecting, its last picture frozen).
    func attach(presenter: VideoPresenter?, key: String, title: String, isLive: @escaping () -> Bool) {
        self.presenter = presenter
        self.key = key
        self.title = title
        self.isLive = isLive
        restartWatcher()
        sampling?.cancel()
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: Self.interval)) != nil else { return }
                await self?.sample()
            }
        }
    }

    func detach() {
        sampling?.cancel()
        sampling = nil
    }

    // MARK: Choosing the region

    func startSelecting() { isSelecting = true }
    func cancelSelecting() { isSelecting = false }

    /// The dragged-out region (0...1 over the picture): watched from now on,
    /// with the alert's condition kept if there was one.
    func select(_ region: CGRect) {
        var alert = alert ?? RegionAlert(region: region)
        alert.region = region
        store[key] = alert
        isSelecting = false
        restartWatcher()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func setCondition(_ condition: RegionWatcher.Condition) {
        guard var alert, alert.condition != condition else { return }
        alert.condition = condition
        store[key] = alert
        restartWatcher()
    }

    func setStillSeconds(_ seconds: Int) {
        guard var alert, alert.stillSeconds != seconds else { return }
        alert.stillSeconds = seconds
        store[key] = alert
        restartWatcher()
    }

    func remove() {
        store[key] = nil
        restartWatcher()
    }

    /// The banner was tapped: the outline goes back to watching.
    func dismissAlert() {
        watcher?.dismissAlert()
        updateState()
    }

    // MARK: Watching

    private func restartWatcher() {
        watcher = alert.map { RegionWatcher(condition: $0.condition, stillSeconds: TimeInterval($0.stillSeconds)) }
        last = nil
        updateState()
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func sample() async {
        guard let alert, watcher != nil else { return }
        let live = isLive() && UIApplication.shared.applicationState != .background
        guard live, let presenter, let frame = presenter.lastFrame else {
            wasPaused = true
            return updateState()
        }
        if wasPaused {
            wasPaused = false
            watcher?.resume(at: Self.now)
        }
        let signature: RegionSignature
        if let last, last.sequence == frame.sequence {
            signature = last.signature
        } else {
            let displaySize = presenter.displaySize, region = alert.region
            let made = await Task.detached(priority: .utility) {
                RegionSignature.make(pixelBuffer: frame.pixelBuffer, displaySize: displaySize, region: region)
            }.value
            // The region or its alert may have changed meanwhile.
            guard let made, self.alert == alert else { return }
            last = (frame.sequence, made)
            signature = made
        }
        if watcher?.observe(signature, at: Self.now) == true { alerted(alert.condition) }
        updateState()
    }

    private func updateState() {
        let state = watcher?.state(at: Self.now)
        if state != self.state { self.state = state }
    }

    private func alerted(_ condition: RegionWatcher.Condition) {
        lastAlert = condition
        alertCount += 1
        print("region alert: \(condition.rawValue)")
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Spectre" : title
        content.body = Self.message(condition)
        content.sound = .default
        // One per session: a newer alert replaces the one not yet read.
        let request = UNNotificationRequest(identifier: "region-alert.\(key)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func message(_ condition: RegionWatcher.Condition) -> String {
        switch condition {
        case .stopsChanging: String(localized: "The watched region stopped changing.")
        case .startsChanging: String(localized: "The watched region started changing.")
        }
    }
}

/// Shows notifications while the app is in front: a region alert is only
/// sent then when the app's window isn't the active one (beside another
/// app, in Stage Manager), where it would otherwise not appear.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

import Foundation
import Observation
import SpectreKit

/// A region of a host's remote desktop to watch, and when to alert
/// (docs/ipad-layout.md, region alerts).
struct RegionAlert: Codable, Equatable {
    /// 0...1 each way over the remote picture, top-left origin.
    var region: CGRect
    var condition: RegionWatcher.Condition = .stopsChanging
    /// How long the region has to be still (see ``RegionWatcher``).
    var stillSeconds = 5

    static let stillChoices = [3, 5, 10, 30, 60]

    /// "3 seconds", "1 minute", in the user's language.
    static func duration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }
}

/// Each host's region alert, on this device only. Keyed by the saved
/// host's id; sessions started from the command line by their source
/// (``PlaybackModel/regionKey``).
@MainActor
@Observable
final class RegionAlertStore {
    static let shared = RegionAlertStore()

    private(set) var alerts: [String: RegionAlert]
    private static let key = "regionAlerts"

    private init() {
        alerts = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: RegionAlert].self, from: $0) } ?? [:]
    }

    subscript(key: String) -> RegionAlert? {
        get { alerts[key] }
        set {
            guard alerts[key] != newValue else { return }
            alerts[key] = newValue
            if let data = try? JSONEncoder().encode(alerts) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    subscript(host id: UUID) -> RegionAlert? {
        get { self[id.uuidString] }
        set { self[id.uuidString] = newValue }
    }
}

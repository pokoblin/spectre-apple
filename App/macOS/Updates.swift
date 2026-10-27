import Sparkle
import SwiftUI

/// Spectre › Check for Updates…, and the checks Sparkle makes on its own
/// (scripts/make-appcast.sh).
///
/// The feed and the key its updates are signed with are build settings
/// (project.yml: SPARKLE_FEED_URL, SPARKLE_PUBLIC_ED_KEY), put in the
/// Info.plist by App/macOS/Info.plist. A build without the key, as one from
/// source, has no updater: Sparkle won't start without it, and the menu item
/// and the Settings toggle aren't there.
@MainActor
final class Updates {
    /// Sparkle keeps the choice under its own key in the app's defaults.
    static let automaticChecksKey = "SUEnableAutomaticChecks"

    private let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                          updaterDelegate: nil,
                                                          userDriverDelegate: nil)

    /// Whether this build has a feed and a key to check it with.
    let isAvailable: Bool

    init() {
        isAvailable = ["SUFeedURL", "SUPublicEDKey"].allSatisfy {
            !(Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "").isEmpty
        }
        if isAvailable { controller.startUpdater() }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Through the updater rather than the defaults alone, so that it
    /// reschedules its next check.
    func setAutomaticChecks(_ on: Bool) {
        controller.updater.automaticallyChecksForUpdates = on
    }
}

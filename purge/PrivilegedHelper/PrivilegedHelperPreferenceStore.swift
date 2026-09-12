import Combine
import Foundation
import ServiceManagement

/// Holds the privileged helper's live status for Settings and the uninstall flow.
/// The status always comes from macOS, including changes the user makes directly in
/// System Settings.
@MainActor
final class PrivilegedHelperPreferenceStore: ObservableObject {
    static let shared = PrivilegedHelperPreferenceStore()

    private let manager = PrivilegedHelperManager.shared

    @Published private(set) var status: SMAppService.Status
    /// Set when a registration attempt could neither enable nor reach approval, so the
    /// UI can offer a clear retry action.
    @Published private(set) var lastRegistrationFailed = false

    private init() {
        status = PrivilegedHelperManager.shared.status
    }

    var isEnabled: Bool { status == .enabled }

    /// The helper is registered but still needs the user to approve it in System Settings.
    var needsApproval: Bool { status == .requiresApproval }

    /// Re-reads the daemon status. Cheap; call it when the window returns to the
    /// foreground so a change made in System Settings is picked up.
    func refresh() {
        let latest = manager.status
        // Low-volume and only on refresh: lets us confirm from Console what the app
        // actually reads after the user flips the switch, when a non-notarized dev
        // build makes SMAppService status hard to trust.
        NSLog("Purge: helper status = %ld", latest.rawValue)
        status = latest
        if status == .enabled { lastRegistrationFailed = false }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            lastRegistrationFailed = false
            switch manager.register() {
            case .enabled:
                break
            case .needsApproval:
                manager.openLoginItemsSettings()
            case .failed(let detail):
                lastRegistrationFailed = true
                NSLog("Purge: helper registration failed — %@", detail)
            }
        } else {
            lastRegistrationFailed = false
            Task {
                await manager.unregister()
                refresh()
            }
        }
        refresh()
    }

    func openLoginItemsSettings() {
        manager.openLoginItemsSettings()
    }
}

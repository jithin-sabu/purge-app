import Combine
import Foundation
import ServiceManagement

/// Backs the Settings toggle for the privileged helper. Holds the daemon's live
/// `SMAppService` status so the switch reflects reality — including changes the user
/// makes directly in System Settings — and turns a toggle into a register /
/// unregister, nudging the user to the Login Items pane when approval is pending.
@MainActor
final class PrivilegedHelperPreferenceStore: ObservableObject {
    static let shared = PrivilegedHelperPreferenceStore()

    private let manager = PrivilegedHelperManager.shared

    @Published private(set) var status: SMAppService.Status
    /// True right after a toggle-on that landed in `.requiresApproval`, so the UI can
    /// explain the one remaining step without nagging on every status refresh.
    @Published private(set) var awaitingApproval = false

    private init() {
        status = PrivilegedHelperManager.shared.status
    }

    var isEnabled: Bool { status == .enabled }

    /// Re-reads the daemon status. Cheap; call it when the window returns to the
    /// foreground so a change made in System Settings is picked up.
    func refresh() {
        status = manager.status
        if status == .enabled { awaitingApproval = false }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            switch manager.register() {
            case .enabled:
                awaitingApproval = false
            case .needsApproval:
                awaitingApproval = true
                manager.openLoginItemsSettings()
            case .failed:
                awaitingApproval = false
            }
        } else {
            awaitingApproval = false
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

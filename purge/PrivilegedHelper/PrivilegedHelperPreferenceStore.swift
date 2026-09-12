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

    /// The most recent state the user asked for. A request that is superseded before
    /// its turn is dropped, so the helper always settles on the last thing asked.
    private var desiredEnabled: Bool?
    /// Serializes register/unregister so a slow `unregister()` can never land after a
    /// newer `register()` and leave the helper in the wrong state.
    private var applyTask: Task<Void, Never>?
    /// macOS does not send the app a notification when the user approves a background
    /// helper in System Settings. Poll briefly while approval is pending so the
    /// uninstall screen can continue as soon as the switch is turned on.
    private var approvalMonitorTask: Task<Void, Never>?

    func setEnabled(_ enabled: Bool) {
        desiredEnabled = enabled
        lastRegistrationFailed = false
        if !enabled { approvalMonitorTask?.cancel() }
        let previous = applyTask
        applyTask = Task { @MainActor in
            _ = await previous?.value
            // A later request took over while this one waited; let that one decide.
            guard desiredEnabled == enabled else { return }
            if enabled {
                switch manager.register() {
                case .enabled:
                    approvalMonitorTask?.cancel()
                    break
                case .needsApproval:
                    monitorPendingApproval()
                    manager.openLoginItemsSettings()
                case .failed(let detail):
                    approvalMonitorTask?.cancel()
                    lastRegistrationFailed = true
                    NSLog("Purge: helper registration failed — %@", detail)
                }
            } else {
                await manager.unregister()
            }
            refresh()
        }
    }

    private func monitorPendingApproval() {
        approvalMonitorTask?.cancel()
        approvalMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Five minutes is long enough to read the explanation and find the switch,
            // without leaving a permanent timer running in the app.
            for _ in 0..<600 {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard desiredEnabled == true else { return }
                refresh()
                if isEnabled || !needsApproval { return }
            }
        }
    }

    func openLoginItemsSettings() {
        manager.openLoginItemsSettings()
    }
}

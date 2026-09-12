import Foundation
import ServiceManagement

/// The app's side of the privileged helper: registers the root daemon through
/// `SMAppService`, reports whether it is enabled, and dials it over XPC to move
/// admin-owned bundles to the Trash without a per-uninstall password.
///
    /// Registration is a one-time setup. macOS shows the daemon under the app in
/// System Settings and the user enables it there. Once enabled, uninstalls of
/// locked apps can use the helper without another password prompt.
@MainActor
final class PrivilegedHelperManager {
    static let shared = PrivilegedHelperManager()

    // A fresh handle every read. A cached `SMAppService.daemon` reports the status it
    // saw at creation, so after the user flips the switch in System Settings a stored
    // instance keeps saying `.requiresApproval` — which left the UI stuck and made
    // "Set Up" reopen Settings forever. Re-derive it so `status` is always current.
    private var service: SMAppService {
        SMAppService.daemon(plistName: PurgeHelperConstants.daemonPlistName)
    }

    private init() {}

    enum Registration: Equatable {
        case enabled
        case needsApproval
        case failed(String)
    }

    var status: SMAppService.Status { service.status }

    /// Registers the daemon if it isn't already. A fresh registration lands in
    /// `.requiresApproval` until the user flips it on in System Settings, so this
    /// reports which of the two happened rather than pretending it is live.
    @discardableResult
    func register() -> Registration {
        let statusBeforeRegistration = service.status
        do {
            try service.register()
        } catch {
            // Calling register for an already-loaded helper throws harmlessly. We also
            // call it when macOS still says "enabled" but dropped the launch job after
            // an app update, because that call loads the approved helper again.
            if statusBeforeRegistration != .enabled {
                NSLog("Purge: helper register() threw — %@", error.localizedDescription)
            }
        }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        default: return .failed("status \(service.status.rawValue)")
        }
    }

    @discardableResult
    func unregister() async -> Bool {
        do {
            try await service.unregister()
            return true
        } catch {
            NSLog("Purge: helper unregister() failed — %@", error.localizedDescription)
            return false
        }
    }

    /// Opens the Login Items pane so the user can enable the pending helper.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Moving is quick, but handing ownership of every file in a large app back to the
    /// user can take minutes. A timeout is therefore an unknown result, never proof
    /// that nothing moved.
    private static let moveTimeout: TimeInterval = 300
    private static let versionTimeout: TimeInterval = 10

    /// Builds a connection to the helper and applies the code-signing requirement so
    /// we only ever talk to the genuine, same-team daemon — the mirror of the check the
    /// helper runs on us.
    private func vettedConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: PurgeHelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: PurgeHelperProtocol.self)
        connection.setCodeSigningRequirement(PurgeHelperConstants.helperRequirement)
        connection.resume()
        return connection
    }

    /// Moves `urls` to the connecting user's Trash through the helper. Returns `nil`
    /// when the helper is not enabled or the connection fails, so the caller knows
    /// escalation did not happen. Never throws: escalation is best-effort.
    func moveToTrash(_ urls: [URL]) async -> PrivilegedMoveResult? {
        // A helper can be approved after app launch. Check again here so an old,
        // newly-approved copy is replaced before it receives the current protocol.
        // A definite, un-fixable version mismatch reports "not ready" rather than
        // letting a stale helper serve the request, so we never silently run an old
        // binary: the caller then offers one-time setup instead.
        let ready = await reconcileVersion()
        guard ready, !urls.isEmpty else { return nil }
        let connection = vettedConnection()
        defer { connection.invalidate() }

        let sentPaths = urls.map(\.path)
        return await withCheckedContinuation { (continuation: CheckedContinuation<PrivilegedMoveResult?, Never>) in
            let box = ContinuationBox(continuation)

            // The helper may already have moved one or more paths before a timeout.
            // Preserve that uncertainty so callers do not report a false failure or
            // immediately retry an operation that may still be finishing.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.moveTimeout) {
                box.resume(PrivilegedMoveResult(moved: [], failed: [], indeterminate: urls))
            }

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                // An enabled helper that faults mid-call may already have moved one or
                // more paths. Mark them indeterminate — same as the timeout path — so the
                // caller keeps the honest original error instead of demoting an enabled
                // helper to a "needs administrator setup" retry.
                NSLog("Purge: helper XPC error — %@", error.localizedDescription)
                box.resume(PrivilegedMoveResult(moved: [], failed: [], indeterminate: urls))
            } as? PurgeHelperProtocol

            guard let proxy else {
                box.resume(nil)
                return
            }

            proxy.moveToTrashReportingOwnership(
                paths: sentPaths
            ) { movedPaths, ownershipIncompletePaths in
                let movedSet = Set(movedPaths)
                let incompleteSet = Set(ownershipIncompletePaths)
                let moved = urls.filter { movedSet.contains($0.path) }
                let failed = urls.filter { !movedSet.contains($0.path) }
                let ownershipIncomplete = urls.filter { incompleteSet.contains($0.path) }
                box.resume(PrivilegedMoveResult(
                    moved: moved,
                    failed: failed,
                    indeterminate: [],
                    ownershipIncomplete: ownershipIncomplete
                ))
            }
        }
    }

    /// The version an enabled helper reports, or `nil` if it can't be reached in time.
    /// Deliberately distinguishes "no answer" (nil) from a real version string so the
    /// caller never re-registers on a flaky call.
    private func installedHelperVersion() async -> String? {
        let connection = vettedConnection()
        defer { connection.invalidate() }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let box = VersionBox(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.versionTimeout) {
                box.resume(nil)
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                box.resume(nil)
            } as? PurgeHelperProtocol
            guard let proxy else { box.resume(nil); return }
            proxy.helperVersion { version in box.resume(version) }
        }
    }

    /// If an enabled helper reports a version other than the one this app ships, an
    /// older copy survived an app update — re-register to install the current binary.
    /// A definite mismatch replaces the old registration. A missing answer refreshes
    /// the existing approved registration without removing it or asking again.
    /// Returns `true` when an enabled helper at the current version is ready to serve
    /// a request. A definite version mismatch that survives re-registration returns
    /// `false`, so the caller treats the helper as not set up rather than trusting a
    /// stale binary to behave like the current one.
    @discardableResult
    func reconcileVersion() async -> Bool {
        guard service.status == .enabled else { return false }
        guard let installed = await installedHelperVersion() else {
            // SMAppService can report `.enabled` even though launchd no longer has the
            // job, most often after replacing Purge.app with a newer build. Registering
            // again reloads the already-approved daemon without removing the user's
            // permission or sending them back to System Settings. A flaky version query
            // is also possible, so let the request proceed — the move has its own
            // timeout and error handling for a genuinely dead helper.
            NSLog("Purge: enabled helper is unreachable — reloading registration")
            register()
            return true
        }
        guard installed != PurgeHelperConstants.version else { return true }

        NSLog("Purge: stale helper %@ (want %@) — re-registering", installed, PurgeHelperConstants.version)
        if await unregister() == false {
            // Removing the old registration failed. Re-registering on top of it can
            // leave the old binary in place, so confirm the version afterwards rather
            // than assuming the update took.
            NSLog("Purge: could not remove stale helper %@ before reinstalling", installed)
        }
        register()

        let afterUpdate = await installedHelperVersion()
        if afterUpdate == PurgeHelperConstants.version { return true }
        NSLog(
            "Purge: helper update did not take (installed %@, want %@) — offering setup instead of using the old helper",
            afterUpdate ?? "unreachable",
            PurgeHelperConstants.version
        )
        return false
    }
}

/// Guards a checked continuation so the XPC error handler and the reply block — which
/// can race on different queues — resume it exactly once.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PrivilegedMoveResult?, Never>?

    init(_ continuation: CheckedContinuation<PrivilegedMoveResult?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: PrivilegedMoveResult?) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

/// The version-query counterpart of `ContinuationBox`: the reply and the timeout race
/// on different queues, so this resumes the continuation exactly once.
private final class VersionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

import Combine
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
final class PrivilegedHelperManager: ObservableObject {
    static let shared = PrivilegedHelperManager()

    /// `true` when macOS reports the helper as enabled but it still did not answer
    /// after Purge reloaded it. Seen after an app update, when launchd keeps a job that
    /// points at the replaced bundle and fails every launch. The uninstall screen uses
    /// this to stop claiming "Secure removal is on" when it plainly is not working.
    @Published private(set) var isUnresponsive = false

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

    /// The same status, read off the main thread. Each read is an XPC round trip
    /// to the system, about a millisecond, and approval polling makes 600 of them.
    func statusOffMain() async -> SMAppService.Status {
        let plistName = PurgeHelperConstants.daemonPlistName
        return await Task.detached(priority: .utility) {
            SMAppService.daemon(plistName: plistName).status
        }.value
    }

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
        // binary. So does a helper that stays silent after a reload: a move sent to it
        // would wait out the full `moveTimeout` with the cleaning screen frozen.
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

    /// Returns `true` when an enabled helper at the current version is ready to serve
    /// a request. Anything else reports "not ready", so the caller offers setup or
    /// Finder instead of sending a request nobody will answer. See
    /// `HelperReconciler.reconcile` for the steps.
    @discardableResult
    func reconcileVersion() async -> Bool {
        // Unregistering stops the running helper, including an old copy whose file an
        // update replaced, and registering starts the one in this bundle. It also
        // points macOS back at this copy of Purge if its record named another one. In
        // testing on macOS 27 the user's approval survived this every time, so no
        // prompt appeared.
        let reload: (() async -> Void)?
        if Self.mayRepairRegistration() {
            reload = { await self.reloadRegistration() }
        } else {
            reload = nil
        }

        let outcome = await HelperReconciler.reconcile(
            isEnabled: { self.service.status == .enabled },
            expectedVersion: PurgeHelperConstants.version,
            probe: { await self.installedHelperVersion() },
            reload: reload
        )
        isUnresponsive = outcome == .unresponsive
        return outcome == .ready
    }

    private func reloadRegistration() async {
        if await unregister() == false {
            NSLog("Purge: could not remove the helper registration before reloading it")
        }
        try? await Task.sleep(for: .milliseconds(500))
        register()
    }

    /// Whether this copy of Purge may reload the helper's registration on its own.
    ///
    /// Registering ties the helper to the copy of Purge that registers it: launchd then
    /// starts the helper from inside that copy. A dev build, the unit-test host, or a
    /// copy run straight from the disk image would take the helper with it, and
    /// deleting or ejecting that copy leaves the helper with nowhere to start from.
    /// That is how this Mac's helper broke. So only an installed copy repairs the
    /// registration by itself. Turning the switch on in Settings still works from
    /// anywhere, because the user chose it.
    nonisolated static func mayRepairRegistration(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard !TestHost.isActive(environment: environment) else { return false }
        // Standardized, so a path like /Applications/../Users/x/Downloads cannot pass
        // the prefix check.
        let path = bundleURL.standardizedFileURL.path
        let userApplications = homeDirectory.standardizedFileURL
            .appendingPathComponent("Applications").path + "/"
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications)
    }
}

/// What checking the installed helper found.
enum HelperReconcileOutcome: Equatable {
    /// The user has not turned the helper on.
    case notEnabled
    /// The helper answered with the version this app ships.
    case ready
    /// The helper did not answer, even after a reload.
    case unresponsive
    /// The helper answered with an old version that reloading did not replace.
    case staleVersion
}

enum HelperReconciler {
    /// Checks an enabled helper before Purge sends it real work.
    ///
    /// 1. Ask for its version. The current version means it is ready.
    /// 2. No answer, or an old version: reload the helper, then ask once more. No
    ///    answer covers a launch job macOS dropped and an old process the app can no
    ///    longer verify because an update replaced its file.
    /// 3. Still no answer means the helper is not usable right now. A move request
    ///    would sit unanswered until its five-minute timeout, so report
    ///    `.unresponsive` instead of letting it through.
    ///
    /// A `nil` `reload` skips steps 2 and 3, for a copy of Purge that must not
    /// re-register the helper.
    ///
    /// The closures keep this free of XPC and `SMAppService`, so tests can drive it.
    static func reconcile(
        isEnabled: () -> Bool,
        expectedVersion: String,
        probe: () async -> String?,
        reload: (() async -> Void)?
    ) async -> HelperReconcileOutcome {
        guard isEnabled() else { return .notEnabled }

        let installed = await probe()
        if installed == expectedVersion { return .ready }
        guard let reload else {
            // This copy may not repair the registration (see `mayRepairRegistration`),
            // so report what it found without touching the helper.
            NSLog("Purge: helper not ready and this copy of Purge may not reload it")
            return installed == nil ? .unresponsive : .staleVersion
        }
        if let installed {
            NSLog("Purge: stale helper %@ (want %@), reloading", installed, expectedVersion)
        } else {
            NSLog("Purge: enabled helper is unreachable, reloading")
        }
        await reload()

        // If the reload cost the approval, the user needs setup, not a note that the
        // helper is not responding.
        guard isEnabled() else { return .notEnabled }

        let afterReload = await probe()
        if afterReload == expectedVersion { return .ready }
        NSLog(
            "Purge: helper not ready after reload (installed %@, want %@), not sending the move",
            afterReload ?? "unreachable",
            expectedVersion
        )
        return afterReload == nil ? .unresponsive : .staleVersion
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

import Foundation
import ServiceManagement

/// The app's side of the privileged helper: registers the root daemon through
/// `SMAppService`, reports whether it is enabled, and dials it over XPC to move
/// admin-owned bundles to the Trash without a per-uninstall password.
///
/// Registration is a one-time setup — macOS shows the daemon under the app in
/// System Settings and the user enables it there. Once enabled, uninstalls of
/// locked apps are silent; until then the caller falls back to the osascript prompt,
/// so the feature always works, just less smoothly before setup.
@MainActor
final class PrivilegedHelperManager {
    static let shared = PrivilegedHelperManager()

    private let service = SMAppService.daemon(plistName: PurgeHelperConstants.daemonPlistName)

    private init() {}

    enum Registration: Equatable {
        case enabled
        case needsApproval
        case failed(String)
    }

    var status: SMAppService.Status { service.status }

    /// The helper is installed, enabled, and ready to take a connection.
    var isReady: Bool { service.status == .enabled }

    /// Registers the daemon if it isn't already. A fresh registration lands in
    /// `.requiresApproval` until the user flips it on in System Settings, so this
    /// reports which of the two happened rather than pretending it is live.
    @discardableResult
    func register() -> Registration {
        if service.status == .enabled { return .enabled }
        do {
            try service.register()
        } catch {
            // `register()` throws if it is already registered; the status read below
            // is the real answer, so only a genuinely stuck state falls through.
            NSLog("Purge: helper register() threw — %@", error.localizedDescription)
        }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        default: return .failed("status \(service.status.rawValue)")
        }
    }

    func unregister() async {
        do {
            try await service.unregister()
        } catch {
            NSLog("Purge: helper unregister() failed — %@", error.localizedDescription)
        }
    }

    /// Opens the Login Items pane so the user can enable the pending helper.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Moves `urls` to `trashDirectory` through the helper. Returns `nil` when the
    /// helper is not enabled or the connection cannot be vetted, so the caller knows
    /// escalation did not happen. Never throws: escalation is best-effort.
    func moveToTrash(_ urls: [URL], trashDirectory: URL) async -> PrivilegedMoveResult? {
        guard service.status == .enabled, !urls.isEmpty else { return nil }

        let connection = NSXPCConnection(
            machServiceName: PurgeHelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: PurgeHelperProtocol.self)
        // Refuse to talk to anything but the genuine, same-team helper — the mirror of
        // the check the helper runs on us. If it can't be applied, don't risk it.
        do {
            try connection.setCodeSigningRequirement(PurgeHelperConstants.helperRequirement)
        } catch {
            NSLog("Purge: helper requirement not applied — %@", error.localizedDescription)
            connection.invalidate()
            return nil
        }
        connection.resume()
        defer { connection.invalidate() }

        let sentPaths = urls.map(\.path)
        return await withCheckedContinuation { (continuation: CheckedContinuation<PrivilegedMoveResult?, Never>) in
            let box = ContinuationBox(continuation)

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                NSLog("Purge: helper XPC error — %@", error.localizedDescription)
                box.resume(nil)
            } as? PurgeHelperProtocol

            guard let proxy else {
                box.resume(nil)
                return
            }

            proxy.moveToTrash(
                paths: sentPaths,
                trashDirectoryPath: trashDirectory.path,
                uid: Int(getuid()),
                gid: Int(getgid())
            ) { movedPaths in
                let movedSet = Set(movedPaths)
                let moved = urls.filter { movedSet.contains($0.path) }
                let failed = urls.filter { !movedSet.contains($0.path) }
                box.resume(PrivilegedMoveResult(moved: moved, failed: failed))
            }
        }
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

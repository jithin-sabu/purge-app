import Foundation

/// Decides who may talk to the root helper. The whole security of this daemon rests
/// here: it accepts a connection only after macOS itself confirms the peer is the
/// genuine, Apple-notarized, same-team Purge app.
///
/// The check is `NSXPCConnection.setCodeSigningRequirement`, the platform's own
/// vetting (macOS 13+), rather than a hand-rolled audit-token/`SecCode` dance — the
/// native path is the one Apple keeps correct as the attack landscape shifts, and a
/// bug in a bespoke check here would be a local root exploit.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    /// Quits the helper after 30 idle seconds so an app update never leaves an old
    /// copy answering. launchd's minimum runtime is 10 seconds, so a respawn soon after
    /// is never throttled.
    private let idleTracker = HelperIdleTracker(idleInterval: 30) {
        NSLog("PurgeHelper: idle, exiting until the next request")
        exit(0)
    }

    override init() {
        super.init()
        idleTracker.start()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // Refuse anything that is not the real Purge app. The requirement is a fixed,
        // tested constant and must be installed before the connection is resumed.
        newConnection.setCodeSigningRequirement(PurgeHelperConstants.clientRequirement)

        newConnection.exportedInterface = NSXPCInterface(with: PurgeHelperProtocol.self)
        // Every accepted connection holds the helper open until it ends, including one
        // that the signing requirement later refuses. Once the helper has committed to
        // quitting it takes no new work; the app sees the refusal and its next request
        // starts a fresh helper.
        guard idleTracker.acquire() else { return false }
        newConnection.exportedObject = HelperService(idleTracker: idleTracker)
        newConnection.invalidationHandler = { [idleTracker] in idleTracker.release() }
        newConnection.resume()
        return true
    }
}

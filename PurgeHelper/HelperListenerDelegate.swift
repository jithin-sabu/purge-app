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
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // Refuse anything that is not the real Purge app. If the requirement string
        // cannot even be applied, fail closed rather than serve an unvetted client.
        do {
            try newConnection.setCodeSigningRequirement(PurgeHelperConstants.clientRequirement)
        } catch {
            NSLog("PurgeHelper: rejecting connection, requirement not applied — %@", error.localizedDescription)
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: PurgeHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}

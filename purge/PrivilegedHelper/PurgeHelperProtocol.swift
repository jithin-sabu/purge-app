import Foundation

/// The single source of truth for the identifiers and code-signing requirements the
/// app and the privileged helper use to find and vouch for each other. Both targets
/// compile this file, so the two ends can never drift apart on a name or a
/// requirement string — a drift that would surface only as a silent XPC failure.
enum PurgeHelperConstants {
    /// launchd label, Mach service name, and helper bundle identifier — all one string.
    static let machServiceName = "io.getpurge.helper"

    /// The daemon property list bundled at `Contents/Library/LaunchDaemons/`, named
    /// to `SMAppService.daemon(plistName:)`.
    static let daemonPlistName = "io.getpurge.helper.plist"

    /// The team the app and helper are both signed by. Baked into the requirements
    /// below so a differently-signed binary can neither impersonate the app to the
    /// helper nor the helper to the app.
    static let teamIdentifier = "BX83ZBV95B"

    /// What the helper demands of whoever connects: the genuine, Apple-notarized,
    /// same-team Purge app. Applied with `NSXPCConnection.setCodeSigningRequirement`.
    static let clientRequirement =
        "identifier \"io.getpurge.app\" and anchor apple generic and " +
        "certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// What the app demands of the helper it dials, so a planted binary answering on
    /// the same Mach service cannot pose as the helper.
    static let helperRequirement =
        "identifier \"\(machServiceName)\" and anchor apple generic and " +
        "certificate leaf[subject.OU] = \"\(teamIdentifier)\""
}

/// The privileged operations the helper exposes over XPC. Deliberately tiny: the
/// helper runs as root, so every method here is attack surface. It does exactly one
/// thing — move already-chosen paths into a Trash directory and hand ownership back
/// to the user — and nothing that could be turned into an arbitrary-write primitive.
@objc(PurgeHelperProtocol) protocol PurgeHelperProtocol {
    /// Moves each path in `paths` into `trashDirectoryPath` as root, then `chown`s the
    /// moved item back to (`uid`, `gid`) so the user can empty the Trash unaided.
    /// Replies with the subset of `paths` that are now gone from their source.
    func moveToTrash(
        paths: [String],
        trashDirectoryPath: String,
        uid: Int,
        gid: Int,
        withReply reply: @escaping (_ movedPaths: [String]) -> Void
    )

    /// Round-trips the helper's build version so the app can tell whether an older
    /// helper is still installed after an update and re-register if so.
    func helperVersion(withReply reply: @escaping (_ version: String) -> Void)
}

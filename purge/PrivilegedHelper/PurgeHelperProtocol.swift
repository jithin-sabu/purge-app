import Foundation

/// The single source of truth for the identifiers and code-signing requirements the
/// app and the privileged helper use to find and vouch for each other. Both targets
/// compile this file, so the two ends can never drift apart on a name or a
/// requirement string — a drift that would surface only as a silent XPC failure.
enum PurgeHelperConstants {
    /// launchd label, Mach service name, and helper bundle identifier — all one string.
    static let machServiceName = "io.getpurge.helper"

    /// The helper's build version, shared so the app and the daemon agree on it.
    /// Bump it whenever the helper's behaviour changes: the app compares this against
    /// the version a running helper reports and re-registers when an older copy
    /// survived an update.
    static let version = "2"

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

    /// Directories whose immediate children the uninstaller may offer as leftovers.
    /// Keep this in the shared file so the root helper enforces the same boundary as
    /// the scanner instead of trusting paths supplied over XPC.
    private static let userLeftoverRelativeRoots = [
        "Library/Application Support",
        "Library/Caches",
        "Library/HTTPStorages",
        "Library/Preferences",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Saved Application State",
        "Library/Logs",
        "Library/LaunchAgents"
    ]

    private static let systemLeftoverRoots = [
        "/Library/LaunchDaemons",
        "/Library/Application Support",
        "/Library/LaunchAgents"
    ]

    /// Returns true only for locations the app-uninstall scanner can produce:
    /// an app bundle in an Applications folder, or one direct child of a known
    /// leftover directory. Symlinks are rejected so an allowed-looking path cannot
    /// redirect the root helper somewhere else between path components.
    static func isAllowedUninstallLocation(_ url: URL, homeDirectory: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard standardized.path == resolved.path else { return false }

        let home = homeDirectory.standardizedFileURL
        let userRoots = userLeftoverRelativeRoots.map {
            home.appendingPathComponent($0, isDirectory: true).standardizedFileURL
        }
        let machineRoots = systemLeftoverRoots.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        let parent = standardized.deletingLastPathComponent().path
        if (userRoots + machineRoots).contains(where: { $0.path == parent }) {
            return true
        }

        let appRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
        guard standardized.pathExtension.lowercased() == "app" else { return false }
        let appParent = standardized.deletingLastPathComponent()
        if appRoots.contains(where: { appParent.path == $0.path }) { return true }

        let grandparent = appParent.deletingLastPathComponent()
        return appRoots.contains { grandparent.path == $0.path }
    }
}

/// The privileged operations the helper exposes over XPC. Deliberately tiny: the
/// helper runs as root, so every method here is attack surface. It does exactly one
/// thing — move already-chosen paths into a Trash directory and hand ownership back
/// to the user — and nothing that could be turned into an arbitrary-write primitive.
@objc(PurgeHelperProtocol) protocol PurgeHelperProtocol {
    /// Moves each path in `paths` into the connecting user's Trash as root, then hands
    /// ownership back to that same user so they can empty the Trash unaided.
    /// Replies with the subset of `paths` that are now gone from their source.
    func moveToTrash(
        paths: [String],
        withReply reply: @escaping (_ movedPaths: [String]) -> Void
    )

    /// Round-trips the helper's build version so the app can tell whether an older
    /// helper is still installed after an update and re-register if so.
    func helperVersion(withReply reply: @escaping (_ version: String) -> Void)
}

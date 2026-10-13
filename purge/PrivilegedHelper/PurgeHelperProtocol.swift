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
    ///
    /// v3 adds the administrator-only caller gate and the ownership-reporting move, so
    /// an app that talks the v3 protocol re-registers any surviving v2 helper first.
    /// v4 opens the Trash search-only, so privacy protection no longer blocks it, and
    /// quits when idle, so an update never leaves an old copy running.
    /// v5 accepts app bundles at any depth inside an Applications folder, never
    /// through a package, symlink, or hidden folder (#143).
    /// v6 also accepts the entries a finished macOS update left in `macOS Install
    /// Data`, and only while they are older than the installed system (#127).
    static let version = "6"

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
    /// an app bundle in an Applications folder (at any depth, never through
    /// another bundle or package), or one direct child of a known leftover
    /// directory. Symlinks are rejected so an allowed-looking path cannot
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
        // The same reach the uninstaller's picker walks; the helper target
        // compiles `AppBundleReach` too.
        return AppBundleReach.folderDepth(
            ofAppAtPath: standardized.path,
            roots: appRoots.map { $0.standardizedFileURL.path }
        ) != nil
    }

    /// One entry directly inside `macOS Install Data`, never `Locked Files`, and
    /// never reached through a symlink. Where the path is, not whether the folder
    /// is a leftover: that date rule is `installLeftoverRuleHolds` below.
    static func isAllowedInstallLeftoverLocation(
        _ url: URL,
        root: URL = MacOSInstallLeftovers.root
    ) -> Bool {
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard standardized.path == resolved.path else { return false }
        return MacOSInstallLeftovers.isEntryPath(standardized.path, root: root)
    }

    /// Everything the helper will move: an uninstall location, or a macOS install
    /// leftover while `installLeftoverRuleHolds`. The helper works that rule out
    /// itself, once per request and before it moves anything, because each move
    /// changes the folder's date. It never takes the app's word for it.
    static func isAllowedMoveSource(
        _ url: URL,
        homeDirectory: URL,
        installLeftoverRuleHolds: Bool
    ) -> Bool {
        if isAllowedUninstallLocation(url, homeDirectory: homeDirectory) { return true }
        return installLeftoverRuleHolds && isAllowedInstallLeftoverLocation(url)
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
    ///
    /// Kept for wire compatibility with a v2 app talking to a v3 helper. New callers
    /// use `moveToTrashReportingOwnership`, which also names the items whose ownership
    /// could not be fully handed back.
    func moveToTrash(
        paths: [String],
        withReply reply: @escaping (_ movedPaths: [String]) -> Void
    )

    /// Same move as `moveToTrash`, but the reply also names the subset of moved items
    /// whose ownership could not be fully handed back to the user. Those items really
    /// did move to the Trash, but emptying them may prompt for a password, so the app
    /// can say so honestly instead of reporting a clean success.
    func moveToTrashReportingOwnership(
        paths: [String],
        withReply reply: @escaping (_ movedPaths: [String], _ ownershipIncompletePaths: [String]) -> Void
    )

    /// Round-trips the helper's build version so the app can tell whether an older
    /// helper is still installed after an update and re-register if so.
    func helperVersion(withReply reply: @escaping (_ version: String) -> Void)
}

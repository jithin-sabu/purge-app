import Foundation

/// Bounds and safety rules for the app uninstaller (issue #45). Kept separate
/// from `DeletionSafetyPolicy` and `LargeFileScanPolicy`, the same way those two
/// are separate from each other: uninstall targets are an app's own bundle and
/// support files, which is a different set of paths with a different owner from
/// either shared caches or personal media.
enum AppUninstallScanPolicy {

    // MARK: App roots

    /// Folders the picker enumerates. `/System/Applications` and
    /// `/System/Library` are deliberately absent, so Apple's built-in apps are
    /// never listed, never matched, and never deletable.
    nonisolated static func installedAppRoots() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    /// True for a bundle that must never be offered for uninstall: anything under
    /// `/System`, and Purge itself (removing the tool mid-uninstall).
    nonisolated static func isProtectedApp(bundleURL: URL, bundleID: String?) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        if path.hasPrefix("/System/") { return true }
        if let bundleID, protectedBundleIDs.contains(bundleID) { return true }
        return false
    }

    /// Purge's own identifiers, hard-excluded so the app can never queue itself
    /// for deletion. The fallback matches `FirstRunGate`'s default domain.
    nonisolated static let protectedBundleIDs: Set<String> = {
        var ids: Set<String> = ["io.getpurge.app"]
        if let main = Bundle.main.bundleIdentifier { ids.insert(main) }
        return ids
    }()

    // MARK: Leftover roots

    /// A location the leftover scan looks in, tagged with the category its direct
    /// children belong to.
    nonisolated struct LeftoverRoot {
        let url: URL
        let category: UninstallCategory
    }

    /// The support locations from the issue. User-domain roots first, then the
    /// two shared `/Library` roots that hold launch daemons and shared support.
    nonisolated static func leftoverSearchRoots(home: URL) -> [LeftoverRoot] {
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        return [
            LeftoverRoot(url: lib.appendingPathComponent("Application Support", isDirectory: true),
                         category: .applicationSupport),
            LeftoverRoot(url: lib.appendingPathComponent("Caches", isDirectory: true),
                         category: .caches),
            LeftoverRoot(url: lib.appendingPathComponent("HTTPStorages", isDirectory: true),
                         category: .caches),
            LeftoverRoot(url: lib.appendingPathComponent("Preferences", isDirectory: true),
                         category: .preferences),
            LeftoverRoot(url: lib.appendingPathComponent("Containers", isDirectory: true),
                         category: .containers),
            LeftoverRoot(url: lib.appendingPathComponent("Group Containers", isDirectory: true),
                         category: .groupContainers),
            LeftoverRoot(url: lib.appendingPathComponent("Saved Application State", isDirectory: true),
                         category: .savedState),
            LeftoverRoot(url: lib.appendingPathComponent("Logs", isDirectory: true),
                         category: .logs),
            LeftoverRoot(url: lib.appendingPathComponent("LaunchAgents", isDirectory: true),
                         category: .launchAgents),
            LeftoverRoot(url: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
                         category: .launchDaemons),
            LeftoverRoot(url: URL(fileURLWithPath: "/Library/Application Support", isDirectory: true),
                         category: .applicationSupport),
            LeftoverRoot(url: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
                         category: .launchAgents)
        ]
    }

    // MARK: Delete-boundary gate

    /// The gate `FileDeleter` calls before trashing an uninstall target. This is a
    /// safety net, not the matcher: the scanner decides which paths belong to the
    /// chosen app, and this refuses anything that is not either a top-level entry
    /// inside a known leftover root or an `.app` bundle inside an app root. A bug
    /// in matching can therefore never trash a path outside those bounds.
    nonisolated static func isEligibleForUninstallDeletion(_ url: URL) -> Bool {
        let std = url.standardizedFileURL
        let path = std.path

        // Never through this gate: system locations.
        if path.hasPrefix("/System/") { return false }

        // An app bundle sitting inside an app root, or one folder deeper (vendors
        // that group their apps, e.g. `/Applications/Utilities/…`). This mirrors
        // the one-level nesting `AppUninstallScanner.discoverAppBundleURLs` walks,
        // so every bundle the picker offers can actually be trashed. Deeper paths
        // stay out, so the gate never descends into bundle internals.
        if std.pathExtension == "app" {
            let appRoots = installedAppRoots().map { $0.standardizedFileURL.path }
            let parent = std.deletingLastPathComponent()
            if appRoots.contains(parent.path) { return true }
            let grandparent = parent.deletingLastPathComponent().path
            if appRoots.contains(grandparent) { return true }
            return false
        }

        // A leftover: must live strictly inside one of the leftover roots, and
        // must not be one of the roots themselves.
        let home = FileManager.default.homeDirectoryForCurrentUser
        for root in leftoverSearchRoots(home: home) {
            let rootPath = root.url.standardizedFileURL.path
            if path == rootPath { return false }
            if path.hasPrefix(rootPath + "/") { return true }
        }
        return false
    }

    // MARK: Matching

    /// The set of file-name tokens, for a folder or file directly inside a
    /// leftover root, that count as belonging to `app`, paired with why. Returns
    /// `nil` when the name does not match the app at all.
    ///
    /// Matching is intentionally strict. Bundle-id anchoring (`com.vendor.App`,
    /// `com.vendor.App.plist`, `com.vendor.App.savedState`) is exact. Name
    /// anchoring requires the whole leftover name to equal the app's display name;
    /// loose substring matching is never used, so uninstalling one Google app does
    /// not sweep in `Application Support/Google`.
    nonisolated static func matchReason(
        forLeftoverName name: String,
        category: UninstallCategory,
        app: InstalledApp
    ) -> MatchReason? {
        let lowerName = name.lowercased()

        if let bundleID = app.bundleID?.lowercased(), !bundleID.isEmpty {
            // Exact bundle id, or bundle id plus a known suffix.
            if lowerName == bundleID { return .bundleID }
            if lowerName == bundleID + ".plist" { return .bundleID }
            if lowerName == bundleID + ".savedstate" { return .bundleID }
            if lowerName == bundleID + ".binarycookies" { return .bundleID }
            // Launch agents/daemons are commonly `com.vendor.App.helper.plist`.
            if category == .launchAgents || category == .launchDaemons {
                if lowerName.hasPrefix(bundleID + ".") && lowerName.hasSuffix(".plist") {
                    return .bundleID
                }
            }
            // Group containers are `<teamID>.<bundle id>` or `group.<bundle id>`.
            // Require the app's complete bundle identifier as a dot-suffix. A
            // stem-only match risked two unrelated vendors sharing a final
            // component (both `…​.rectangle`) claiming each other's container,
            // which would be preselected because group matches are high-confidence.
            if category == .groupContainers {
                if lowerName.hasSuffix("." + bundleID) { return .groupID }
            }
        }

        // Name-only: the whole leftover name equals the display name. Applies to
        // human-named support and log folders, not to the config locations that
        // are always bundle-id keyed.
        if category == .applicationSupport || category == .logs || category == .other {
            if lowerName == app.matchName.lowercased() { return .appName }
        }

        return nil
    }

    // MARK: Shared-leftover detection

    /// The first app in `others` (never the one whose id is `ownerID`) that also
    /// claims this leftover, using the same strict identifier/name rules as
    /// `matchReason`. A non-nil result means the leftover is shared with an app the
    /// user is keeping, so removing its owner must not trash it: the two-copies
    /// case, or one app of a suite that shares support with its siblings.
    nonisolated static func claimant(
        forLeftoverName name: String,
        category: UninstallCategory,
        ownerID: String,
        among others: [InstalledApp]
    ) -> InstalledApp? {
        others.first { candidate in
            candidate.id != ownerID
                && matchReason(forLeftoverName: name, category: category, app: candidate) != nil
        }
    }

    // MARK: Safety mapping

    /// Bundle-id and group anchored matches are safe to remove and preselected;
    /// name matches are "Check First" and left unchecked. The `.app` bundle is
    /// safe unless it needs admin rights to trash, where the medium tier flags
    /// that Trash may ask for a password.
    nonisolated static func safetyInfo(
        for reason: MatchReason,
        category: UninstallCategory,
        url: URL,
        appName: String
    ) -> SafetyInfo {
        switch reason {
        case .appBundle:
            if DeletionSafetyPolicy.requiresAdminPrivileges(for: url) {
                return SafetyInfo(
                    level: .medium,
                    headline: "\(appName)",
                    explanation: "Removing this app needs administrator rights. macOS will ask for your password when it moves the app to the Trash.",
                    recoverySteps: "Reinstall \(appName) from its original source if you need it again.",
                    reinstallCommand: nil
                )
            }
            return SafetyInfo(
                level: .safe,
                headline: "\(appName)",
                explanation: "The application bundle. Moving it to the Trash removes the app itself.",
                recoverySteps: "Reinstall \(appName) from its original source if you need it again.",
                reinstallCommand: nil
            )
        case .bundleID, .groupID:
            return SafetyInfo(
                level: .safe,
                headline: "\(appName) \(category.displayName)",
                explanation: "A \(category.displayName.lowercased()) file that belongs to \(appName), matched by its identifier. Safe to remove with the app.",
                recoverySteps: "\(appName) recreates what it needs the next time it runs.",
                reinstallCommand: nil
            )
        case .appName:
            return SafetyInfo(
                level: .medium,
                headline: "\(appName) \(category.displayName)",
                explanation: "This \(category.displayName.lowercased()) folder is named after \(appName), but was matched by name rather than identifier. Check it belongs to this app before removing.",
                recoverySteps: "\(appName) recreates what it needs the next time it runs.",
                reinstallCommand: nil
            )
        }
    }
}

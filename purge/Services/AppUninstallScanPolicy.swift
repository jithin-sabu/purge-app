import Foundation

/// Bounds and safety rules for the app uninstaller (issue #45). Kept separate
/// from `DeletionSafetyPolicy` and `LargeFileScanPolicy`, the same way those two
/// are separate from each other: uninstall targets are an app's own bundle and
/// support files, which is a different set of paths with a different owner from
/// either shared caches or personal media.
enum AppUninstallScanPolicy {

    // MARK: App roots

    /// Folders the picker enumerates (`AppFolders`): the two Applications
    /// folders, each attached drive's, and the ones the user added (#99).
    /// `/System/Applications` and `/System/Library` are deliberately absent, so
    /// Apple's built-in apps are never listed, never matched, and never deletable.
    nonisolated static func installedAppRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        AppFolders.roots(home: home)
    }

    /// True for a bundle that must never be offered for uninstall: anything under
    /// `/System`, and Purge itself (removing the tool mid-uninstall).
    ///
    /// `/Applications/Safari.app` is a symlink into
    /// `/System/Cryptexes/App/System/Applications/Safari.app` (#176), so the
    /// `/System` check reads where the bundle really lives as well as its path.
    nonisolated static func isProtectedApp(bundleURL: URL, bundleID: String?) -> Bool {
        let std = bundleURL.standardizedFileURL
        if std.path.hasPrefix("/System/") { return true }
        if std.resolvingSymlinksInPath().path.hasPrefix("/System/") { return true }
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

    /// The category of the leftover root `url` sits inside, or `nil` when it is
    /// not inside one. A retry uses it to run the ownership check again (#174).
    nonisolated static func leftoverCategory(
        for url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> UninstallCategory? {
        let path = url.standardizedFileURL.path
        return leftoverSearchRoots(home: home)
            .first { PathContainment.isInside(path, $0.url.standardizedFileURL.path) }?
            .category
    }

    /// The support locations from the issue. User-domain roots first, then the
    /// shared `/Library` roots: launch items and shared support, and the three
    /// folders macOS also keeps its own files in (#352), where the gate accepts
    /// less (`PurgeHelperConstants.isAllowedSharedSystemLeftoverEntry`).
    ///
    /// `/private/var/db/receipts` is deliberately absent (#352). A receipt is
    /// named by the installer package's id, which is rarely the app's bundle id,
    /// and its `.bom` is the only record of what that package put outside the
    /// app bundle. `pkgutil --forget` is the tool for it.
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
            LeftoverRoot(url: lib.appendingPathComponent("Application Scripts", isDirectory: true),
                         category: .applicationScripts),
            LeftoverRoot(url: lib.appendingPathComponent("Cookies", isDirectory: true),
                         category: .webData),
            LeftoverRoot(url: lib.appendingPathComponent("WebKit", isDirectory: true),
                         category: .webData),
            LeftoverRoot(url: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
                         category: .launchDaemons),
            LeftoverRoot(url: URL(fileURLWithPath: "/Library/Application Support", isDirectory: true),
                         category: .applicationSupport),
            LeftoverRoot(url: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
                         category: .launchAgents),
            LeftoverRoot(url: URL(fileURLWithPath: "/Library/Caches", isDirectory: true),
                         category: .caches),
            LeftoverRoot(url: URL(fileURLWithPath: "/Library/Preferences", isDirectory: true),
                         category: .preferences),
            LeftoverRoot(url: URL(fileURLWithPath: "/Library/Logs", isDirectory: true),
                         category: .logs)
        ]
    }

    // MARK: Delete-boundary gate

    /// The gate `FileDeleter` calls before trashing an uninstall target. This is a
    /// safety net, not the matcher: the scanner decides which paths belong to the
    /// chosen app, and this refuses anything that is not a top-level entry inside
    /// a known leftover root, an `.app` bundle inside an app root, or a hidden
    /// home folder the dot-folder catalog names in full (#224). In the `/Library`
    /// folders macOS shares with other apps it takes only a name shaped like a
    /// bundle identifier, and refuses Apple's own and hidden entries (#352). A
    /// bug in matching
    /// can therefore never trash a path outside those bounds.
    ///
    /// `home` is the real home folder everywhere but the tests, which hand in a
    /// temporary one so they never write to the user's Library (#171).
    nonisolated static func isEligibleForUninstallDeletion(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        dotFolderCatalog: AppDotFolderCatalog = .shared
    ) -> Bool {
        let std = url.standardizedFileURL
        let path = std.path

        // Never through this gate: system locations.
        if path.hasPrefix("/System/") { return false }

        // A leftover: must live strictly inside one of the leftover roots, and
        // must not be one of the roots themselves. A bundle id can end in `.app`
        // (`Application Support/com.granola.app`), and such leftovers were once
        // refused as bundles outside the app roots. So a `.app` name is a
        // leftover only directly inside a root, and only when it is not a real
        // application bundle; a bundle anywhere under these roots is never one.
        // The extension is read without case, as the root helper reads it, so
        // a bundle named `Foo.APP` is refused here too (#362).
        // In a folder macOS shares with other apps (`/Library/Preferences`),
        // only a direct child whose name the shared rule accepts (#352).
        for root in leftoverSearchRoots(home: home) {
            let rootPath = root.url.standardizedFileURL.path
            if path == rootPath { return false }
            guard PathContainment.isInside(path, rootPath) else { continue }
            if PurgeHelperConstants.sharedSystemLeftoverRoots.contains(rootPath) {
                guard std.deletingLastPathComponent().standardizedFileURL.path == rootPath,
                      PurgeHelperConstants.isAllowedSharedSystemLeftoverEntry(std, inRootAt: rootPath)
                else { return false }
            }
            if std.pathExtension.lowercased() == "app" {
                guard std.deletingLastPathComponent().standardizedFileURL.path == rootPath,
                      !isRealAppBundle(std) else { return false }
            }
            return true
        }

        // An app bundle inside an app root, at any depth the picker walks
        // (`AppBundleReach`), so every bundle it offers can actually be trashed.
        // A path through another bundle or package, a symlink, or a hidden
        // folder stays out, so the gate never reaches bundle internals.
        // Never one that links into `/System`, like `/Applications/Safari.app`,
        // and never Purge itself, read by its bundle id as the list reads it (#176).
        // A drive's folder or one the user added is read again here, so a drive
        // swapped or a folder replaced since the scan answers as it is now (#99).
        // A bundle there must also be on a disk attached to this Mac that can be
        // written to: a folder inside a root can be where a network share or a
        // disk image is mounted.
        if std.pathExtension == "app" {
            let bundleID = AppBundleReach.readInfoPlist(at: std)["CFBundleIdentifier"] as? String
            guard !isProtectedApp(bundleURL: std, bundleID: bundleID) else { return false }
            let builtIn = AppFolders.builtInRoots(home: home).map { $0.standardizedFileURL.path }
            if AppBundleReach.folderDepth(ofAppAtPath: path, roots: builtIn) != nil { return true }
            let appRoots = installedAppRoots(home: home).map { $0.standardizedFileURL.path }
            guard AppFolders.folderDepth(ofAppAtPath: path, roots: appRoots, home: home) != nil else { return false }
            return AppFolders.isOnLocalDisk(std) && !AppFolders.isReadOnly(std)
        }

        // A hidden home folder, only when the catalog names exactly this path and
        // no link leads there. Nothing inside one, never a parent such as
        // `~/.gemini`, and never a `~/.gemini` that links into Dropbox or a
        // dotfiles repository, where the Trash move would take the synced copy.
        guard dotFolderCatalog.entry(forFolderAt: std, home: home) != nil else { return false }
        return staysInsideHomeWithoutLinks(std, home: home)
    }

    /// A real application bundle, as opposed to a folder whose name ends in
    /// `.app` because its bundle id does (`com.granola.app`).
    nonisolated static func isRealAppBundle(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
    }

    /// Whether `url` sits inside `home` with no symbolic link on the way down:
    /// the lexical path and the resolved path agree once both are resolved from
    /// the home. A home that is itself a link, or spelled `/var` for
    /// `/private/var`, still passes; a linked component under it does not.
    nonisolated static func staysInsideHomeWithoutLinks(_ url: URL, home: URL) -> Bool {
        let std = url.standardizedFileURL
        let homePath = home.standardizedFileURL.path
        guard PathContainment.isInside(std.path, homePath) else { return false }
        let relative = String(std.path.dropFirst(homePath.count))
        let resolvedHome = home.standardizedFileURL.resolvingSymlinksInPath().path
        return std.resolvingSymlinksInPath().path == resolvedHome + relative
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
    ///
    /// A hidden entry (`.com.vendor.App`, #352) is matched by its name without
    /// the leading dot, and only by the bundle id or the id plus a known suffix:
    /// never by display name, group, or a launch item's prefix.
    nonisolated static func matchReason(
        forLeftoverName name: String,
        category: UninstallCategory,
        app: InstalledApp,
        dotFolderCatalog: AppDotFolderCatalog = .shared
    ) -> MatchReason? {
        let lowerName = name.lowercased()

        // A hidden home folder is paired with a bundle id by the catalog and by
        // nothing else (#228). The scanner lists them from the catalog directly;
        // this branch is for `claimant`, so a second installed copy of the same
        // app keeps the folder. The name is the folder's last component.
        if category == .homeFolderData {
            guard let bundleID = app.bundleID?.lowercased(), !bundleID.isEmpty else { return nil }
            let listed = dotFolderCatalog.entries.contains { entry in
                entry.bundleID.lowercased() == bundleID
                    && entry.folders.contains { ($0 as NSString).lastPathComponent == name }
            }
            return listed ? .dotFolderCatalog : nil
        }

        let isHidden = lowerName.hasPrefix(".")
        if let bundleID = app.bundleID?.lowercased(), !bundleID.isEmpty {
            // Cookies and WebKit also hold the system's own files under plain
            // names (`Cookies.binarycookies`, `HSTS.plist`, `Databases`). An
            // app whose bundle id is one word (`Cookies`) would be paired with
            // them, so there the id must be shaped like an identifier (#362).
            if category == .webData, !isShapedLikeIdentifier(bundleID) { return nil }
            if isHidden {
                return isNamedByIdentifier(String(lowerName.dropFirst()), bundleID: bundleID) ? .bundleID : nil
            }
            // Exact bundle id, or bundle id plus a known suffix.
            if isNamedByIdentifier(lowerName, bundleID: bundleID) { return .bundleID }
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
            // Application Scripts has a folder for each group too, named the
            // same way.
            if entriesCanBeAppGroups(category) {
                if lowerName.hasSuffix("." + bundleID) { return .groupID }
            }
        }
        if isHidden { return nil }

        // Name-only: the whole leftover name equals the display name. Applies to
        // human-named support and log folders, not to the config locations that
        // are always bundle-id keyed.
        if category == .applicationSupport || category == .logs || category == .other {
            if lowerName == app.matchName.lowercased() { return .appName }
        }

        return nil
    }

    /// Whether a match of this strength is offered in `root` (#352). In the
    /// `/Library` folders macOS shares with other apps only an identifier
    /// counts: a name-only match there could pair an app called `Bluetooth`
    /// with the system's `/Library/Logs/Bluetooth`, and the root helper would
    /// move it.
    nonisolated static func offers(_ reason: MatchReason, in root: LeftoverRoot) -> Bool {
        guard reason == .appName else { return true }
        return !PurgeHelperConstants.sharedSystemLeftoverRoots.contains(root.url.standardizedFileURL.path)
    }

    /// Whether `lowerName` is `bundleID` itself or the id plus a known suffix.
    /// Both are lowercased.
    private nonisolated static func isNamedByIdentifier(_ lowerName: String, bundleID: String) -> Bool {
        lowerName == bundleID
            || lowerName == bundleID + ".plist"
            || lowerName == bundleID + ".savedstate"
            || lowerName == bundleID + ".binarycookies"
    }

    /// Whether `identifier` has at least two parts around a dot, none of them
    /// empty, and no space: the shape of `com.vendor.App`, and the same shape
    /// `PurgeHelperConstants.isAllowedSharedSystemLeftover` asks of a name.
    private nonisolated static func isShapedLikeIdentifier(_ identifier: String) -> Bool {
        guard !identifier.contains(" ") else { return false }
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && !parts.contains { $0.isEmpty }
    }

    /// The categories whose entries can be named after an app group: Group
    /// Containers, and Application Scripts, where macOS makes a folder for each
    /// group beside the one for each app (#352).
    nonisolated static func entriesCanBeAppGroups(_ category: UninstallCategory) -> Bool {
        switch category {
        case .groupContainers, .applicationScripts:
            return true
        case .bundle, .applicationSupport, .caches, .preferences, .containers, .webData, .savedState,
             .logs, .launchAgents, .launchDaemons, .homeFolderData, .other:
            return false
        }
    }

    /// Whether `item` is named after an app group, so an app the user is keeping
    /// could list it in its entitlements. Every Group Containers entry is. In
    /// Application Scripts only an entry matched as a group is: the rest are
    /// named after the app's own bundle id, which no other app can list.
    nonisolated static func isNamedAfterAppGroup(_ item: UninstallItem) -> Bool {
        switch item.category {
        case .groupContainers:
            return true
        case .applicationScripts:
            return item.matchReason == .groupID
        case .bundle, .applicationSupport, .caches, .preferences, .containers, .webData, .savedState,
             .logs, .launchAgents, .launchDaemons, .homeFolderData, .other:
            return false
        }
    }

    // MARK: Shared-leftover detection

    /// The first app in `others` (never the one whose id is `ownerID`) that also
    /// claims this leftover, using the same strict identifier/name rules as
    /// `matchReason`. A non-nil result means the leftover is shared with an app the
    /// user is keeping, so removing its owner must not trash it: the two-copies
    /// case, or one app of a suite that shares support with its siblings.
    ///
    /// A group container, or a group's Application Scripts folder, is also claimed
    /// by an app that lists that exact group in its entitlements
    /// (`appGroupClaims`, #200). The developer names the group,
    /// so `<team>.<id of the app being removed>` can be a group a kept app shares
    /// while nothing in the kept app's own id matches it.
    nonisolated static func claimant(
        forLeftoverName name: String,
        category: UninstallCategory,
        ownerID: String,
        among others: [InstalledApp],
        appGroupClaims: AppGroupClaims
    ) -> InstalledApp? {
        others.first { candidate in
            guard candidate.id != ownerID else { return false }
            if matchReason(forLeftoverName: name, category: category, app: candidate) != nil { return true }
            return entriesCanBeAppGroups(category) && appGroupClaims.app(candidate, claims: name)
        }
    }

    // MARK: Safety mapping

    /// Whether an Application Scripts folder holds anything besides Finder's
    /// `.DS_Store` (#352). macOS makes the folder empty. Whatever is in it was
    /// put there for the app to run, often written by the user, so the row is
    /// Check First and starts unticked. A folder that cannot be listed counts
    /// as holding something.
    nonisolated static func scriptsFolderHoldsFiles(_ url: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return true }
        return names.contains { $0 != ".DS_Store" }
    }

    /// Whether a scripts folder the user approved as empty holds files now
    /// (#352). The scan read it once, and a script can land in it while the
    /// review sheet is open or while a locked app waits for a retry. Read again
    /// right before the move, such a folder stays. One the user ticked knowing
    /// it held scripts moves, and one that is gone is not this check's concern.
    nonisolated static func scriptsFolderGainedFiles(_ item: UninstallItem) -> Bool {
        guard item.category == .applicationScripts, !item.holdsAddedScripts,
              FileManager.default.fileExists(atPath: item.path.path) else { return false }
        return scriptsFolderHoldsFiles(item.path)
    }

    /// The same check for a failure row, which has a path and no item (#362).
    /// Retry can come minutes after the clean, so it reads the folder again.
    /// `approvedWithFiles` is the row's `holdsAddedScripts`: false for a folder
    /// the user approved as empty, and for a row that does not say.
    nonisolated static func scriptsFolderGainedFiles(
        at url: URL,
        approvedWithFiles: Bool,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard !approvedWithFiles,
              leftoverCategory(for: url, home: home) == .applicationScripts,
              FileManager.default.fileExists(atPath: url.path) else { return false }
        return scriptsFolderHoldsFiles(url)
    }

    // MARK: Helper eligibility

    /// Whether moving `url` out of its folder takes more than `user`'s own
    /// rights, so the leftover may go to the root helper when the plain move
    /// fails. A move needs write access to the folder holding the entry. The
    /// entry's own owner and mode do not matter for a rename, so checking the
    /// entry would send files in a user-writable folder to the helper for
    /// nothing.
    ///
    /// A sticky folder is the exception (#362). `/Library/Caches` is
    /// `drwxrwxrwt root:admin`: an administrator can write to it, and still
    /// can't move an entry there unless they own the entry or the folder. A
    /// root-owned cache folder a removed app left there read as "no privilege
    /// needed", and its row kept a Retry that could never work.
    ///
    /// This only names what may be handed to the helper. The helper's own gate
    /// (`PurgeHelperConstants.isAllowedUninstallLocation`) still decides what
    /// it moves.
    nonisolated static func moveNeedsPrivilege(_ url: URL, user: uid_t = getuid()) -> Bool {
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { return true }
        guard user != 0 else { return false }
        var parentInfo = stat()
        guard stat(parent.path, &parentInfo) == 0, parentInfo.st_mode & S_ISVTX != 0 else { return false }
        var entryInfo = stat()
        guard lstat(url.path, &entryInfo) == 0 else { return false }
        return parentInfo.st_uid != user && entryInfo.st_uid != user
    }

    /// Bundle-id and group anchored matches are safe to remove and preselected;
    /// name matches are "Check First" and left unchecked. The `.app` bundle is
    /// safe unless it needs admin rights to trash, where the medium tier flags
    /// that Trash may ask for a password. An Application Scripts folder with
    /// files in it (`holdsAddedScripts`) is Check First whatever matched it.
    nonisolated static func safetyInfo(
        for reason: MatchReason,
        category: UninstallCategory,
        url: URL,
        appName: String,
        holdsAddedScripts: Bool = false
    ) -> SafetyInfo {
        if holdsAddedScripts {
            return SafetyInfo(
                level: .medium,
                headline: String(localized: "\(appName) \(category.displayName)"),
                explanation: String(localized: "This folder holds scripts added for \(appName), which may be ones you wrote. Check it before removing."),
                recoverySteps: String(localized: "Removed items go to the Trash, so you can put them back until you empty it."),
                reinstallCommand: nil
            )
        }
        switch reason {
        case .appBundle:
            if DeletionSafetyPolicy.requiresAdminPrivileges(for: url) {
                return SafetyInfo(
                    level: .medium,
                    headline: String(localized: "\(appName)"),
                    explanation: String(localized: "Removing this app needs administrator rights. macOS will ask for your password when it moves the app to the Trash."),
                    recoverySteps: String(localized: "Reinstall \(appName) from its original source if you need it again."),
                    reinstallCommand: nil
                )
            }
            return SafetyInfo(
                level: .safe,
                headline: String(localized: "\(appName)"),
                explanation: String(localized: "The application bundle. Moving it to the Trash removes the app itself."),
                recoverySteps: String(localized: "Reinstall \(appName) from its original source if you need it again."),
                reinstallCommand: nil
            )
        case .bundleID, .groupID:
            return SafetyInfo(
                level: .safe,
                headline: String(localized: "\(appName) \(category.displayName)"),
                explanation: String(localized: "A \(category.displayName.lowercased()) file that belongs to \(appName), matched by its identifier. Safe to remove with the app."),
                recoverySteps: String(localized: "\(appName) recreates what it needs the next time it runs."),
                reinstallCommand: nil
            )
        // A hidden home folder the catalog names for the app being uninstalled
        // (#228). Settings, extensions and history live there, so it is Check
        // First and starts unticked.
        case .dotFolderCatalog:
            return SafetyInfo(
                level: .medium,
                headline: String(localized: "\(appName) \(category.displayName)"),
                explanation: String(localized: "A hidden folder in your home folder that \(appName) is known to keep. It holds settings, extensions and history rather than a cache, so check it before removing."),
                recoverySteps: String(localized: "Removed items go to the Trash, so you can put them back until you empty it. If you reinstall the app, let it recreate its data."),
                reinstallCommand: nil
            )
        // The ledger and the Library cross-evidence only attribute leftovers of
        // removed apps, whose rows get their text from
        // `OrphanLeftoverScanPolicy.safetyInfo`; listed here so a name-strength
        // match is never read as safe.
        case .appName, .ownerLedger, .libraryCrossEvidence:
            return SafetyInfo(
                level: .medium,
                headline: String(localized: "\(appName) \(category.displayName)"),
                explanation: String(localized: "This \(category.displayName.lowercased()) folder is named after \(appName), but was matched by name rather than identifier. Check it belongs to this app before removing."),
                recoverySteps: String(localized: "\(appName) recreates what it needs the next time it runs."),
                reinstallCommand: nil
            )
        }
    }
}

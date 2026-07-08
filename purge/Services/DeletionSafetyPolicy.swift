import Foundation

/// Outcome of running a candidate path through the safety policy.
enum DeletionSafetyDecision: Equatable {
    /// Safe to remove.
    case allow
    /// On the never-delete list. Skip silently and drop from any selection.
    case blockedNeverDelete
    /// Not on the whitelist. Skip and surface "This file was skipped for safety".
    case blockedNotWhitelisted

    var skipReason: String? {
        switch self {
        case .allow: return nil
        case .blockedNeverDelete: return "Protected location — not eligible for deletion."
        case .blockedNotWhitelisted: return "This file was skipped for safety"
        }
    }

    var isUserVisibleSkip: Bool {
        self == .blockedNotWhitelisted
    }
}

/// Strict allow / deny policy gating every filesystem removal performed by Purge.
/// Both manual and scheduled cleanup must run paths through `evaluate(_:)` before
/// touching the disk. Any path not explicitly allowed is refused.
enum DeletionSafetyPolicy {
    /// System-level paths that require administrator privileges — not offered for cleanup.
    nonisolated static let systemCacheDeletionPrefixes: [String] = [
        "/Library/Caches",
        "/Library/Updates",
        "/private/var/log",
        "/var/log",
        "/private/var/db/DiagnosticPipeline",
        "/Library/Logs/DiagnosticReports"
    ]

    /// macOS-protected folders under ~/Library/Caches that cannot be removed even with Full Disk Access.
    nonisolated static let protectedSystemCacheFolderNames: Set<String> = [
        "CloudKit",
        "FamilyCircle"
    ]

    /// macOS-managed folders under ~/Library/Logs that the OS refuses to remove even with
    /// Full Disk Access. They surface inside the "Application Logs" scan but must never be offered.
    nonisolated static let protectedLogFolderNames: Set<String> = [
        "DiagnosticReportsForNewHardware"
    ]

    /// Sandboxed app containers whose cache directories are guarded by macOS.
    nonisolated static let protectedContainerBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.Home",
        "com.apple.homed",
        "com.apple.HomeKit"
    ]

    /// Folder names allowed to be removed when located anywhere inside the user's home.
    ///
    /// AUDIT: `build`, `dist`, `out`, and `target` are generic names that could,
    /// in principle, match a user-authored directory rather than a build
    /// artifact. This match only authorizes deletion; discovery is driven by
    /// `DevScanner`, which only surfaces these when they sit next to a known
    /// project manifest — so a lone user folder named "out" is never scanned.
    /// Kept as-is deliberately; flagged here so the breadth stays visible.
    nonisolated static let whitelistedFolderNames: Set<String> = [
        "node_modules",
        "venv",
        ".venv",
        "target",
        "Pods",
        ".gradle",
        "DerivedData",
        "build",
        "dist",
        "out",
        ".next",
        ".nuxt",
        ".cache",
        "__pycache__",
        ".turbo",
        ".parcel-cache",
        ".dart_tool"
    ]

    /// Sensitive locations whose path or any descendant must never be removed.
    nonisolated static func neverDeletePrefixes(home: String) -> [String] {
        [
            "\(home)/Library/Keychains",
            "\(home)/Library/Preferences",
            "\(home)/Library/Mail",
            "\(home)/System",
            "\(home)/Pictures",
            "\(home)/Music",
            "\(home)/Movies",
            "/Library",
            "/usr",
            "/bin",
            "/sbin",
            "/etc",
            "/var"
        ]
    }

    /// User content roots that themselves are off-limits, while whitelisted caches
    /// nested below them remain reachable through the whitelist.
    nonisolated static func neverDeleteExactPaths(home: String) -> [String] {
        [
            "\(home)/Library/Application Support",
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads"
        ]
    }

    /// Absolute paths (and their descendants) we are explicitly authorized to delete.
    ///
    /// Audit note: every entry below resolves to a regenerable cache, build
    /// artifact, or log directory — nothing here holds non-recoverable user
    /// data. A handful of entries are flagged `AUDIT` where the folder holds
    /// re-creatable but not-instantly-regenerated state; those are surfaced as
    /// "Check First" by their classifiers (never silently downgraded to Safe),
    /// and are called out here so the risk stays visible.
    nonisolated static func whitelistedAbsolutePrefixes(home: String) -> [String] {
        [
            "\(home)/Library/Caches",
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
            "\(home)/Library/Developer/Xcode/DocumentationCache",
            // AUDIT: Xcode Archives hold built .xcarchive bundles + dSYMs. Not
            // user data, but not auto-regenerated — treat as Check First, never Safe.
            "\(home)/Library/Developer/Xcode/Archives",
            "\(home)/.npm",
            "\(home)/.npm/_npx",
            "\(home)/.npm/_logs",
            "\(home)/.cache/node/corepack",
            "\(home)/.yarn/cache",
            "\(home)/.pnpm-store",
            "\(home)/.gradle/caches",
            // AUDIT: `.android` also holds AVD emulator images and the adb key.
            // Re-creatable (re-auth devices / re-create AVDs) but not a pure
            // cache — classify as Check First, not Safe.
            "\(home)/.android",
            "\(home)/.cocoapods",
            "\(home)/.sbt",
            "\(home)/.ivy2/cache",
            "\(home)/.cache/act",
            "\(home)/.zcompdump",
            "\(home)/.cargo/registry",
            "\(home)/.pub-cache",
            "\(home)/.flutter",
            // NOTE: `~/Library/Application Support/MobileSync/Backup` (iPhone/iPad
            // backups) is deliberately NOT on the allowlist. Those backups are
            // non-recoverable, so they must never be scanned, sized, or shown.
            "\(home)/Library/Logs",
            "\(home)/Library/Logs/DiagnosticReports",
            "\(home)/.m2/repository",
            "\(home)/.gem",
            "\(home)/.bundle/cache",
            "\(home)/.composer/cache",
            "\(home)/.cargo/git",
            "\(home)/.terraform.d/plugin-cache",
            "\(home)/.vagrant.d/tmp",
            "\(home)/.zsh_sessions",
            "\(home)/.zcompdump",
            "\(home)/.cache/go-build",
            "\(home)/go/pkg/mod/cache",
            "\(home)/Library/Application Support/Code/Cache",
            "\(home)/Library/Application Support/Code/CachedData",
            "\(home)/Library/Application Support/Code/CachedExtensionVSIXs",
            "\(home)/Library/Application Support/Code/User/workspaceStorage",
            "\(home)/Library/Application Support/Cursor/Cache",
            "\(home)/Library/Application Support/Cursor/CachedData",
            "\(home)/Library/Application Support/Cursor/User/workspaceStorage",
            "\(home)/Library/Caches/JetBrains",
            "\(home)/Library/Application Support/JetBrains",
            // AUDIT: `Zed/db` is Zed's local state database (not a pure cache).
            // Re-created on next launch but may reset local editor state —
            // Check First, not Safe.
            "\(home)/Library/Application Support/Zed/db",
            "\(home)/Library/Caches/Zed",
            "\(home)/Library/Caches/ms-playwright",
            "\(home)/.cache/ms-playwright",
            "\(home)/Library/Developer/CoreSimulator/Devices",
            "\(home)/Library/Application Support/Slack/Cache",
            "\(home)/Library/Application Support/Slack/Code Cache",
            "\(home)/Library/Application Support/discord/Cache",
            "\(home)/Library/Application Support/discord/Code Cache",
            "\(home)/Library/Application Support/Notion/Cache",
            "\(home)/Library/Application Support/Figma/Cache",
            // Adobe stores its heavy caches under Application Support rather than
            // ~/Library/Caches, so the broad Caches sweep never reaches them. These
            // are the default Common media cache locations only (never a project-local
            // or user-chosen scratch dir); Premiere/After Effects rebuild them on
            // next launch. Safe, not Check First.
            "\(home)/Library/Application Support/Adobe/Common/Media Cache Files",
            "\(home)/Library/Application Support/Adobe/Common/Media Cache",
            // AUDIT: Docker's container holds images/volumes. Re-pullable but
            // deleting can be costly — Check First, not Safe. (App Caches scan
            // already excludes com.docker.* bundle IDs; this entry is used by
            // the Dev Tools path.)
            "\(home)/Library/Containers/com.docker.docker",
            "\(home)/.vagrant.d/boxes",
            "/Applications/Install macOS"
        ]
    }

    /// Whether Purge may offer this path for manual or scheduled cleanup (no admin prompt).
    nonisolated static func isOfferedForCleanup(_ url: URL) -> Bool {
        if requiresAdminPrivileges(for: url) { return false }
        return evaluate(url) == .allow
    }

    nonisolated static func filterCacheItems(_ items: [CacheItem]) -> [CacheItem] {
        items.compactMap(filterCacheItem)
    }

    nonisolated static func filterCacheItem(_ item: CacheItem) -> CacheItem? {
        let locations = item.locations.filter { isOfferedForCleanup($0.path) }
        guard !locations.isEmpty else { return nil }
        guard locations.count != item.locations.count else { return item }
        return item.withLocations(locations)
    }

    nonisolated static func devToolFilteredToOfferedCleanup(_ tool: DevTool) -> DevTool? {
        let paths = tool.paths.filter { isOfferedForCleanup($0) }
        guard !paths.isEmpty else { return nil }

        let allowedKeys = Set(paths.map { $0.standardizedFileURL.path })
        let pathSizes = tool.pathSizeBytesByPath.filter { allowedKeys.contains($0.key) }
        let sizedBytes = pathSizes.values.reduce(Int64(0), +)
        let sizeBytes = sizedBytes > 0 ? sizedBytes : (pathSizes.isEmpty ? tool.sizeBytes : 0)
        let stillDetected = !paths.isEmpty && (sizeBytes > 0 || pathSizes.isEmpty)

        return DevTool(
            definitionKey: tool.definitionKey,
            toolName: tool.toolName,
            paths: paths.map(\.standardizedFileURL),
            sizeBytes: sizeBytes,
            pathSizeBytesByPath: pathSizes,
            lastModified: tool.lastModified,
            isSelected: tool.isSelected && stillDetected,
            isDetected: stillDetected,
            safetyInfo: tool.safetyInfo,
            reinstallSafety: tool.reinstallSafety
        )
    }

    nonisolated static func projectGroupFilteredToOfferedCleanup(_ group: ProjectGroup) -> ProjectGroup? {
        let artifacts = group.artifacts.filter { isOfferedForCleanup($0.path) }
        guard !artifacts.isEmpty else { return nil }
        guard artifacts.count != group.artifacts.count else { return group }
        return ProjectGroup(
            displayName: group.displayName,
            rootPath: group.rootPath,
            inferredTypes: group.inferredTypes,
            artifacts: artifacts
        )
    }

    nonisolated static func simulatorFilteredToOfferedCleanup(_ device: SimulatorDevice) -> SimulatorDevice? {
        guard isOfferedForCleanup(device.folderURL) else { return nil }
        return device
    }

    /// Paths where only children may be removed; the directory itself must remain.
    nonisolated static func contentsOnlyPrefixes(home: String) -> [String] {
        [
            "\(home)/Library/Logs",
            "\(home)/Library/Logs/DiagnosticReports",
            "\(home)/Library/Caches"
        ]
    }

    nonisolated static func requiresAdminPrivileges(for url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return systemCacheDeletionPrefixes.contains { prefix in
            path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    nonisolated static func shouldDeleteContentsOnly(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if contentsOnlyPrefixes(home: home).contains(path) { return true }
        // Clear the Telegram media cache's contents but leave the `media`
        // directory itself (and everything above it) in place.
        if isTelegramMediaCacheDirectory(path, home: home) { return true }
        return false
    }

    nonisolated static func isProtectedSystemCache(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let cachesPrefix = "\(home)/Library/Caches"
        let path = standardized.path
        guard path.hasPrefix(cachesPrefix + "/") else { return false }

        let relative = String(path.dropFirst(cachesPrefix.count + 1))
        let topFolder = relative.split(separator: "/").first.map(String.init) ?? ""
        return protectedSystemCacheFolderNames.contains(topFolder)
    }

    nonisolated static func isProtectedLogFolder(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let logsPrefix = "\(home)/Library/Logs"
        let path = standardized.path
        guard path == logsPrefix || path.hasPrefix(logsPrefix + "/") else { return false }

        let relative = path == logsPrefix ? "" : String(path.dropFirst(logsPrefix.count + 1))
        let topFolder = relative.split(separator: "/").first.map(String.init) ?? ""
        return protectedLogFolderNames.contains(topFolder)
    }

    nonisolated static func isProtectedAppContainer(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let containersPrefix = "\(home)/Library/Containers/"
        let path = standardized.path
        guard path.hasPrefix(containersPrefix) else { return false }

        let relative = String(path.dropFirst(containersPrefix.count))
        guard let bundleID = relative.split(separator: "/").first.map(String.init) else {
            return false
        }
        return protectedContainerBundleIDs.contains(bundleID)
    }

    nonisolated static func isWhitelistedApplicationSupportCachePath(_ path: String, home: String) -> Bool {
        let prefix = "\(home)/Library/Application Support/"
        guard path.hasPrefix(prefix) else { return false }

        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty else { return false }

        let topFolder = relative.split(separator: "/").first.map(String.init) ?? ""
        if topFolder.isEmpty || topFolder == relative { return false }

        if relative.hasSuffix("/Crashpad/completed") { return true }

        let lastComponent = relative.split(separator: "/").last.map(String.init) ?? ""
        if CacheDiscoveryPaths.applicationSupportDirectCacheNames.contains(lastComponent) {
            return true
        }

        if relative.contains("/Service Worker/CacheStorage") { return true }
        if relative.contains("/Service Worker/ScriptCache") { return true }

        if relative.contains("/User Data/"),
           CacheDiscoveryPaths.chromiumProfileCacheNames.contains(lastComponent) {
            return true
        }

        return false
    }

    nonisolated static func isWhitelistedContainerCachePath(_ path: String, home: String) -> Bool {
        let containersPrefix = "\(home)/Library/Containers/"
        guard path.hasPrefix(containersPrefix) else { return false }
        guard path.contains("/Data/Library/Caches") else { return false }

        let relative = String(path.dropFirst(containersPrefix.count))
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count >= 4,
              parts[1] == "Data",
              parts[2] == "Library",
              parts[3] == "Caches" else { return false }
        if protectedContainerBundleIDs.contains(parts[0]) { return false }
        return true
    }

    /// Split of a Telegram Group Container path into the segments below
    /// `.../6N38VWS5BX.ru.keepcoder.Telegram/`. Returns `nil` when `path` is not
    /// inside that container at all.
    private nonisolated static func telegramGroupContainerRelativeParts(
        _ path: String,
        home: String
    ) -> [String]? {
        let groupRoot = "\(home)/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/"
        guard path.hasPrefix(groupRoot) else { return nil }
        let relative = String(path.dropFirst(groupRoot.count))
        guard !relative.isEmpty else { return nil }
        return relative.split(separator: "/").map(String.init)
    }

    /// Whether `path` is the Telegram `.../account-*/postbox/media` cache
    /// directory itself, or a descendant of it.
    ///
    /// The account database lives directly in `postbox`, so touching anything
    /// shallower would log the user out or lose local data. Authorization
    /// requires the full `<channel>/account-*/postbox/media` suffix — `postbox`
    /// itself and every ancestor can never match.
    nonisolated static func isWhitelistedTelegramMediaCachePath(_ path: String, home: String) -> Bool {
        guard let parts = telegramGroupContainerRelativeParts(path, home: home) else { return false }
        // channel / account-* / postbox / media  (media itself, or a descendant of it)
        guard parts.count >= 4 else { return false }
        guard !parts[0].isEmpty,
              parts[1].hasPrefix("account-"),
              parts[2] == "postbox",
              parts[3] == "media" else { return false }
        return true
    }

    /// Whether `path` is exactly the Telegram `media` directory (not a
    /// descendant). Used to clean the directory's contents while leaving the
    /// `media` directory itself in place.
    nonisolated static func isTelegramMediaCacheDirectory(_ path: String, home: String) -> Bool {
        guard let parts = telegramGroupContainerRelativeParts(path, home: home) else { return false }
        guard parts.count == 4 else { return false }
        return !parts[0].isEmpty
            && parts[1].hasPrefix("account-")
            && parts[2] == "postbox"
            && parts[3] == "media"
    }

    nonisolated static func isWhitelistedStaleBrowserFrameworkPath(_ path: String) -> Bool {
        guard path.hasPrefix("/Applications/"), path.contains(".app/Contents/Frameworks/") else {
            return false
        }
        guard path.contains("/Versions/") else { return false }
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last != "Current" && last != "Versions"
    }

    nonisolated static func isWhitelistedEditorExtensionPath(_ path: String, home: String) -> Bool {
        let prefixes = [
            "\(home)/.cursor/extensions/",
            "\(home)/.vscode/extensions/"
        ]
        guard let matched = prefixes.first(where: { path.hasPrefix($0) }) else { return false }
        let relative = String(path.dropFirst(matched.count))
        guard !relative.isEmpty, !relative.contains("/") else { return false }
        return true
    }

    nonisolated static func evaluate(_ url: URL) -> DeletionSafetyDecision {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let home = homeURL.path

        if isProtectedSystemCache(standardized)
            || isProtectedAppContainer(standardized)
            || isProtectedLogFolder(standardized) {
            return .blockedNeverDelete
        }

        for allowed in whitelistedAbsolutePrefixes(home: home) {
            if path == allowed || path.hasPrefix(allowed + "/") {
                return .allow
            }
        }

        if isWhitelistedApplicationSupportCachePath(path, home: home) {
            return .allow
        }
        if isWhitelistedContainerCachePath(path, home: home) {
            return .allow
        }
        if isWhitelistedTelegramMediaCachePath(path, home: home) {
            return .allow
        }
        if isWhitelistedStaleBrowserFrameworkPath(path) {
            return .allow
        }
        if isWhitelistedEditorExtensionPath(path, home: home) {
            return .allow
        }

        for blocked in neverDeletePrefixes(home: home) {
            if path == blocked || path.hasPrefix(blocked + "/") {
                return .blockedNeverDelete
            }
        }

        if neverDeleteExactPaths(home: home).contains(path) {
            return .blockedNeverDelete
        }

        let inHome = path == home || path.hasPrefix(home + "/")
        if inHome && whitelistedFolderNames.contains(standardized.lastPathComponent) {
            return .allow
        }

        return .blockedNotWhitelisted
    }
}

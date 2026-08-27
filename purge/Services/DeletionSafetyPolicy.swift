import Foundation

/// Outcome of running a candidate path through the safety policy.
nonisolated enum DeletionSafetyDecision: Equatable {
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

    /// Folders under ~/Library/Caches that must never be offered for cleanup.
    ///
    /// CloudKit and FamilyCircle are macOS-protected (the OS refuses to remove
    /// them even with Full Disk Access). The account/identity daemon caches are
    /// deletable, but wiping them makes accountsd/akd/identityservicesd lose
    /// their cached authorization state and re-hit the login keychain for every
    /// service — the notorious storm of "… wants to use the login keychain"
    /// password prompts. Never offer them; the space is negligible anyway.
    ///
    /// This exact-name set is the record of daemons we have actually caught
    /// causing prompts. It is deliberately paired with
    /// `protectedSystemCacheFolderFragments`: an exact list alone has to be
    /// extended once per newly discovered daemon, and every gap between
    /// discoveries is a prompt storm for the user. The fragment rule closes the
    /// class so a name we have not seen yet is refused by default.
    nonisolated static let protectedSystemCacheFolderNames: Set<String> = [
        "CloudKit",
        "FamilyCircle",
        "com.apple.accountsd",
        "com.apple.appleaccountd",
        "com.apple.amsaccountsd",
        "com.apple.akd",
        "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent",
        "com.apple.identityservicesd",
        "com.apple.iCloudHelper",
        "com.apple.icloudwebd",
        // Caught deleting these in the wild; each forces a re-authorization
        // against the Apple ID and a fresh login-keychain prompt.
        "com.apple.itunescloudd",
        "com.apple.iCloudNotificationAgent",
        "PassKit"
    ]

    /// Case-insensitive fragments that mark a `~/Library/Caches` top-level
    /// folder as identity, authentication, or payment state.
    ///
    /// Matching is substring, not prefix, because the offenders are spread
    /// across naming conventions (`com.apple.amsaccountsd`,
    /// `com.apple.iCloudNotificationAgent`, bare `PassKit`). Fragments are kept
    /// specific enough to avoid ordinary words — `authkit`/`authentication`
    /// rather than a bare `auth`, which would also swallow "Author".
    ///
    /// Over-matching here is the safe direction: the folder is simply not
    /// offered, and these caches are negligible in size.
    nonisolated static let protectedSystemCacheFolderFragments: [String] = [
        "account",
        "icloud",
        "itunescloud",
        "appleid",
        "authkit",
        "authentication",
        "authorization",
        "identityservice",
        "keychain",
        "passkit"
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

    /// Container bundle-ID prefixes covering Apple's account, authentication,
    /// and password stack (Passwords.app, AuthKit, Apple ID, Apple Pay, and
    /// Internet Accounts extensions). Clearing their caches forces the identity
    /// daemons to re-authorize against the login keychain, triggering repeated
    /// keychain password prompts — never offer them.
    nonisolated static let protectedContainerBundleIDPrefixes: [String] = [
        "com.apple.Passwords",
        "com.apple.AuthKit",
        "com.apple.AppleAccount",
        "com.apple.Accounts",
        "com.apple.PassKit",
        "com.apple.Internet-Accounts"
    ]

    /// Whether a container bundle ID belongs to the protected set, by exact
    /// match or protected prefix.
    nonisolated static func isProtectedContainerBundleID(_ bundleID: String) -> Bool {
        if protectedContainerBundleIDs.contains(bundleID) { return true }
        return protectedContainerBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

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
            "\(home)/Library",
            "\(home)/Library/Application Support",
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads"
        ]
    }

    /// The user's home path, resolved once. `FileManager.homeDirectoryForCurrentUser`
    /// plus `standardizedFileURL` was previously re-run inside every protection check,
    /// several times per item, on every flush — it cannot change while the app runs.
    nonisolated static let cachedHomePath: String =
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    /// Prebuilt for `cachedHomePath`, which is the only value production ever passes.
    /// The uncached form allocated ~20 interpolated strings per call, per item, per flush.
    private nonisolated static let cachedWhitelistedPrefixes: [String] =
        whitelistedAbsolutePrefixes(home: cachedHomePath)

    nonisolated static func whitelistedPrefixes(home: String) -> [String] {
        home == cachedHomePath ? cachedWhitelistedPrefixes : whitelistedAbsolutePrefixes(home: home)
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
            // Hex is Elixir/Erlang's package registry; `packages` is a pure download
            // cache, re-fetched by `mix deps.get`. `~/.mix` is deliberately NOT listed:
            // it holds installed Mix archives (tools the user chose to install), not a cache.
            "\(home)/.hex/packages",
            "\(home)/.cache/rebar3",
            "\(home)/.nuget/packages",
            "\(home)/.bun/install/cache",
            "\(home)/.cabal/packages",
            "\(home)/Library/Caches/org.swift.swiftpm",
            "\(home)/.swiftpm/cache",
            // AUDIT: `.stack` also holds downloaded GHC compilers, and `~/.cache/bazel`
            // can be tens of GB. Both re-download rather than being lost, but the next
            // build is very slow — surfaced as Check First, never Safe.
            "\(home)/.stack",
            "\(home)/.cache/bazel",
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
    ///
    /// Memoised by path, because `filterCacheItems` runs over the *entire* accumulated
    /// result set on every scan flush; without a cache the policy was re-evaluated
    /// (items x flushes) times on the main thread, which profiling showed to be
    /// essentially the whole per-flush cost.
    ///
    /// What may be cached is narrower than it looks. `evaluate` now reads the disk, to
    /// check whether a project marker sits above a generically-named folder. That is
    /// safe to memoise: a `mix.exs` or `composer.json` identifies a project for as long
    /// as the project exists, so the answer cannot flip mid-session.
    ///
    /// Refusals are the exception and are deliberately kept *outside* the cache. Whether
    /// a `.terraform` folder holds state changes the moment someone runs `terraform
    /// apply`, so a verdict cached before that would keep offering a folder that has
    /// since become dangerous. It is re-checked on every call, and only for the handful
    /// of folder names that declare a refusal at all.
    nonisolated static func isOfferedForCleanup(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path

        if projectArtifactRefusesDeletion(url) { return false }

        offeredForCleanupLock.lock()
        let cached = offeredForCleanupCache[key]
        offeredForCleanupLock.unlock()
        if let cached { return cached }

        // Evaluated outside the lock: the scanners call this concurrently, and holding
        // the lock across the evaluation would serialise them onto one another.
        let verdict = !requiresAdminPrivileges(for: url) && evaluate(url) == .allow

        offeredForCleanupLock.lock()
        offeredForCleanupCache[key] = verdict
        offeredForCleanupLock.unlock()
        return verdict
    }

    private nonisolated(unsafe) static var offeredForCleanupCache: [String: Bool] = [:]
    private nonisolated static let offeredForCleanupLock = NSLock()

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
        let home = cachedHomePath
        if contentsOnlyPrefixes(home: home).contains(path) { return true }
        // Clear the Telegram media cache's contents but leave the `media`
        // directory itself (and everything above it) in place.
        if isTelegramMediaCacheDirectory(path, home: home) { return true }
        return false
    }

    nonisolated static func isProtectedSystemCache(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let home = cachedHomePath
        let cachesPrefix = "\(home)/Library/Caches"
        let path = standardized.path
        guard path.hasPrefix(cachesPrefix + "/") else { return false }

        let relative = String(path.dropFirst(cachesPrefix.count + 1))
        let topFolder = relative.split(separator: "/").first.map(String.init) ?? ""
        return isProtectedSystemCacheFolderName(topFolder)
    }

    /// Whether a `~/Library/Caches` top-level folder name is protected, by exact
    /// match or by identity/auth/payment fragment.
    nonisolated static func isProtectedSystemCacheFolderName(_ folderName: String) -> Bool {
        if protectedSystemCacheFolderNames.contains(folderName) { return true }
        let lower = folderName.lowercased()
        return protectedSystemCacheFolderFragments.contains { lower.contains($0) }
    }

    nonisolated static func isProtectedLogFolder(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let home = cachedHomePath
        let logsPrefix = "\(home)/Library/Logs"
        let path = standardized.path
        guard path == logsPrefix || path.hasPrefix(logsPrefix + "/") else { return false }

        let relative = path == logsPrefix ? "" : String(path.dropFirst(logsPrefix.count + 1))
        let topFolder = relative.split(separator: "/").first.map(String.init) ?? ""
        return protectedLogFolderNames.contains(topFolder)
    }

    nonisolated static func isProtectedAppContainer(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let home = cachedHomePath
        let containersPrefix = "\(home)/Library/Containers/"
        let path = standardized.path
        guard path.hasPrefix(containersPrefix) else { return false }

        let relative = String(path.dropFirst(containersPrefix.count))
        guard let bundleID = relative.split(separator: "/").first.map(String.init) else {
            return false
        }
        return isProtectedContainerBundleID(bundleID)
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
        if isProtectedContainerBundleID(parts[0]) { return false }
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

    /// Index at which the `account-*/postbox/media` suffix starts within a
    /// container-relative split, or `nil` when the split never reaches it.
    ///
    /// Most installs nest accounts under a distribution channel (`stable`,
    /// `appstore`); some place `account-*` directly at the container root, so
    /// that segment is optional. Nothing deeper is searched: the suffix must
    /// begin at the root or one level below it, which keeps the match anchored
    /// to the real layout rather than any `account-*/postbox/media` triple that
    /// happens to appear further down.
    private nonisolated static func telegramMediaSuffixStart(_ parts: [String]) -> Int? {
        for start in 0...1 where parts.count >= start + 3 {
            guard parts[start].hasPrefix("account-"),
                  parts[start + 1] == "postbox",
                  parts[start + 2] == "media" else { continue }
            return start
        }
        return nil
    }

    /// Whether `path` is the Telegram `.../account-*/postbox/media` cache
    /// directory itself, or a descendant of it.
    ///
    /// The account database lives directly in `postbox`, so touching anything
    /// shallower would log the user out or lose local data. Authorization
    /// requires the full `account-*/postbox/media` suffix — `postbox` itself,
    /// `postbox/db`, and every ancestor can never match.
    nonisolated static func isWhitelistedTelegramMediaCachePath(_ path: String, home: String) -> Bool {
        guard let parts = telegramGroupContainerRelativeParts(path, home: home) else { return false }
        // [channel/] account-* / postbox / media  (media itself, or a descendant)
        return telegramMediaSuffixStart(parts) != nil
    }

    /// Whether `path` is exactly the Telegram `media` directory (not a
    /// descendant). Used to clean the directory's contents while leaving the
    /// `media` directory itself in place.
    nonisolated static func isTelegramMediaCacheDirectory(_ path: String, home: String) -> Bool {
        guard let parts = telegramGroupContainerRelativeParts(path, home: home),
              let start = telegramMediaSuffixStart(parts) else { return false }
        return parts.count == start + 3
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

    /// Whether this path is a build artifact of a real project sitting right above it.
    ///
    /// This is the mechanism that lets Purge offer folders whose *names* are far too
    /// generic to ever allow globally — `bin`, `obj`, `vendor`, `Temp`, and Unity's
    /// `Library`. Nothing is allowed on the strength of its name. The folder only
    /// qualifies when the directory it sits in is demonstrably a project of the matching
    /// kind, proven by a marker file such as `mix.exs`, `composer.json`, or a `.csproj`.
    ///
    /// Deliberately evaluated *after* the never-delete guards in `evaluate`, so a project
    /// checked out inside Pictures, Music, or Mail still exposes nothing.
    /// Whether any rule matching this folder name refuses it because of what is inside.
    ///
    /// Intentionally not memoised: unlike a project marker, the contents this looks for
    /// can appear between one scan and the next.
    nonisolated static func projectArtifactRefusesDeletion(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard let candidates = ProjectArtifactCatalog.rulesByFolderName[standardized.lastPathComponent] else {
            return false
        }
        return candidates.contains { $0.refusesArtifact(at: standardized) }
    }

    nonisolated static func isWhitelistedProjectArtifactPath(_ url: URL, home: String) -> Bool {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard path == home || path.hasPrefix(home + "/") else { return false }

        guard let candidates = ProjectArtifactCatalog.rulesByFolderName[standardized.lastPathComponent] else {
            return false
        }

        for rule in candidates {
            // Walk back up by however many components the rule's folder spans, so
            // `ios/Pods` anchors on the Xcode project root rather than on `ios`.
            let depth = rule.folder.split(separator: "/").count
            var root = standardized
            for _ in 0..<depth { root = root.deletingLastPathComponent() }
            guard root.path.hasPrefix(home + "/") || root.path == home else { continue }
            guard rule.matchesRoot(root) else { continue }
            // Checked here rather than only in the scanner so that no caller can route
            // around it: a `.terraform` folder holding state is never deletable.
            guard !rule.refusesArtifact(at: standardized) else { continue }
            return true
        }
        return false
    }

    nonisolated static func evaluate(_ url: URL) -> DeletionSafetyDecision {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        let home = cachedHomePath

        if isProtectedSystemCache(standardized)
            || isProtectedAppContainer(standardized)
            || isProtectedLogFolder(standardized) {
            return .blockedNeverDelete
        }

        for allowed in whitelistedPrefixes(home: home) {
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
        // Deliberately below the never-delete guards, exactly like the folder-name rule
        // above it: this matches on a name plus nearby evidence, not on an audited
        // absolute path, so the protections for Pictures, Music, Mail and the rest win.
        if isWhitelistedProjectArtifactPath(standardized, home: home) {
            return .allow
        }

        return .blockedNotWhitelisted
    }
}

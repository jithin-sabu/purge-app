import Foundation

enum SafetyTierList {

    /// Folders we are 100% certain are safe to delete.
    /// These are always regenerated automatically with zero data loss.
    nonisolated static let definitelySafe: Set<String> = [
        "node_modules",
        "DerivedData",
        ".next",
        ".nuxt",
        ".turbo",
        ".parcel-cache",
        "__pycache__",
        ".gradle",
        "target",
        "build",
        "dist",
        "out",
        ".cache",
        "venv",
        ".venv",
        "_cacache",
        "_npx",
        "_logs",
        "GPUCache",
        "ShaderCache",
        "CachedData",
        "Code Cache",
        "DawnWebGPUCache",
        "component_crx_cache",
        "DocumentationCache",
        "LinkThumbnail",
        "ChatMedia",
        "AppInstallationBinaryDeltas",
        "corepack",
        "Homebrew",
        "yarn",
        "pnpm",
        "pip",
        "cocoapods",
        "Pods",
        ".dart_tool"
    ]

    /// Bundle ID prefixes we are certain are safe app caches.
    /// These are standard app cache folders that apps recreate automatically.
    nonisolated static let definitelySafeBundlePrefixes: [String] = [
        "com.google.Chrome",
        // Not "com.apple.Safari": as a prefix it also matched Safari's bookmark and
        // history sync agents. Safari's own cache is matched by bundle ID instead.
        "org.mozilla.firefox",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.spotify.client",
        "com.tinyspeck.slackmacgap",
        "com.figma.desktop",
        "us.zoom.xos",
        "com.microsoft.VSCode",
        "com.todesktop",
        "com.raycast.macos",
        "com.runningwithcrayons.Alfred",
        "com.hnc.Discord",
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",
        "notion.id",
        "com.linear",
        "com.loom.desktop",
        "com.grammarly",
        "com.ollama.ollama",
        "com.microsoft.teams"
    ]

    /// Folders that involve user data, syncing, or an index the system has to
    /// rebuild. Safe to delete technically, but each one costs the user
    /// something visible afterwards — a re-sync, a re-index, or a sign-in — so
    /// they are excluded from one-click and scheduled cleanup.
    nonisolated static let checkFirst: Set<String> = [
        "com.apple.Spotlight",
        "com.apple.mail",
        "com.apple.Photos",
        "com.apple.Music",
        "com.apple.Maps",
        "com.apple.GeoServices",
        "com.dropbox.client2",
        "com.google.GoogleDrive",
        "com.google.drivefs",
        "com.microsoft.OneDrive",
        "com.apple.cloudd",
        "com.1password.1password",
        "com.apple.icloud"
    ]

    /// `<…>/Library/Application Support/<App>/<cache>`, checked against the app
    /// folder with `CacheDiscoveryPaths.isApplicationSupportCachePath`.
    private nonisolated static func isApplicationSupportChromiumCache(_ path: URL) -> Bool {
        let components = path.standardizedFileURL.pathComponents
        guard let index = components.indices.dropLast().first(where: {
            components[$0] == "Library" && components[$0 + 1] == "Application Support"
        }) else { return false }
        let appIndex = index + 2
        guard components.count > appIndex + 1 else { return false }
        let appRoot = URL(
            fileURLWithPath: NSString.path(withComponents: Array(components[...appIndex])),
            isDirectory: true
        )
        return CacheDiscoveryPaths.isApplicationSupportCachePath(
            Array(components[(appIndex + 1)...]),
            appRoot: appRoot
        )
    }

    /// - Parameter home: whose `Library/Caches` the Chromium shape rule looks
    ///   in. Tests pass a throwaway home.
    nonisolated static func evaluate(
        folderName: String,
        path: URL? = nil,
        home: String = DeletionSafetyPolicy.cachedHomePath
    ) -> SafetyLevel? {
        switch ruleRating(folderName: folderName, path: path) {
        case .decided(let level):
            return level
        case .unrated:
            // A folder in `~/Library/Caches` that no name above knows, holding
            // nothing but a browser's disk caches. The shape decides, as for the
            // Application Support caches above, so a new Chromium browser needs
            // no entry. Checked last, so it only ever lifts a folder that would
            // be Not Sure. A move reads the shape again
            // (`passesChromiumShapeBoundary`).
            if let path, holdsChromiumShapeInHomeCaches(path, home: home) {
                return .safe
            }
            // Unknown, let AI decide
            return nil
        }
    }

    /// What every rule but the Chromium shape rule says about a folder.
    private enum RuleRating {
        /// A rule gave this tier, or decided the folder gets none (`nil`).
        case decided(SafetyLevel?)
        /// No rule knows the folder, so only the shape rule can rate it.
        case unrated
    }

    private nonisolated static func ruleRating(folderName: String, path: URL?) -> RuleRating {
        let lower = folderName.lowercased()

        if let path {
            let pathLower = path.standardizedFileURL.path.lowercased()
            // Never a `Service Worker` cache: its loss removes sites' workers and
            // their web push subscriptions (`CacheDiscoveryPaths`).
            if pathLower.contains("/service worker/") {
                return .decided(nil)
            }
            // Crash reports an app has not sent yet are Check First (#367), even in
            // a folder the Application Support shape below would call Safe.
            if pathLower.hasSuffix("/crashpad/pending") || pathLower.contains("/crashpad/pending/") {
                return .decided(.medium)
            }
            if pathLower.contains("/gpucache")
                || pathLower.contains("/shadercache")
                || pathLower.contains("/code cache")
                || pathLower.contains("/cacheddata")
                || pathLower.contains("/component_crx_cache")
                || pathLower.contains("/crashpad/completed")
                || pathLower.contains("/linkthumbnail")
                || pathLower.contains("/chatmedia")
                || pathLower.contains("/appinstallationbinarydeltas") {
                return .decided(.safe)
            }
            // An Electron or Chromium app's cache under Application Support, in the
            // shape the scan lists and the deletion policy allows. The shape decides,
            // not the name: a folder merely named Cache could be anything.
            if isApplicationSupportChromiumCache(path) {
                return .decided(.safe)
            }
            // Spotlight index data regenerates on its own, but search is slow or
            // incomplete until it does — a visible inconvenience, so never part
            // of one-click cleanup.
            if pathLower.contains("/spotlight/") || pathLower.contains("com.apple.spotlight") {
                return .decided(.medium)
            }
            if pathLower.contains(".app/contents/frameworks/") && pathLower.contains("/versions/") {
                return .decided(.medium)
            }
            if pathLower.contains("/.cursor/projects/")
                || AgentWorktreeScanPolicy.looksLikeAgentWorktreePath(
                    path,
                    home: FileManager.default.homeDirectoryForCurrentUser
                ) {
                return .decided(.medium)
            }
        }

        if lower == "stale-browser-framework" {
            return .decided(.medium)
        }

        if lower.hasSuffix(".shipit") {
            return .decided(.safe)
        }

        // Check definitely safe folder names
        if definitelySafe.contains(where: { lower == $0.lowercased() }) {
            return .decided(.safe)
        }

        // Check definitely safe bundle ID prefixes
        for prefix in definitelySafeBundlePrefixes where lower.hasPrefix(prefix.lowercased()) {
            return .decided(.safe)
        }

        // Check check first
        if checkFirst.contains(where: { lower == $0.lowercased() }) {
            return .decided(.medium)
        }

        return .unrated
    }

    /// Whether `path` sits directly in `<home>/Library/Caches`. Not a sandboxed
    /// app's `Data/Library/Caches`: the shape was only checked against browsers
    /// that write to the home one.
    private nonisolated static func isInHomeCaches(_ path: URL, home: String) -> Bool {
        path.standardizedFileURL.deletingLastPathComponent().path == home + "/Library/Caches"
    }

    /// Whether `path` is a folder directly in `<home>/Library/Caches` that holds
    /// nothing but Chromium disk caches, read from disk now. The shape rule and
    /// entries marked `needs_chromium_shape` rate a folder Safe only while this
    /// is true.
    nonisolated static func holdsChromiumShapeInHomeCaches(_ path: URL, home: String) -> Bool {
        isInHomeCaches(path, home: home) && CacheDiscoveryPaths.holdsOnlyChromiumDiskCaches(path)
    }

    /// Whether only the Chromium shape could have rated `url` Safe: a folder
    /// directly in `<home>/Library/Caches` whose own name has an entry marked
    /// `needs_chromium_shape`, or that no entry and no other rule here knows.
    /// Worked out from the folder's name, the bundled entries and the disk,
    /// never from what a scan in this process rated, so a row cleaned from a
    /// saved scan, an App Intent or another process is held to the shape too
    /// (#452). A folder a rule here decides gets no tier, such as a
    /// `Service Worker` path, is held to it as well, which only ever refuses
    /// more.
    ///
    /// The scan rates a `<app>-updater` folder with a `pending` folder under the
    /// Electron updater entry, whatever its own name. That rating counts here
    /// only while the folder holds nothing but `pending` and loose files
    /// (`holdsOnlyUpdaterDownloads`). A browser cache folder the shape rated
    /// keeps its profile folders when it gains a `pending` folder, so it is
    /// still held to the shape. An updater folder that lost `pending` before the
    /// move, and whose own name nothing knows, is held to the shape too and
    /// stays: nothing tells it apart from a folder the shape rated.
    nonisolated static func dependsOnChromiumShape(_ url: URL, home: String) -> Bool {
        guard isInHomeCaches(url, home: home), shapeCouldRate(url) else { return false }
        if CacheDiscoveryPaths.isElectronUpdaterCache(url), holdsOnlyUpdaterDownloads(url) {
            return false
        }
        // `GOMODCACHE` can name a folder here. Its row is rated by
        // `GoModuleCacheScanPolicy`, which reads the folder again before the move.
        if GoModuleCacheScanPolicy.isWholeCacheRoot(url) {
            return false
        }
        return true
    }

    /// Whether the shape rule, or an entry that needs the shape, decides the
    /// tier of a folder with this name in the home's Caches.
    private nonisolated static func shapeCouldRate(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if let record = ExplanationDatabase.matchBundledDatabase(folderName: name) {
            return record.needsChromiumShape == true
        }
        switch ruleRating(folderName: name, path: url) {
        case .decided(let level):
            return level == nil
        case .unrated:
            return true
        }
    }

    /// Whether `folder` holds only what electron-updater writes there: a real
    /// `pending` folder and regular files. Any other folder, a link or an entry
    /// that can't be read fails.
    private nonisolated static func holdsOnlyUpdaterDownloads(_ folder: URL) -> Bool {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        ) else { return false }
        return children.allSatisfy { child in
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                return false
            }
            // `isDirectoryKey` and `isRegularFileKey` are false for a link.
            if child.lastPathComponent == "pending" {
                return values.isDirectory == true
            }
            return values.isRegularFile == true
        }
    }

    /// Checked before each Trash move. A folder that only the Chromium shape
    /// could have rated Safe (`dependsOnChromiumShape`) moves only while it
    /// still has that shape, whoever rated it and whenever. Every other path
    /// passes.
    nonisolated static func passesChromiumShapeBoundary(
        _ url: URL,
        home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    ) -> Bool {
        guard dependsOnChromiumShape(url, home: home) else { return true }
        return CacheDiscoveryPaths.holdsOnlyChromiumDiskCaches(url)
    }
}

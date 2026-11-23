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
        let lower = folderName.lowercased()

        if let path {
            let pathLower = path.standardizedFileURL.path.lowercased()
            // Never a `Service Worker` cache: its loss removes sites' workers and
            // their web push subscriptions (`CacheDiscoveryPaths`).
            if pathLower.contains("/service worker/") {
                return nil
            }
            // Crash reports an app has not sent yet are Check First (#367), even in
            // a folder the Application Support shape below would call Safe.
            if pathLower.hasSuffix("/crashpad/pending") || pathLower.contains("/crashpad/pending/") {
                return .medium
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
                return .safe
            }
            // An Electron or Chromium app's cache under Application Support, in the
            // shape the scan lists and the deletion policy allows. The shape decides,
            // not the name: a folder merely named Cache could be anything.
            if isApplicationSupportChromiumCache(path) {
                return .safe
            }
            // Spotlight index data regenerates on its own, but search is slow or
            // incomplete until it does — a visible inconvenience, so never part
            // of one-click cleanup.
            if pathLower.contains("/spotlight/") || pathLower.contains("com.apple.spotlight") {
                return .medium
            }
            if pathLower.contains(".app/contents/frameworks/") && pathLower.contains("/versions/") {
                return .medium
            }
            if pathLower.contains("/.cursor/projects/")
                || AgentWorktreeScanPolicy.looksLikeAgentWorktreePath(
                    path,
                    home: FileManager.default.homeDirectoryForCurrentUser
                ) {
                return .medium
            }
        }

        if lower == "stale-browser-framework" {
            return .medium
        }

        if lower.hasSuffix(".shipit") {
            return .safe
        }

        // Check definitely safe folder names
        if definitelySafe.contains(where: { lower == $0.lowercased() }) {
            return .safe
        }

        // Check definitely safe bundle ID prefixes
        for prefix in definitelySafeBundlePrefixes where lower.hasPrefix(prefix.lowercased()) {
            return .safe
        }

        // Check check first
        if checkFirst.contains(where: { lower == $0.lowercased() }) {
            return .medium
        }

        // A folder in `~/Library/Caches` that no name above knows, holding nothing
        // but a browser's disk caches. The shape decides, as for the Application
        // Support caches above, so a new Chromium browser needs no entry. Checked
        // last, so it only ever lifts a folder that would be Not Sure. A move
        // reads the shape again (`passesChromiumShapeBoundary`).
        if let path, isInHomeCaches(path, home: home), CacheDiscoveryPaths.holdsOnlyChromiumDiskCaches(path) {
            recordShapeRating(path)
            return .safe
        }

        // Unknown, let AI decide
        return nil
    }

    /// Whether `path` sits directly in `<home>/Library/Caches`. Not a sandboxed
    /// app's `Data/Library/Caches`: the shape was only checked against browsers
    /// that write to the home one.
    private nonisolated static func isInHomeCaches(_ path: URL, home: String) -> Bool {
        path.standardizedFileURL.deletingLastPathComponent().path == home + "/Library/Caches"
    }

    /// Folders this session rated Safe by their Chromium shape, standardized
    /// paths. The rating is read at scan time, and the browser can write
    /// something else there before the clean, so a move reads the shape again
    /// for each of these. Only these: a folder rated by its name, or a row some
    /// other rule offered, is never held to the shape. Kept for the life of the
    /// app, so a later scan that rates the folder some other way still has it
    /// checked, which only ever refuses more.
    private nonisolated(unsafe) static var shapeRatedPaths = Set<String>()
    private nonisolated static let shapeRatedLock = NSLock()

    private nonisolated static func recordShapeRating(_ path: URL) {
        let key = path.standardizedFileURL.path
        shapeRatedLock.lock()
        shapeRatedPaths.insert(key)
        shapeRatedLock.unlock()
    }

    /// Whether this session rated `path` Safe by its Chromium shape.
    nonisolated static func wasRatedByChromiumShape(_ path: URL) -> Bool {
        let key = path.standardizedFileURL.path
        shapeRatedLock.lock()
        defer { shapeRatedLock.unlock() }
        return shapeRatedPaths.contains(key)
    }

    /// Checked before each Trash move. A folder rated Safe by its shape, by the
    /// rule above or through an entry marked `needs_chromium_shape`, moves only
    /// while it still has that shape. Every other path passes.
    nonisolated static func passesChromiumShapeBoundary(
        _ url: URL,
        home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    ) -> Bool {
        guard isInHomeCaches(url, home: home), wasRatedByChromiumShape(url) else { return true }
        return CacheDiscoveryPaths.holdsOnlyChromiumDiskCaches(url)
    }
}

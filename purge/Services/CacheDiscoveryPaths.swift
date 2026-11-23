import Foundation

/// Shared rules for locating cache directories outside `~/Library/Caches`.
enum CacheDiscoveryPaths {
    /// Cache folder names directly in a Chromium data folder: an Electron app’s
    /// Application Support root, or the root of a Chromium `User Data` folder.
    /// Chromium writes its GPU shader caches under several names over the years,
    /// and current builds write both `DawnGraphiteCache` and `GraphiteDawnCache`.
    nonisolated static let applicationSupportDirectCacheNames: Set<String> = [
        "Cache",
        "Code Cache",
        "GPUCache",
        "ShaderCache",
        "GrShaderCache",
        "DawnCache",
        "DawnWebGPUCache",
        "DawnGraphiteCache",
        "GraphiteDawnCache",
        "CachedData",
        "component_crx_cache"
    ]

    /// Relative paths (from an app’s Application Support root) always treated as caches.
    nonisolated static let applicationSupportRelativeCachePaths: [String] = [
        "Crashpad/completed"
    ]

    // Crashpad, the crash reporter in Chromium and Electron, keeps its reports in
    // a `Crashpad` folder. It writes each report in `new`, renames it into
    // `pending` once it is finished, and into `completed` once it is sent or the
    // app skips sending it. Every time the app starts, Crashpad makes `new`,
    // `pending`, `completed` and `settings.dat` again if they are missing. A
    // report in `new` is still being written, so `new` is never offered.

    nonisolated static let crashpadFolderName = "Crashpad"

    /// The report folders Purge offers inside a Crashpad folder.
    nonisolated static let crashpadCompletedName = "completed"
    nonisolated static let crashpadPendingName = "pending"

    /// Classification name for every `Crashpad/pending` folder: finished crash
    /// reports an app has not sent yet (#367). They share one Check First row, so
    /// they never make an app's own cache row Check First, and Clean Safe Items
    /// and scheduled cleans never take them.
    nonisolated static let crashpadPendingKey = "Unsent Crash Reports"

    /// How many folders may sit between an app's Application Support folder and
    /// its `Crashpad` folder: none for `Codex/Crashpad`, one for
    /// `com.openai.codex/web/Crashpad`, two for `Figma/DesktopProfile/v43/Crashpad`.
    nonisolated static let crashpadMaxDepth = 2

    /// A Crashpad report database: a real, visible `Crashpad` folder with
    /// Crashpad's `settings.dat` file and its `new` folder inside. A folder that
    /// is merely named Crashpad has neither.
    nonisolated static func isCrashpadDatabase(_ folder: URL) -> Bool {
        guard folder.lastPathComponent == crashpadFolderName, isVisibleRealDirectory(folder) else { return false }
        let settings = folder.appendingPathComponent("settings.dat", isDirectory: false)
        return (try? settings.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && isRealDirectory(folder.appendingPathComponent("new", isDirectory: true))
    }

    /// A `Crashpad/pending` folder, by its last two names. Sorts it onto the
    /// Unsent Crash Reports row and its Check First tier. Never a reason to offer it.
    nonisolated static func isCrashpadPendingFolder(_ url: URL) -> Bool {
        url.lastPathComponent == crashpadPendingName
            && url.deletingLastPathComponent().lastPathComponent == crashpadFolderName
    }

    /// Whether `parts`, a path inside the Application Support folder `appRoot`, is
    /// the `pending` or `completed` folder of a Crashpad database at most
    /// `crashpadMaxDepth` folders down. The app folder, every folder on the way and
    /// the report folder must be real, visible folders, as discovery walks them:
    /// a link as the app folder would send the move outside Application Support.
    /// The plain `Crashpad/completed` in `applicationSupportRelativeCachePaths` is
    /// allowed by its name and needs none of this.
    nonisolated static func isCrashpadReportsPath(_ parts: [String], appRoot: URL) -> Bool {
        guard (2...(crashpadMaxDepth + 2)).contains(parts.count),
              [crashpadPendingName, crashpadCompletedName].contains(parts[parts.count - 1]),
              !appRoot.lastPathComponent.hasPrefix("."), isVisibleRealDirectory(appRoot) else { return false }
        var folder = appRoot
        for part in parts.dropLast() {
            folder = folder.appendingPathComponent(part, isDirectory: true)
            guard !part.hasPrefix("."), isVisibleRealDirectory(folder) else { return false }
        }
        return isCrashpadDatabase(folder)
            && isVisibleRealDirectory(folder.appendingPathComponent(parts[parts.count - 1], isDirectory: true))
    }

    /// Cache folder names under Chromium `User Data/<profile>/`.
    nonisolated static let chromiumProfileCacheNames: Set<String> = [
        "GPUCache",
        "ShaderCache",
        "Code Cache",
        "Cache",
        "DawnCache",
        "DawnWebGPUCache",
        "DawnGraphiteCache",
        "GraphiteDawnCache"
    ]

    // Nothing in a `Service Worker` folder is offered, in any of these shapes.
    // `ScriptCache` holds each site's worker scripts, and Chromium deletes a
    // registration whose script it can't read, with the site's web push
    // subscription. `CacheStorage` holds installed web apps' offline content.
    // Browsers keep their profiles in these shapes too (`Google/Chrome Beta/Default`,
    // `Dia/User Data/Default`), and the user must visit each site again.

    /// Application Support roots that are not app caches (handled elsewhere or sensitive).
    nonisolated static let excludedApplicationSupportRoots: Set<String> = [
        "MobileSync",
        "CallHistoryDB",
        "AddressBook",
        "SyncServices",
        "Knowledge",
        "com.apple.TCC",
        "com.apple.sharedfilelist"
    ]

    /// Files Chromium writes at the root of its data folder. Any app can name a
    /// folder `Cache`, so the generic cache names count only in a folder that has
    /// one of these (#130). Some Electron apps write only `Network Persistent State`.
    nonisolated static let chromiumDataFolderMarkers = ["Local State", "Network Persistent State"]

    nonisolated static func isChromiumDataFolder(_ folder: URL, access: ScanAccess = .full) -> Bool {
        let fm = FileManager.default
        return chromiumDataFolderMarkers.contains {
            let marker = folder.appendingPathComponent($0, isDirectory: false)
            return ProtectedLocations.isReadable(marker, access: access) && fm.fileExists(atPath: marker.path)
        }
    }

    /// A folder named `Cache` is Chromium's HTTP cache only with Chromium's
    /// layout inside: `Cache_Data` since Chromium 96, or the older blockfile
    /// `index` and `data_0`. A folder merely named Cache could be anything (#226).
    /// No link is followed: `Cache_Data` must be a real folder, and `index` and
    /// `data_0` regular files. A link, or a folder with a file's name, would
    /// leave the name as the only evidence (#443).
    nonisolated static func hasChromiumHTTPCacheLayout(_ cache: URL) -> Bool {
        if isRealDirectory(cache.appendingPathComponent("Cache_Data", isDirectory: true)) { return true }
        return ["index", "data_0"].allSatisfy {
            isRegularFile(cache.appendingPathComponent($0, isDirectory: false))
        }
    }

    /// A regular file, not a link. `isRegularFileKey` is false for a link.
    private nonisolated static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// Whether `parts`, a path inside the Application Support folder `appRoot`,
    /// is a cache Purge offers there: a cache directly in an Electron app's
    /// folder, a cache in its Chromium `User Data` folder, a cache in a Chromium
    /// storage folder one or two levels down, `Crashpad/completed`, or the
    /// `pending` or `completed` folder of a Crashpad database up to two levels
    /// down. Never a `Service Worker` cache.
    /// The name is never enough by itself. The folder it sits in must be a
    /// Chromium data folder, and `Cache` needs Chromium's layout inside.
    /// `applicationSupportCacheURLs` lists exactly these paths, and
    /// `DeletionSafetyPolicy` allows exactly these.
    nonisolated static func isApplicationSupportCachePath(_ parts: [String], appRoot: URL) -> Bool {
        if applicationSupportRelativeCachePaths.contains(parts.joined(separator: "/")) { return true }
        if isCrashpadReportsPath(parts, appRoot: appRoot) { return true }
        if parts.count == 1 {
            return isChromiumDataFolder(appRoot)
                && isChromiumCacheFolder(appRoot.appendingPathComponent(parts[0], isDirectory: true),
                                         names: applicationSupportDirectCacheNames)
        }
        if parts.first == "User Data",
           isChromiumUserDataCachePath(
               Array(parts.dropFirst()),
               userData: appRoot.appendingPathComponent("User Data", isDirectory: true)
           ) {
            return true
        }
        return isNestedChromiumStorageCachePath(parts, appRoot: appRoot)
    }

    /// How far below an app's Application Support folder a Chromium storage folder
    /// is looked for. Chrome keeps its data in `Google/Chrome Beta` and its profiles
    /// in `Google/Chrome Beta/Default`, Figma in `Figma/DesktopProfile/v43`, and
    /// Electron apps keep one per session in `Partitions/<name>` (#323).
    nonisolated static let nestedChromiumStorageMaxDepth = 2

    /// Whether `parts` is a cache in a Chromium storage folder at most
    /// `nestedChromiumStorageMaxDepth` folders below `appRoot`. A storage folder
    /// holds Chromium's `Local State` or `Network Persistent State`, and only the
    /// cache names directly in it count. Every folder on the way down must be a
    /// real folder, not a link, and hidden folders are skipped, as discovery
    /// skips them.
    nonisolated static func isNestedChromiumStorageCachePath(_ parts: [String], appRoot: URL) -> Bool {
        let depth = parts.count - 1
        guard (1...nestedChromiumStorageMaxDepth).contains(depth) else { return false }
        var storage = appRoot
        for part in parts.prefix(depth) {
            storage = storage.appendingPathComponent(part, isDirectory: true)
            guard !part.hasPrefix("."), isRealDirectory(storage) else { return false }
        }
        return isChromiumDataFolder(storage)
            && isChromiumCacheFolder(storage.appendingPathComponent(parts[depth], isDirectory: true),
                                     names: applicationSupportDirectCacheNames)
    }

    /// How many folders may sit between a browser's folder in `~/Library/Caches`
    /// and one profile's cache folders: one for `Vivaldi/Default`, two for
    /// `Google/Chrome/Default` and `Yab/Chromium/space-<id>`, three for a profile
    /// in a `User Data` folder one level further down.
    nonisolated static let cachesFolderChromiumMaxDepth = 3

    /// Whether `folder`, a folder in a `Library/Caches` folder, holds nothing but
    /// Chromium disk caches. Chromium on macOS keeps a profile in Application
    /// Support and writes its HTTP cache and code cache to the matching folder in
    /// `~/Library/Caches` (`Google/Chrome/Default/Cache`,
    /// `Yab/Chromium/space-<id>/Cache`). A browser with no `explanations.json`
    /// entry is then known by what it wrote, not by its name.
    ///
    /// Every entry on the way down must be a real, visible folder. A file, a link
    /// or a hidden entry fails the check, and so does a folder below
    /// `cachesFolderChromiumMaxDepth`. Only `chromiumProfileCacheNames` count as
    /// caches. A `Service Worker` folder fails it even when empty: it is profile
    /// data, never a folder on the way to a cache. At least one `Cache`
    /// must have Chromium's HTTP cache layout, and every `Cache` must have it,
    /// with no link in it (`hasRealChromiumHTTPCacheLayout`). Nothing inside a
    /// cache folder is read beyond that.
    nonisolated static func holdsOnlyChromiumDiskCaches(_ folder: URL) -> Bool {
        guard isVisibleRealDirectory(folder) else { return false }
        var foundHTTPCache = false
        var level = [folder]
        for depth in 0...cachesFolderChromiumMaxDepth {
            var next: [URL] = []
            for parent in level {
                guard let children = realSubfoldersOnly(parent) else { return false }
                for child in children {
                    let name = child.lastPathComponent
                    if chromiumProfileCacheNames.contains(name) {
                        if name == "Cache" {
                            guard hasRealChromiumHTTPCacheLayout(child) else { return false }
                            foundHTTPCache = true
                        }
                    } else {
                        guard name != "Service Worker", depth < cachesFolderChromiumMaxDepth else { return false }
                        next.append(child)
                    }
                }
            }
            level = next
            if level.isEmpty { break }
        }
        return foundHTTPCache
    }

    /// `hasChromiumHTTPCacheLayout` without following a link: `Cache_Data` a
    /// real folder, or `index` and `data_0` regular files. A link there would
    /// make a name the only evidence left.
    private nonisolated static func hasRealChromiumHTTPCacheLayout(_ cache: URL) -> Bool {
        if isRealDirectory(cache.appendingPathComponent("Cache_Data", isDirectory: true)) { return true }
        return ["index", "data_0"].allSatisfy {
            isRegularFile(cache.appendingPathComponent($0, isDirectory: false))
        }
    }

    /// A regular file, not a link. `isRegularFileKey` is false for a link.
    private nonisolated static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// The folders in `folder`, or nil when it holds anything else: a file, a
    /// link, a hidden entry, or an entry that can't be read. Finder's
    /// `.DS_Store` file is the one file allowed, and only as a regular file: a
    /// folder or link with that name fails. Stops at the first entry that
    /// fails, so a large folder of files costs one read.
    private nonisolated static func realSubfoldersOnly(_ folder: URL) -> [URL]? {
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isRegularFileKey],
            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
            errorHandler: { _, _ in
                failed = true
                return false
            }
        ) else { return nil }
        var folders: [URL] = []
        for case let child as URL in enumerator {
            let name = child.lastPathComponent
            if name == ".DS_Store", isRegularFile(child) { continue }
            guard !name.hasPrefix("."), isVisibleRealDirectory(child) else { return nil }
            folders.append(child)
        }
        return failed ? nil : folders
    }

    /// A folder that is not a link. `isDirectoryKey` is false for a link to a folder.
    private nonisolated static func isRealDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// A real folder Finder shows: no leading dot and no hidden flag. The walk
    /// skips hidden folders, but a name Purge builds itself, like `Crashpad`,
    /// needs the check made here.
    private nonisolated static func isVisibleRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey]) else { return false }
        return values.isDirectory == true && values.isHidden != true
    }

    /// Readable, non-hidden folders one and two levels below `appRoot`, links
    /// left out. Both nested walks share it: Chromium storage folders and
    /// Crashpad databases are looked for at the same depths.
    nonisolated static func subfoldersBelow(_ appRoot: URL, access: ScanAccess = .full) -> [URL] {
        /// Readable, non-hidden folders directly in `folder`, links left out.
        func subfolders(of folder: URL) -> [URL] {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return children.filter {
                ProtectedLocations.isReadable($0, access: access) && isRealDirectory($0)
            }
        }

        var results: [URL] = []
        var level = [appRoot]
        for _ in 1...max(nestedChromiumStorageMaxDepth, crashpadMaxDepth) {
            level = level.flatMap(subfolders(of:))
            results += level
        }
        return results
    }

    /// Chromium storage folders one and two levels below `appRoot`, in the shape
    /// `isNestedChromiumStorageCachePath` accepts. Links are never followed.
    nonisolated static func nestedChromiumStorageFolders(
        in appRoot: URL,
        access: ScanAccess = .full,
        subfolders: [URL]? = nil
    ) -> [URL] {
        (subfolders ?? subfoldersBelow(appRoot, access: access))
            .filter { isChromiumDataFolder($0, access: access) }
    }

    /// The `pending` and `completed` folders of every Crashpad database in
    /// `appRoot` or up to `crashpadMaxDepth` folders below it, in the shape
    /// `isCrashpadReportsPath` accepts. `subfolders` is `subfoldersBelow(appRoot)`.
    nonisolated static func crashpadReportFolders(
        in appRoot: URL,
        access: ScanAccess = .full,
        subfolders: [URL]? = nil
    ) -> [URL] {
        var results: [URL] = []
        for parent in [appRoot] + (subfolders ?? subfoldersBelow(appRoot, access: access)) {
            let crashpad = parent.appendingPathComponent(crashpadFolderName, isDirectory: true)
            guard ProtectedLocations.isReadable(crashpad, access: access), isCrashpadDatabase(crashpad) else {
                continue
            }
            for name in [crashpadCompletedName, crashpadPendingName] {
                let folder = crashpad.appendingPathComponent(name, isDirectory: true)
                guard ProtectedLocations.isReadable(folder, access: access), isVisibleRealDirectory(folder) else {
                    continue
                }
                results.append(folder)
            }
        }
        return results
    }

    /// Whether `parts`, a path inside a Chromium `User Data` folder, is a cache
    /// at its root or a cache in one of its profiles. Never the folder itself, a
    /// profile, its `Service Worker` folder, or anything else in it.
    nonisolated static func isChromiumUserDataCachePath(_ parts: [String], userData: URL) -> Bool {
        guard !parts.isEmpty, parts.count <= 2, isChromiumDataFolder(userData) else { return false }
        let url = parts.reduce(userData) { $0.appendingPathComponent($1, isDirectory: true) }
        switch parts.count {
        case 1:
            return isChromiumCacheFolder(url, names: applicationSupportDirectCacheNames)
        default:
            return isChromiumCacheFolder(url, names: chromiumProfileCacheNames)
        }
    }

    /// Call it only on a folder already checked with `ProtectedLocations.isReadable`:
    /// the `Cache` check looks inside.
    private nonisolated static func isChromiumCacheFolder(_ url: URL, names: Set<String>) -> Bool {
        let name = url.lastPathComponent
        guard names.contains(name) else { return false }
        return name != "Cache" || hasChromiumHTTPCacheLayout(url)
    }

    /// Grouping key for the Application Support caches of an app with no
    /// `explanations.json` entry, so they show as one row instead of one per
    /// folder. It never matches an entry, so the row's tier comes from its folders.
    nonisolated static func applicationSupportGroupKey(appFolderName: String) -> String {
        "application-support:\(appFolderName)"
    }

    /// Returns every cache candidate path under `~/Library/Application Support/<appRoot>/`.
    ///
    /// A limited scan checks each path with `ProtectedLocations.isReadable` before
    /// anything else reads it, since any of these folders can be a symlink into
    /// Documents and `fileExists` would follow it there.
    nonisolated static func applicationSupportCacheURLs(in appRoot: URL, access: ScanAccess = .full) -> [URL] {
        let fm = FileManager.default
        guard ProtectedLocations.isReadable(appRoot, access: access),
              fm.fileExists(atPath: appRoot.path) else { return [] }

        var results: [URL] = []
        var seen = Set<String>()

        func appendIfExists(_ url: URL, cacheNames: Set<String>? = nil) {
            guard ProtectedLocations.isReadable(url, access: access) else { return }
            let key = url.standardizedFileURL.path
            guard !seen.contains(key), fm.fileExists(atPath: url.path) else { return }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
            if let cacheNames, !isChromiumCacheFolder(url, names: cacheNames) { return }
            seen.insert(key)
            results.append(url.standardizedFileURL)
        }

        if isChromiumDataFolder(appRoot, access: access) {
            for name in applicationSupportDirectCacheNames.sorted() {
                appendIfExists(appRoot.appendingPathComponent(name, isDirectory: true),
                               cacheNames: applicationSupportDirectCacheNames)
            }
        }

        for relative in applicationSupportRelativeCachePaths {
            appendIfExists(appRoot.appendingPathComponent(relative, isDirectory: true))
        }

        let userData = appRoot.appendingPathComponent("User Data", isDirectory: true)
        for url in chromiumUserDataCacheURLs(userData: userData, access: access) {
            appendIfExists(url)
        }

        // Every storage folder further down: a browser's data folder and its
        // profiles, a versioned Figma profile, an Electron session partition (#323).
        let subfolders = subfoldersBelow(appRoot, access: access)
        for storage in nestedChromiumStorageFolders(in: appRoot, access: access, subfolders: subfolders) {
            for name in applicationSupportDirectCacheNames.sorted() {
                appendIfExists(storage.appendingPathComponent(name, isDirectory: true),
                               cacheNames: applicationSupportDirectCacheNames)
            }
        }

        // Crash reports in every Crashpad database, also further down:
        // `com.openai.codex/web/Crashpad`, `Figma/DesktopProfile/v43/Crashpad` (#367).
        for folder in crashpadReportFolders(in: appRoot, access: access, subfolders: subfolders) {
            appendIfExists(folder)
        }

        return results
    }

    /// Cache folders inside a Chromium "User Data" folder that lives outside
    /// Application Support (`DeletionSafetyPolicy.chromiumUserDataStores`): the
    /// cache folders at its root and in each profile, nothing else. Same shape as
    /// `DeletionSafetyPolicy.isWhitelistedChromiumUserDataCachePath`, which is
    /// what makes each one deletable.
    nonisolated static func chromiumUserDataCacheURLs(userData: URL, access: ScanAccess = .full) -> [URL] {
        let fm = FileManager.default
        guard ProtectedLocations.isReadable(userData, access: access),
              fm.fileExists(atPath: userData.path) else { return [] }

        var results: [URL] = []
        var seen = Set<String>()

        func appendIfExists(_ url: URL, cacheNames: Set<String>? = nil) {
            guard ProtectedLocations.isReadable(url, access: access) else { return }
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
            if let cacheNames, !isChromiumCacheFolder(url, names: cacheNames) { return }
            seen.insert(key)
            results.append(url.standardizedFileURL)
        }

        guard isChromiumDataFolder(userData, access: access) else { return [] }
        for name in applicationSupportDirectCacheNames.sorted() {
            appendIfExists(userData.appendingPathComponent(name, isDirectory: true),
                           cacheNames: applicationSupportDirectCacheNames)
        }
        appendChromiumProfileCaches(userData: userData, appendIfExists: appendIfExists)
        return results.sorted { $0.path < $1.path }
    }

    private nonisolated static func appendChromiumProfileCaches(
        userData: URL,
        appendIfExists: (URL, Set<String>?) -> Void
    ) {
        let fm = FileManager.default
        guard let profiles = try? fm.contentsOfDirectory(
            at: userData,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for profileDir in profiles {
            guard (try? profileDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            for name in chromiumProfileCacheNames {
                appendIfExists(profileDir.appendingPathComponent(name, isDirectory: true), chromiumProfileCacheNames)
            }
        }
    }

    /// Default Adobe media cache locations under Application Support.
    ///
    /// Premiere Pro and After Effects park large rendered previews, conformed
    /// audio, and the index that tracks them here — outside `~/Library/Caches`,
    /// so the general Caches sweep never sees them. Only the default `Common`
    /// locations are listed; a project-local or user-chosen scratch cache is
    /// never targeted. `key` doubles as the folder name used for classification
    /// (matched against `explanations.json`).
    nonisolated static let adobeMediaCacheEntries: [(relative: String, headline: String, key: String)] = [
        ("Adobe/Common/Media Cache Files", "Adobe Media Cache Files", "Adobe Media Cache Files"),
        ("Adobe/Common/Media Cache", "Adobe Media Cache Database", "Adobe Media Cache")
    ]

    /// Adobe media cache directories that actually exist on disk. Absent Adobe
    /// folders (app not installed) simply yield nothing — never an error row.
    nonisolated static func adobeMediaCacheURLs(
        home: URL,
        access: ScanAccess = .full
    ) -> [(url: URL, headline: String, key: String)] {
        let fm = FileManager.default
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        var results: [(url: URL, headline: String, key: String)] = []
        for entry in adobeMediaCacheEntries {
            let candidate = appSupport.appendingPathComponent(entry.relative, isDirectory: true)
            guard ProtectedLocations.isReadable(candidate, access: access) else { continue }
            let url = candidate.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            results.append((url, entry.headline, entry.key))
        }
        return results
    }

    /// Fixed-location caches outside `~/Library/Caches` that App Caches lists, each
    /// classified by `key` against `explanations.json`. `needsFullAccess` marks the
    /// ones inside folders a limited scan must not open (Messages, Mail's container).
    nonisolated static let knownCacheEntries: [(relative: String, key: String, needsFullAccess: Bool)] = [
        ("Library/iTunes/iPhone Software Updates", "Device Software Updates", false),
        ("Library/iTunes/iPad Software Updates", "Device Software Updates", false),
        ("Library/iTunes/iPod Software Updates", "Device Software Updates", false),
        ("Movies/CacheClip", "CacheClip", false),
        ("Library/Application Support/com.apple.wallpaper/aerials/videos", "Aerial Wallpaper Videos", false),
        ("Library/Messages/Caches/Previews", "Messages Previews", true),
        ("Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "Mail Downloads", true)
    ]

    /// Classification name for every electron-updater download folder. They are
    /// named after the app (`t3code-updater`, `@opencode-aidesktop-updater`), so
    /// they share one entry and show as one row.
    nonisolated static let electronUpdaterKey = "Electron Updater Downloads"

    /// A `~/Library/Caches/<app>-updater` folder with electron-updater's `pending`
    /// download folder inside. The name alone is not enough to call it one.
    nonisolated static func isElectronUpdaterCache(_ directory: URL) -> Bool {
        guard directory.lastPathComponent.lowercased().hasSuffix("-updater") else { return false }
        var isDir: ObjCBool = false
        let pending = directory.appendingPathComponent("pending", isDirectory: true)
        return FileManager.default.fileExists(atPath: pending.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Unfinished downloads directly in ~/Downloads that have not changed for this
    /// long. A browser still downloading touches the file far more often.
    nonisolated static let unfinishedDownloadMinimumAge: TimeInterval = 7 * 24 * 60 * 60

    nonisolated static let unfinishedDownloadsKey = "Unfinished Downloads"

    nonisolated static func unfinishedDownloadURLs(home: URL, now: Date = Date()) -> [URL] {
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: downloads,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            let ext = url.pathExtension.lowercased()
            guard DeletionSafetyPolicy.unfinishedDownloadExtensions.contains(ext) else {
                return false
            }
            // A folder's own date doesn't change when a file inside it does, and
            // only Safari writes a download as a folder.
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory, !DeletionSafetyPolicy.unfinishedDownloadFolderExtensions.contains(ext) {
                return false
            }
            let modified = FolderSizing.contentModificationDate(at: url)
            return now.timeIntervalSince(modified) >= unfinishedDownloadMinimumAge
        }
        .map(\.standardizedFileURL)
        .sorted { $0.path < $1.path }
    }

    /// Telegram's native macOS app parks auto-downloaded photos, videos, and
    /// files inside its Group Container rather than `~/Library/Caches`, so the
    /// broad Caches sweep never reaches them. Only the `postbox/media` directory
    /// is ever targeted — never `postbox` itself, which holds the account
    /// database whose removal would log the user out or lose local data. The
    /// optional leading segment covers the distribution channel (stable,
    /// appstore, and any future channel); `account-*` covers every signed-in
    /// account. The match still terminates at `postbox/media` exactly.
    nonisolated static let telegramGroupContainerRelative =
        "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram"

    /// Folder name used for classification (matched against `explanations.json`)
    /// and the headline shown in the list.
    nonisolated static let telegramMediaCacheKey = "Telegram Media Cache"

    /// Existing `.../[channel/]account-*/postbox/media` directories across all
    /// distribution channels and signed-in accounts. Absent folders (Telegram
    /// not installed) simply yield nothing — never an error row.
    nonisolated static func telegramMediaCacheURLs(
        home: URL
    ) -> [(url: URL, headline: String, key: String)] {
        let fm = FileManager.default
        let root = home.appendingPathComponent(telegramGroupContainerRelative, isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return [] }

        func subdirectories(of dir: URL, namePrefix: String? = nil) -> [URL] {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return entries.filter { url in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    return false
                }
                if let namePrefix { return url.lastPathComponent.hasPrefix(namePrefix) }
                return true
            }
        }

        // `account-*` — one directory per signed-in account. Accounts usually sit
        // under a distribution channel dir (stable, appstore, any future channel),
        // but some installs place them straight at the container root.
        var accountDirs = subdirectories(of: root, namePrefix: "account-")
        for channelDir in subdirectories(of: root)
        where !channelDir.lastPathComponent.hasPrefix("account-") {
            accountDirs.append(contentsOf: subdirectories(of: channelDir, namePrefix: "account-"))
        }

        var results: [(url: URL, headline: String, key: String)] = []
        for accountDir in accountDirs {
            let media = accountDir
                .appendingPathComponent("postbox", isDirectory: true)
                .appendingPathComponent("media", isDirectory: true)
                .standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: media.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            results.append((media, telegramMediaCacheKey, telegramMediaCacheKey))
        }
        return results
    }

    /// Lists each app container's caches folder once, one after another, and
    /// keeps nothing: see the full scan's first step in `PurgeStore`. A look-up
    /// alone (`lstat`) was not enough: the stalls came back.
    nonisolated static func touchContainerCaches(home: URL) {
        _ = containerCacheURLs(home: home)
    }

    /// Enumerates cache paths under `~/Library/Containers/<bundleID>/Data/Library/Caches`.
    nonisolated static func containerCacheURLs(home: URL) -> [URL] {
        let containersRoot = home.appendingPathComponent("Library/Containers", isDirectory: true)
        let fm = FileManager.default
        guard let bundleDirs = try? fm.contentsOfDirectory(
            at: containersRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for bundleDir in bundleDirs {
            let bundleID = bundleDir.lastPathComponent
            guard !DeletionSafetyPolicy.isProtectedContainerBundleID(bundleID) else { continue }
            let cachesRoot = bundleDir
                .appendingPathComponent("Data/Library/Caches", isDirectory: true)
            // Other scans may be reading inside the containers at the same time.
            let listing: [URL]?? = ContainerAccessGate.access(cachesRoot.path) {
                guard fm.fileExists(atPath: cachesRoot.path) else { return nil }
                return .some(try? fm.contentsOfDirectory(
                    at: cachesRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ))
            }
            guard let listing else { continue }

            if let children = listing, !children.isEmpty {
                let subdirs = children.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                if subdirs.isEmpty {
                    results.append(cachesRoot.standardizedFileURL)
                } else {
                    results.append(contentsOf: subdirs.map { $0.standardizedFileURL })
                }
            } else {
                results.append(cachesRoot.standardizedFileURL)
            }
        }
        return results
    }

    /// Classification key and folder name for full macOS installer apps.
    nonisolated static let macOSInstallerKey = "macOS Installer"

    /// Classification key and folder name for the entries a finished macOS update
    /// left in `macOS Install Data` (#127). Found by `MacOSInstallLeftovers`.
    nonisolated static let macOSInstallDataKey = "macOS Install Data"

    /// `/Applications/Install macOS <Name>.app` bundles whose bundle ID is Apple's
    /// InstallAssistant. The name alone is not enough: any app can be called that.
    nonisolated static func macOSInstallerURLs(applications: URL = URL(fileURLWithPath: "/Applications")) -> [URL] {
        let fm = FileManager.default
        guard let apps = try? fm.contentsOfDirectory(
            at: applications,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return apps
            .filter { DeletionSafetyPolicy.isMacOSInstallerAppName($0.lastPathComponent) }
            .filter { DeletionSafetyPolicy.isMacOSInstallerBundle(at: $0) }
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
    }

    /// Chromium browsers whose bundles keep old framework versions after an update.
    /// The framework is `<Browser> Framework.framework` in each (Chrome, Brave, Edge
    /// and Chromium each use their own name), found by `chromiumFrameworkVersionsDir`.
    nonisolated static let chromiumBrowserAppNames: [String] = [
        "Google Chrome.app",
        "Google Chrome Beta.app",
        "Google Chrome Dev.app",
        "Google Chrome Canary.app",
        "Chromium.app",
        "Arc.app",
        "Brave Browser.app",
        "Microsoft Edge.app",
        "Vivaldi.app"
    ]

    /// `Contents/Frameworks/<Name> Framework.framework/Versions` inside a browser
    /// bundle: the one Chromium framework, whose versioned folders pile up.
    nonisolated static func chromiumFrameworkVersionsDir(in appURL: URL) -> URL? {
        let frameworks = appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else {
            return nil
        }
        guard let name = entries.sorted().first(where: { DeletionSafetyPolicy.isChromiumFrameworkName($0) }) else {
            return nil
        }
        return frameworks
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("Versions", isDirectory: true)
    }

    /// The browser a framework version folder belongs to, `Google Chrome` for
    /// `…/Google Chrome.app/Contents/Frameworks/…/Versions/155.0`. Walks up to the
    /// `.app` rather than counting folders, so a row never reads "Contents Old Version".
    nonisolated static func chromiumBrowserAppName(forFrameworkVersion versionURL: URL) -> String {
        var url = versionURL.standardizedFileURL
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension == "app" {
                return url.deletingPathExtension().lastPathComponent
            }
        }
        // Not inside a bundle: name the framework instead of a folder like `Contents`.
        let framework = versionURL.deletingLastPathComponent().deletingLastPathComponent()
        return framework.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " Framework", with: "")
    }

    /// Stale Chromium framework versions inside `.app` bundles (not the `Current` symlink target).
    /// Versions a running browser is still executing from are dropped later by
    /// `DeletionSafetyPolicy.staleBrowserFrameworkRefusesDeletion`.
    nonisolated static func staleChromiumFrameworkVersionURLs() -> [URL] {
        let fm = FileManager.default

        var results: [URL] = []
        for appName in chromiumBrowserAppNames {
            let appURL = URL(fileURLWithPath: "/Applications/\(appName)", isDirectory: true)
            guard fm.fileExists(atPath: appURL.path) else { continue }
            guard let versionsDir = chromiumFrameworkVersionsDir(in: appURL),
                  fm.fileExists(atPath: versionsDir.path) else { continue }

            let currentLink = versionsDir.appendingPathComponent("Current", isDirectory: false)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) else { continue }
            let currentResolved = URL(fileURLWithPath: dest, relativeTo: versionsDir).lastPathComponent

            guard let versionDirs = try? fm.contentsOfDirectory(
                at: versionsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for versionDir in versionDirs {
                let name = versionDir.lastPathComponent
                if name == "Current" { continue }
                if (try? versionDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true { continue }
                if name == currentResolved { continue }
                results.append(versionDir.standardizedFileURL)
            }
        }
        return results
    }
}

import Darwin
import Foundation

/// Playwright browser builds no installed Playwright uses (#328).
///
/// Playwright keeps every browser it downloads in `ms-playwright`, one folder
/// per build (`chromium-1194`, `chromium_headless_shell-1194`, `ffmpeg-1011`).
/// Each copy of `playwright-core` that installs browsers writes one file to
/// `ms-playwright/.links`, named for the SHA-1 of its folder and holding that
/// folder's path. The copy's `browsers.json` names the builds it runs. On every
/// install Playwright deletes the build folders no link names
/// (`_validateInstallationCache` in playwright-core, checked in 1.65.0). Purge
/// applies the same rule without running Playwright, and keeps more than
/// Playwright does:
///
/// - Every build stays while anything is unclear: `.links` is missing, empty or
///   can't be listed, a link file can't be read, it names a folder that isn't
///   there (a project on an unplugged drive, a deleted copy), or that folder's
///   `browsers.json` can't be read or parsed. Playwright drops such a link and
///   deletes the builds only it named. Purge can't tell those builds apart.
/// - A `browsers.json` in Desktop, Documents or another protected folder is read
///   only with Full Disk Access. Without it every build stays.
/// - Every build stays while `__dirlock` is under an hour old. Playwright holds it
///   while it writes a link and downloads.
/// - Only folders named `<browser>-<revision>`, for a browser Playwright has ever
///   downloaded, are offered. `.links`, `__dirlock`, the folder itself and
///   anything else in it are refused.
///
/// Python, Java and .NET Playwright install through the same Node driver, so they
/// write links too. Java unpacks its driver into a temporary folder for each
/// run, so its link soon names a folder that is gone, and every build stays.
///
/// `PLAYWRIGHT_BROWSERS_PATH` is ignored. Only the default folders are looked at.
///
/// The row is Check First. `isWhitelistedPath` proves only the shape, for
/// `evaluate`. `refusesDeletion` reads the links again, from
/// `isOfferedForCleanup`, which `FileDeleter` asks before every move.
nonisolated enum PlaywrightBuildScanPolicy {

    static let label = "Unused Playwright Browsers"
    static let explanationKey = "playwright-unused-builds"

    /// Where Playwright keeps browsers on a Mac, and the Linux spelling, relative
    /// to home.
    static let roots = ["Library/Caches/ms-playwright", ".cache/ms-playwright"]

    /// Playwright's `allDownloadableDirectoriesThatEverExisted`, with dashes as
    /// underscores, as its folder names spell them. A folder for any other name
    /// is never offered, as Playwright never deletes one either.
    static let browserFolderNames: Set<String> = [
        "android",
        "chromium",
        "chromium_headless_shell",
        "chromium_tip_of_tree",
        "chromium_tip_of_tree_headless_shell",
        "ffmpeg",
        "firefox",
        "firefox_beta",
        "webkit",
        "winldd"
    ]

    static let linksFolder = ".links"
    /// Playwright's install lock.
    static let lockName = "__dirlock"
    /// A lock is refreshed every few seconds while Playwright holds it. One older
    /// than this was left by an install that was killed.
    static let lockLifetime: TimeInterval = 60 * 60
    /// Finder may leave this in `.links`. It never names a Playwright copy.
    static let finderMetadataName = ".DS_Store"

    // MARK: Shape

    /// The root `path` sits directly in when it is a build folder. Nil for every
    /// other path, including the root itself and anything inside a build.
    static func buildRoot(of path: String, home: String) -> String? {
        for relative in roots {
            let root = "\(home)/\(relative)"
            if let name = OldToolVersionScanPolicy.onlyChild(path, of: root), isBuildFolderName(name) {
                return root
            }
        }
        return nil
    }

    static func isWhitelistedPath(_ path: String, home: String) -> Bool {
        buildRoot(of: path, home: home) != nil
    }

    /// `chromium-1194`, `chromium_headless_shell-1194`, `ffmpeg-1011`. The
    /// `_special` builds Playwright keeps for older macOS versions
    /// (`webkit_mac14_arm64_special-2251`) don't match, so they always stay.
    static func isBuildFolderName(_ name: String) -> Bool {
        guard let dash = name.lastIndex(of: "-") else { return false }
        let browser = String(name[..<dash])
        let revision = name[name.index(after: dash)...]
        return browserFolderNames.contains(browser)
            && !revision.isEmpty && revision.count <= 9
            && revision.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The root `path` is or sits in, compared without case since the Mac's disk
    /// ignores it.
    static func containingRoot(of path: String, home: String) -> String? {
        let lowered = path.lowercased()
        return roots.map { "\(home)/\($0)" }.first { PathContainment.isSameOrInside(lowered, $0.lowercased()) }
    }

    // MARK: Delete-time gate

    /// True for every path in a Playwright folder that isn't a build no link
    /// names now: the folder itself, `.links`, `__dirlock`, anything inside a
    /// build, and a build in use or whose use can't be read. False for paths
    /// outside the folders, which other rules judge.
    static func refusesDeletion(
        _ url: URL,
        home: String = DeletionSafetyPolicy.cachedHomePath,
        now: Date = Date(),
        access: ScanAccess? = nil
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard let root = containingRoot(of: path, home: home) else { return false }
        guard buildRoot(of: path, home: home) == root else { return true }
        return !isOffered(path, root: root, home: home, now: now, access: access)
    }

    static func isOffered(_ path: String, root: String, home: String, now: Date, access: ScanAccess?) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard !PathContainment.containsSymlinkComponent(url, home: home),
              OldToolVersionScanPolicy.isRealFolder(path),
              let used = usedBuildFolders(root: root, home: home, now: now, access: access) else { return false }
        return !used.contains(url.lastPathComponent.lowercased())
    }

    // MARK: Disk reads

    /// The build folder names, in lowercase, that some link's `browsers.json`
    /// names. Nil, which keeps every build, when an install may be under way or
    /// any link can't be followed to a `browsers.json` Purge can parse.
    static func usedBuildFolders(root: String, home: String, now: Date, access: ScanAccess?) -> Set<String>? {
        var info = stat()
        if lstat("\(root)/\(lockName)", &info) == 0 {
            let changed = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if changed > now.addingTimeInterval(-lockLifetime) { return nil }
        } else if errno != ENOENT {
            return nil
        }

        let links = "\(root)/\(linksFolder)"
        guard OldToolVersionScanPolicy.isRealFolder(links),
              let names = try? FileManager.default.contentsOfDirectory(atPath: links) else { return nil }
        let linkNames = names.filter { $0 != finderMetadataName }
        // No link at all says nothing about who uses the builds.
        guard !linkNames.isEmpty else { return nil }

        // Full Disk Access is checked once, and only when a link leads into a
        // protected folder.
        var resolvedAccess = access
        func mayRead(_ file: String) -> Bool {
            let homeURL = URL(fileURLWithPath: home, isDirectory: true)
            if ProtectedLocations.isReadable(URL(fileURLWithPath: file), access: .limited, home: homeURL) {
                return true
            }
            if resolvedAccess == nil { resolvedAccess = ScanAccess.current() }
            return resolvedAccess == .full
        }

        var used: Set<String> = []
        for name in linkNames {
            guard let target = linkTarget(at: "\(links)/\(name)") else { return nil }
            let file = URL(fileURLWithPath: target, isDirectory: true)
                .appendingPathComponent("browsers.json").standardizedFileURL.path
            guard mayRead(file), let data = readSmallFile(file),
                  let folders = buildFolders(inBrowsersJSON: data) else { return nil }
            used.formUnion(folders)
        }
        return used
    }

    /// The folder a link file names. Playwright writes the path and nothing else.
    /// Nil for anything that isn't a small regular file holding one absolute path.
    static func linkTarget(at file: String) -> String? {
        var info = stat()
        guard lstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 4096,
              let data = FileManager.default.contents(atPath: file),
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("/"),
              !text.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
        return text
    }

    /// A regular file's contents, following links as Playwright does. Nil when it
    /// is missing, not a regular file, larger than any `browsers.json`, or only in
    /// iCloud, where reading it would wait for a download.
    static func readSmallFile(_ path: String) -> Data? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= 1_000_000,
              info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// The build folders a `browsers.json` names, in lowercase. Playwright's
    /// folder for an entry is its name with dashes as underscores, a dash, and the
    /// revision. On a Mac with a revision override it is
    /// `<name>_<platform>_special-<revision>`. Every override is kept, whatever Mac
    /// this is, and so is `<name>-<revision>` for it. Nil when the file is not the
    /// shape Playwright writes.
    static func buildFolders(inBrowsersJSON data: Data) -> Set<String>? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let browsers = object["browsers"] as? [[String: Any]] else { return nil }
        func folder(_ prefix: String, _ revision: String) -> String {
            "\(prefix.replacingOccurrences(of: "-", with: "_"))-\(revision)".lowercased()
        }
        var folders: Set<String> = []
        for browser in browsers {
            guard let name = browser["name"] as? String, !name.isEmpty,
                  let revision = browser["revision"] as? String, !revision.isEmpty else { return nil }
            folders.insert(folder(name, revision))
            guard let rawOverrides = browser["revisionOverrides"] else { continue }
            guard let overrides = rawOverrides as? [String: String] else { return nil }
            for (platform, override) in overrides {
                folders.insert(folder("\(name)_\(platform)_special", override))
                folders.insert(folder(name, override))
            }
        }
        return folders
    }

    // MARK: Scan

    /// One row listing the build folders no link names, across both folders.
    /// A folder the limited scan can't read without a prompt is skipped, and so
    /// is one reached through a link.
    static func definitions(
        home: URL,
        access: ScanAccess,
        now: Date = Date()
    ) -> [(label: String, paths: [URL])] {
        let homePath = home.standardizedFileURL.path
        var builds: [URL] = []
        for relative in roots {
            let root = "\(homePath)/\(relative)"
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard ProtectedLocations.isReadable(rootURL, access: .limited, home: home),
                  !PathContainment.containsSymlinkComponent(rootURL, home: homePath),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: root),
                  names.contains(where: isBuildFolderName),
                  let used = usedBuildFolders(root: root, home: homePath, now: now, access: access) else { continue }
            builds += names
                .filter { isBuildFolderName($0) && !used.contains($0.lowercased()) }
                .filter { OldToolVersionScanPolicy.isRealFolder("\(root)/\($0)") }
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
                .map { URL(fileURLWithPath: "\(root)/\($0)", isDirectory: true) }
        }
        return builds.isEmpty ? [] : [(label, builds)]
    }
}

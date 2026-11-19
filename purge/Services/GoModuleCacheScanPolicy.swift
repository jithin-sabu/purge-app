import Darwin
import Foundation
import os

/// Go's module cache, offered whole (#397).
///
/// `go/pkg/mod/cache` holds only the downloaded zips. The unpacked source sits
/// beside it in `go/pkg/mod/<module>@<version>`, which is where the space goes,
/// so the row offers the whole folder. It is Check First: the next build
/// downloads every module again, and private or offline modules fail until then.
///
/// The folder comes from `GOMODCACHE`, else the first `GOPATH` entry plus
/// `pkg/mod`, else `~/go/pkg/mod`, the same order Go uses. A value missing from
/// Purge's environment is read from launchd and then from Go's own env file
/// (what `go env -w` writes), since Purge never sees a shell profile.
///
/// The whole folder is offered only when it looks like a module cache and
/// nothing else: `cache/download` inside it, and every other entry a folder
/// named after a module path's first element, which always has a dot
/// (`github.com`, `golang.org`). So `GOMODCACHE` naming `GOPATH`, with the
/// user's `src` in it, is never offered whole. Otherwise only `cache` is.
///
/// Go makes each unpacked module folder read-only. Moved to the Trash like
/// that, the Trash could not be emptied, so right before the move Purge gives
/// the owner write permission on each folder, as `go clean -modcache` does.
nonisolated enum GoModuleCacheScanPolicy {
    /// The cache Purge last found, and whether it is offered whole.
    struct Snapshot: Equatable, Sendable {
        var root: String
        var isWholeCache: Bool
    }

    /// The environment and home a test reads from instead of the real ones,
    /// with its own snapshot.
    final class TestContext: @unchecked Sendable {
        let environment: [String: String]
        let home: URL
        let excludedPaths: Set<String>
        fileprivate let stored = OSAllocatedUnfairLock<Snapshot?>(initialState: nil)

        init(environment: [String: String] = [:], home: URL, excludedPaths: Set<String> = []) {
            self.environment = environment
            self.home = home
            self.excludedPaths = excludedPaths
        }
    }

    @TaskLocal static var testContext: TestContext?

    static let label = "Go Module Cache"
    static let explanationKey = "go"

    private static let log = Logger(subsystem: "io.getpurge.app", category: "GoModuleCache")

    // MARK: Finding the folder

    /// Where Go keeps its module cache, from `environment` and then Go's env
    /// file. Nil when the value Go would use is not an absolute path, which Go
    /// itself refuses.
    static func configuredRoot(
        environment: [String: String],
        home: URL,
        envFile: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) -> URL? {
        let fileValues = goEnvFileValues(environment: environment, home: home, read: envFile)
        func value(_ name: String) -> String? {
            if let set = environment[name], !set.isEmpty { return set }
            if let set = fileValues[name], !set.isEmpty { return set }
            return nil
        }
        if let modCache = value("GOMODCACHE") {
            return absoluteFolder(modCache)
        }
        if let goPath = value("GOPATH") {
            guard let first = goPath.split(separator: ":", omittingEmptySubsequences: false).first,
                  let base = absoluteFolder(String(first)) else { return nil }
            return base.appendingPathComponent("pkg/mod", isDirectory: true)
        }
        return home.appendingPathComponent("go/pkg/mod", isDirectory: true).standardizedFileURL
    }

    /// `KEY=value` lines from the file `go env -w` writes:
    /// `~/Library/Application Support/go/env`, or `GOENV` when it names
    /// another file. `GOENV=off` turns the file off, as it does for Go.
    static func goEnvFileValues(
        environment: [String: String],
        home: URL,
        read: (URL) -> String?
    ) -> [String: String] {
        let file: URL
        if let goEnv = environment["GOENV"], !goEnv.isEmpty {
            guard goEnv != "off", let url = absoluteFile(goEnv) else { return [:] }
            file = url
        } else {
            file = home.appendingPathComponent("Library/Application Support/go/env")
        }
        guard let text = read(file) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            values[String(trimmed[..<equals])] = String(trimmed[trimmed.index(after: equals)...])
        }
        return values
    }

    private static func absoluteFolder(_ value: String) -> URL? {
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }

    private static func absoluteFile(_ value: String) -> URL? {
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    // MARK: Judging the folder

    /// Whether `root` is somewhere a Go module cache may be offered from at
    /// all: a real local folder with `cache/download` in it, reached through
    /// no link, not `/`, home or above it, not under a never-delete location,
    /// and not in a folder a sync service keeps, where a move to the Trash is a
    /// delete on every device.
    static func acceptsLocation(_ root: URL, home: URL) -> Bool {
        let path = root.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard path.hasPrefix("/"), path != "/", !PathContainment.isSameOrInside(homePath, path) else { return false }

        let inHome = PathContainment.isInside(path, homePath)
        // `evaluate` reaches its shape rules before the never-delete list, so
        // this rule checks the list itself. A test's home sits under `/var`,
        // so inside home only the home folder's own entries apply.
        let refused = DeletionSafetyPolicy.neverDeletePrefixes(home: homePath)
            .filter { !inHome || PathContainment.isSameOrInside($0, homePath) }
            + ["\(homePath)/Library/Mobile Documents", "\(homePath)/Library/CloudStorage"]
        if refused.contains(where: { PathContainment.isSameOrInside(path, $0) }) { return false }

        if inHome {
            if PathContainment.containsSymlinkComponent(root, home: homePath) { return false }
        } else if containsLinkFromRoot(path) {
            return false
        }
        guard isRealFolder(path), isRealFolder(path + "/cache"), isRealFolder(path + "/cache/download") else {
            return false
        }
        guard AppFolders.isOnLocalDisk(root) else { return false }

        var folder = root.standardizedFileURL
        while folder.path != "/" {
            if AppFolders.isSyncedByAnotherService(folder) { return false }
            folder.deleteLastPathComponent()
        }
        return true
    }

    /// Whether everything in `root` is Go's: `cache`, and folders named after
    /// a module path's first element, which always has a dot. `.DS_Store` is
    /// Finder's. A link, a file, a hidden entry or a name like `src` means the
    /// folder holds more than modules. A folder the user excluded inside it
    /// keeps the whole folder from being offered too.
    static func holdsOnlyModules(_ root: URL, excludedPaths: Set<String>) -> Bool {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath().path
        if excludedPaths.contains(where: { PathContainment.isInside($0, canonical) }) { return false }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return false }
        for entry in entries {
            let name = entry.lastPathComponent
            if name == ".DS_Store" { continue }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            guard values?.isSymbolicLink != true, values?.isDirectory == true else { return false }
            if name == "cache" { continue }
            guard !name.hasPrefix("."), name.contains(".") else { return false }
        }
        return true
    }

    /// Reads the folder from disk. Nil when there is no folder Purge may offer
    /// anything from. `insideHomeOnly` is for a scan without Full Disk Access,
    /// which must not read a drive outside home.
    static func read(
        environment: [String: String],
        home: URL,
        excludedPaths: Set<String>,
        insideHomeOnly: Bool
    ) -> Snapshot? {
        guard let root = configuredRoot(environment: environment, home: home) else { return nil }
        let homePath = home.standardizedFileURL.path
        if insideHomeOnly, !PathContainment.isInside(root.path, homePath) { return nil }
        guard acceptsLocation(root, home: home) else { return nil }
        return Snapshot(root: root.path, isWholeCache: holdsOnlyModules(root, excludedPaths: excludedPaths))
    }

    // MARK: Snapshot

    /// The folder as last read, for `DeletionSafetyPolicy.evaluate` and the
    /// Dev Tools row list, which never read the disk for it. Refreshed at the
    /// start of each Dev Tools scan and each clean. Nil in the test host until
    /// a test binds `testContext` and refreshes.
    static var snapshot: Snapshot? {
        if let testContext { return testContext.stored.withLock { $0 } }
        return store.withLock { $0 }
    }

    /// Reads the folder again. Off the main thread: it runs `launchctl` and
    /// lists the folder. The test host never reads the real one.
    @discardableResult
    static func refreshSnapshot(insideHomeOnly: Bool = false) -> Snapshot? {
        let read: Snapshot?
        if let testContext {
            read = Self.read(
                environment: testContext.environment,
                home: testContext.home,
                excludedPaths: testContext.excludedPaths,
                insideHomeOnly: insideHomeOnly
            )
            testContext.stored.withLock { $0 = read }
        } else {
            guard !RemovedAppHandoff.runsInTestHost else { return snapshot }
            LaunchdEnvironment.refresh()
            read = Self.read(
                environment: liveEnvironment,
                home: FileManager.default.homeDirectoryForCurrentUser,
                excludedPaths: ExcludedPathsStore.allExcludedPaths(),
                insideHomeOnly: insideHomeOnly
            )
            let changed = store.withLock { stored -> Bool in
                defer { stored = read }
                return stored != read
            }
            if !changed { return read }
        }
        // `evaluate` reads the snapshot, so verdicts cached before it changed
        // are stale.
        DeletionSafetyPolicy.clearOfferedForCleanupCache()
        return read
    }

    /// Purge's own environment, with the Go names filled in from launchd.
    static var liveEnvironment: [String: String] {
        LaunchdEnvironment.merged(into: ProcessInfo.processInfo.environment)
    }

    private static let store = OSAllocatedUnfairLock<Snapshot?>(initialState: nil)

    // MARK: Row and gates

    /// The paths the Go Module Cache row offers: the whole folder when it
    /// holds only modules, else its `cache`. Never both, so nothing is counted
    /// twice. With no folder read, `~/go/pkg/mod/cache` as before.
    static func rowPaths(home: URL) -> [URL] {
        guard let snapshot else {
            return [home.appendingPathComponent("go/pkg/mod/cache", isDirectory: true)]
        }
        let root = URL(fileURLWithPath: snapshot.root, isDirectory: true)
        return snapshot.isWholeCache ? [root] : [root.appendingPathComponent("cache", isDirectory: true)]
    }

    /// Shape only, for `evaluate`: the folder itself when it was found to hold
    /// only modules, and its `cache` and below. Never one module folder on its
    /// own, and never the folders above it.
    static func isWhitelistedPath(_ path: String) -> Bool {
        guard let snapshot else { return false }
        if path == snapshot.root { return snapshot.isWholeCache }
        return PathContainment.isSameOrInside(path, snapshot.root + "/cache")
    }

    /// Whether `url` is the whole module cache as last read.
    static func isWholeCacheRoot(_ url: URL) -> Bool {
        guard let snapshot, snapshot.isWholeCache else { return false }
        return url.standardizedFileURL.path == snapshot.root
    }

    /// Checked before every move of the whole folder. Off the main thread the
    /// folder is found and judged again from disk, so a `src` folder added
    /// since the scan, or `GOMODCACHE` moved elsewhere, stops the move. The
    /// Dev Tools filter asks on the main thread on every scan flush and takes
    /// the scan's answer.
    static func refusesDeletion(_ url: URL, reuseRecentRead: Bool = false) -> Bool {
        guard let snapshot else { return false }
        let path = url.standardizedFileURL.path
        guard path == snapshot.root else { return false }
        guard snapshot.isWholeCache else { return true }
        if reuseRecentRead { return false }
        let current: Snapshot?
        if let testContext {
            current = read(
                environment: testContext.environment,
                home: testContext.home,
                excludedPaths: testContext.excludedPaths,
                insideHomeOnly: false
            )
        } else {
            current = read(
                environment: liveEnvironment,
                home: FileManager.default.homeDirectoryForCurrentUser,
                excludedPaths: ExcludedPathsStore.allExcludedPaths(),
                insideHomeOnly: false
            )
        }
        return current != snapshot
    }

    // MARK: Before the move

    /// Gives the owner write permission on every folder under `root` that
    /// lacks it, so the Trash can be emptied. Files are left alone: removing
    /// a file needs write permission on its folder, not on the file. Links are
    /// never followed and other volumes never entered. False when any folder
    /// could not be read or changed; the caller then leaves the cache where it is.
    static func makeFoldersWritable(in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        var rootInfo = stat()
        guard lstat(rootPath, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else { return false }
        let device = rootInfo.st_dev
        let user = getuid()
        var allWritable = true

        func makeWritable(_ path: String, _ info: stat) {
            guard info.st_uid == user else {
                // Another account's folder, such as one `sudo go` made. Purge
                // can't change it, and the Trash couldn't empty it.
                if access(path, W_OK) != 0 { allWritable = false }
                return
            }
            guard info.st_mode & S_IWUSR == 0 else { return }
            if fchmodat(AT_FDCWD, path, (info.st_mode & 0o7777) | S_IWUSR, AT_SYMLINK_NOFOLLOW) != 0 {
                allWritable = false
                log.error("Could not make a Go module folder writable: errno \(errno, privacy: .public)")
            }
        }

        makeWritable(rootPath, rootInfo)
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: rootPath, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in
                allWritable = false
                return true
            }
        ) else { return false }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                allWritable = false
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                enumerator.skipDescendants()
                continue
            }
            guard info.st_dev == device else {
                enumerator.skipDescendants()
                allWritable = false
                continue
            }
            makeWritable(url.path, info)
        }
        return allWritable
    }

    // MARK: Helpers

    private static func isRealFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// True when any folder from `/` down to `path` is a link.
    private static func containsLinkFromRoot(_ path: String) -> Bool {
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            var info = stat()
            guard lstat(current, &info) == 0 else { return true }
            if (info.st_mode & S_IFMT) == S_IFLNK { return true }
        }
        return false
    }
}

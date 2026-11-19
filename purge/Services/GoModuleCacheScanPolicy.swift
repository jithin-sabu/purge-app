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
/// The whole folder is offered only with positive evidence that everything in
/// it is Go's: below every entry other than `cache`, only folders that
/// lead down to unpacked modules (`<path>@<version>`). A file, a link, a hidden
/// entry or a version-control folder on the way means the folder holds more,
/// such as the user's own checkouts under `github.com/me/repo`, and then only
/// `cache` is offered.
///
/// Go makes each unpacked module folder read-only. Moved to the Trash like
/// that, the Trash could not be emptied, so right before the move Purge gives
/// the owner write permission on each folder, as `go clean -modcache` does.
nonisolated enum GoModuleCacheScanPolicy {
    /// The cache Purge last found, and what its row offers.
    struct Snapshot: Equatable, Sendable {
        enum Offer: Equatable, Sendable {
            /// The whole folder: everything in it is Go's.
            case wholeCache
            /// Only `<root>/cache`: the folder holds something else too.
            case downloadsOnly
            /// Nothing: an exclusion sits inside `cache`, or another rule
            /// already offers a folder that holds the cache.
            case nothing
        }

        var root: String
        var offer: Offer
        /// Read by a scan without Full Disk Access, which never looks inside
        /// a protected folder or outside home. A move reads it the same way.
        var limited: Bool

        var isWholeCache: Bool { offer == .wholeCache }
    }

    /// The environment and home a test reads from instead of the real ones,
    /// with its own snapshot. The environment can change, as `GOMODCACHE` can
    /// between a scan and a clean.
    final class TestContext: @unchecked Sendable {
        let home: URL
        let excludedPaths: Set<String>
        fileprivate let stored = OSAllocatedUnfairLock<State>(initialState: State())
        private let environmentStore: OSAllocatedUnfairLock<[String: String]>

        init(environment: [String: String] = [:], home: URL, excludedPaths: Set<String> = []) {
            self.environmentStore = OSAllocatedUnfairLock(initialState: environment)
            self.home = home
            self.excludedPaths = excludedPaths
        }

        var environment: [String: String] {
            get { environmentStore.withLock { $0 } }
            set { environmentStore.withLock { $0 = newValue } }
        }
    }

    @TaskLocal static var testContext: TestContext?

    /// Set while `read` asks `evaluate` whether another rule offers a folder,
    /// so the answer leaves this rule out.
    @TaskLocal private static var judgingOtherRules = false

    /// The folders `makeFoldersWritable` just gave write permission, by inode
    /// number, so any spelling of their path matches. They were read-only,
    /// which is Go's evidence, so the check right before the move still
    /// counts them as Go's.
    @TaskLocal static var foldersMadeWritable: Set<UInt64> = []

    static let label = "Go Module Cache"
    static let explanationKey = "go"

    private static let log = Logger(subsystem: "io.getpurge.app", category: "GoModuleCache")

    // MARK: Finding the folder

    /// Where Go keeps its module cache, from `environment` and then Go's env
    /// file. Nil when the value Go would use is not an absolute path, which Go
    /// itself refuses. Paths are tidied as text only, never by asking the
    /// disk, which could follow a link into a protected folder. `canRead`
    /// says whether the env file may be opened at all.
    static func configuredRoot(
        environment: [String: String],
        home: URL,
        canRead: (URL) -> Bool = { _ in true },
        envFile: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) -> URL? {
        let fileValues = goEnvFileValues(environment: environment, home: home) { file in
            canRead(file) ? envFile(file) : nil
        }
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
        return absoluteFolder(home.path + "/go/pkg/mod")
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
            file = URL(fileURLWithPath: lexicalPath(home.path + "/Library/Application Support/go/env"), isDirectory: false)
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
        return URL(fileURLWithPath: lexicalPath(value), isDirectory: true)
    }

    private static func absoluteFile(_ value: String) -> URL? {
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: lexicalPath(value), isDirectory: false)
    }

    /// `path` without `.`, `..` or doubled slashes, worked out as text.
    static func lexicalPath(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                _ = parts.popLast()
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    // MARK: Judging the folder

    /// System locations no module cache is offered from. `/System` and
    /// `/private` also catch another spelling of a folder elsewhere:
    /// `/System/Volumes/Data/Users/...` is the home folder, and
    /// `/private/var/...` is `/var`, reached without any link.
    static let refusedSystemPrefixes = ["/System", "/private", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var", "/cores", "/dev"]

    /// Whether `path` is somewhere the row may never sit, by its spelling
    /// alone: home or above it, a never-delete folder or one of the exact
    /// folders `evaluate` refuses, iCloud Drive or a cloud-storage folder, or
    /// a system location. Compared without case, since the Mac's disk ignores
    /// it, so `~/pictures` is `~/Pictures`. On a disk that minds case, this
    /// only refuses more.
    static func isRefusedSpelling(
        _ path: String,
        home: String,
        systemPrefixes: [String] = refusedSystemPrefixes
    ) -> Bool {
        let path = path.lowercased()
        let home = home.lowercased()
        guard path.hasPrefix("/"), path != "/", !PathContainment.isSameOrInside(home, path) else { return true }
        let inHome = PathContainment.isInside(path, home)
        let homeRefused = (DeletionSafetyPolicy.neverDeletePrefixes(home: home)
            .filter { PathContainment.isSameOrInside($0.lowercased(), home) }
            + ["\(home)/library/mobile documents", "\(home)/library/cloudstorage"])
            .map { $0.lowercased() }
        if homeRefused.contains(where: { PathContainment.isSameOrInside(path, $0) }) { return true }
        if DeletionSafetyPolicy.neverDeleteExactPaths(home: home).contains(where: { $0.lowercased() == path }) {
            return true
        }
        // A test's home sits under `/var`, so inside home only home's own
        // entries apply.
        if inHome { return false }
        let systemRefused = (systemPrefixes + DeletionSafetyPolicy.neverDeletePrefixes(home: home)).map { $0.lowercased() }
        return systemRefused.contains { PathContainment.isSameOrInside(path, $0) }
    }

    /// Whether `root` is somewhere a Go module cache may be offered from at
    /// all: an allowed spelling (`isRefusedSpelling`), a real local folder
    /// reached through no link, and not in a
    /// folder iCloud or another sync service keeps, where a move to the Trash
    /// is a delete on every device.
    static func acceptsLocation(_ root: URL, home: URL) -> Bool {
        let path = root.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard !isRefusedSpelling(path, home: homePath) else { return false }

        if PathContainment.isInside(path, homePath) {
            if PathContainment.containsSymlinkComponent(root, home: homePath) { return false }
        } else if containsLinkFromRoot(path) {
            return false
        }
        guard isRealFolder(path) else { return false }
        guard AppFolders.isOnLocalDisk(root) else { return false }

        // iCloud Desktop & Documents leaves no marker file, so ask each folder
        // whether iCloud keeps it, from the cache up to home.
        var folder = root.standardizedFileURL
        while folder.path != "/" {
            if AppFolders.isSyncedByAnotherService(folder) { return false }
            if PathContainment.isSameOrInside(folder.path, homePath),
               (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
                return false
            }
            folder.deleteLastPathComponent()
        }
        return true
    }

    /// Whether everything in `root` is Go's: `cache`, and below every other
    /// entry only folders leading down to unpacked modules. The first element
    /// of a module path always has a dot (`github.com`), no element starts
    /// with one, and Go's module zips hold no version-control folder. So a
    /// file, a link, a hidden entry or a `.git` on the way down means the
    /// folder holds more than modules, such as the user's checkouts. A folder
    /// the user excluded inside it keeps the whole folder from being offered.
    /// So does an empty one: it needs Go's `cache/download` or at least one
    /// module. `cache` can be gone, as earlier versions of Purge cleaned it.
    static func holdsOnlyModules(_ root: URL, excludedPaths: Set<String>) -> Bool {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath().path
        if excludedPaths.contains(where: { PathContainment.isInside($0, canonical) }) { return false }
        guard let entries = entries(of: root) else { return false }
        var modules = 0
        for entry in entries {
            let name = entry.url.lastPathComponent
            if name == ".DS_Store", !entry.isFolder { continue }
            guard entry.isFolder else { return false }
            if name == "cache" { continue }
            guard !name.hasPrefix("."), name.contains(".") else { return false }
            // A one-element module path, such as `example.com@v1.0.0`.
            if name.contains("@v") {
                guard isUnpackedModule(entry.url, relativePath: name, root: root) else { return false }
                modules += 1
                continue
            }
            guard !name.contains("@"),
                  leadsOnlyToModules(entry.url, relativePath: name, root: root, depth: 1, modules: &modules) else {
                return false
            }
        }
        return modules > 0 || isRealFolder(root.path + "/cache/download")
    }

    /// Go's module paths are short. A deeper tree is not one.
    private static let maxModulePathDepth = 16

    private static let versionControlFolders: Set<String> = [".git", ".hg", ".svn", ".bzr", "_darcs", ".jj"]

    private static func leadsOnlyToModules(
        _ folder: URL,
        relativePath: String,
        root: URL,
        depth: Int,
        modules: inout Int
    ) -> Bool {
        guard depth <= maxModulePathDepth, let entries = entries(of: folder) else { return false }
        for entry in entries {
            let name = entry.url.lastPathComponent
            if name == ".DS_Store", !entry.isFolder { continue }
            guard entry.isFolder, !name.hasPrefix(".") else { return false }
            let relative = relativePath + "/" + name
            if name.contains("@v") {
                guard isUnpackedModule(entry.url, relativePath: relative, root: root) else { return false }
                modules += 1
            } else if !leadsOnlyToModules(entry.url, relativePath: relative, root: root, depth: depth + 1, modules: &modules) {
                return false
            }
        }
        return true
    }

    /// The files Go keeps in `cache/download/<module>/@v/` for each version it
    /// fetched.
    private static let downloadFileExtensions = ["zip", "ziphash", "mod", "info"]

    /// An unpacked module folder, `<module>@<version>`, with evidence that Go
    /// put it there: its download files in `cache/download`, or the
    /// read-only mode Go leaves on it and on everything at its top. Either can be missing on its own:
    /// earlier versions of Purge cleaned `cache` and left the modules, and
    /// `-modcacherw` leaves them writable. A folder with neither, such as an
    /// exported checkout named like a module, is not Go's. Go's zips never
    /// hold a version-control folder either, so one at its top is a checkout.
    private static func isUnpackedModule(_ folder: URL, relativePath: String, root: URL) -> Bool {
        guard let entries = entries(of: folder),
              !entries.contains(where: { versionControlFolders.contains($0.url.lastPathComponent) }),
              let at = relativePath.range(of: "@", options: .backwards) else { return false }
        let modulePath = relativePath[..<at.lowerBound]
        let version = relativePath[at.upperBound...]
        guard !modulePath.isEmpty, !version.isEmpty else { return false }

        var info = stat()
        guard lstat(folder.path, &info) == 0 else { return false }
        if foldersMadeWritable.contains(UInt64(info.st_ino)) { return true }
        let downloads = root.path + "/cache/download/" + modulePath + "/@v/" + version
        if downloadFileExtensions.contains(where: { isRegularFile(downloads + "." + $0) }) { return true }
        // Go's mark: the folder and everything at its top read-only, folders
        // `r-x` and files `r--`. A checkout someone made read-only rarely has
        // every file that way too.
        guard info.st_mode & S_IWUSR == 0 else { return false }
        return entries.allSatisfy { entry in
            var entryInfo = stat()
            return lstat(entry.url.path, &entryInfo) == 0 && entryInfo.st_mode & S_IWUSR == 0
        }
    }

    private struct Entry {
        let url: URL
        /// A real folder, never a link to one.
        let isFolder: Bool
    }

    private static func entries(of folder: URL) -> [Entry]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return nil }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(url: url, isFolder: values?.isSymbolicLink != true && values?.isDirectory == true)
        }
    }

    /// Whether a rule other than this one already offers `root` or a folder
    /// above it, such as `~/Library/Caches` or Go's build cache. A Safe row
    /// there could move the module cache without its Check First, so the
    /// module cache gets no row of its own, and `refusesDeletion` keeps the
    /// other row from moving a folder that holds it.
    static func isInsideAnotherOfferedFolder(_ root: URL) -> Bool {
        $judgingOtherRules.withValue(true) {
            var folder = root.standardizedFileURL
            while folder.path != "/" {
                if DeletionSafetyPolicy.evaluate(folder) == .allow { return true }
                folder.deleteLastPathComponent()
            }
            return false
        }
    }

    /// Reads the folder from disk. Nil when there is no folder Purge may offer
    /// anything from. `insideHomeOnly` is for a scan without Full Disk Access,
    /// which reads nothing outside home and nothing in a protected folder,
    /// such as Documents, before it knows it may.
    static func read(
        environment: [String: String],
        home: URL,
        excludedPaths: Set<String>,
        insideHomeOnly: Bool
    ) -> Snapshot? {
        readState(environment: environment, home: home, excludedPaths: excludedPaths, insideHomeOnly: insideHomeOnly)
            .snapshot
    }

    /// What a refresh keeps: where Go's cache is, by its spelling alone,
    /// whether or not anything there may be offered, and the snapshot.
    struct State: Equatable, Sendable {
        var configuredRoot: String?
        var snapshot: Snapshot?
    }

    static func readState(
        environment: [String: String],
        home: URL,
        excludedPaths: Set<String>,
        insideHomeOnly: Bool
    ) -> State {
        let homePath = home.standardizedFileURL.path
        // A limited scan opens Go's env file only inside home and only where
        // it may read: `GOENV` can name a file in Documents.
        let canRead: (URL) -> Bool = { file in
            !insideHomeOnly || (PathContainment.isInside(file.path, homePath)
                && ProtectedLocations.isReadable(file, access: .limited, home: home))
        }
        guard let root = configuredRoot(environment: environment, home: home, canRead: canRead) else { return State() }
        var state = State(configuredRoot: root.path)
        if insideHomeOnly {
            guard PathContainment.isInside(root.path, homePath),
                  ProtectedLocations.isReadable(root, access: .limited, home: home) else { return state }
        }
        guard acceptsLocation(root, home: home) else { return state }

        let offer: Snapshot.Offer
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let cacheCanonical = cache.standardizedFileURL.resolvingSymlinksInPath().path
        if isInsideAnotherOfferedFolder(root) {
            offer = .nothing
        } else if holdsOnlyModules(root, excludedPaths: excludedPaths) {
            offer = .wholeCache
        } else if !isRealFolder(cache.path + "/download")
            || excludedPaths.contains(where: { PathContainment.isInside($0, cacheCanonical) }) {
            offer = .nothing
        } else {
            offer = .downloadsOnly
        }
        state.snapshot = Snapshot(root: root.path, offer: offer, limited: insideHomeOnly)
        return state
    }

    // MARK: Snapshot

    /// The folder as last read, for `DeletionSafetyPolicy.evaluate` and the
    /// Dev Tools row list, which never read the disk for it. Refreshed at the
    /// start of each Dev Tools scan and each clean. Nil in the test host until
    /// a test binds `testContext` and refreshes.
    static var snapshot: Snapshot? {
        state.snapshot
    }

    /// Where Go keeps its cache as last read, even when nothing there may be
    /// offered, such as a folder without Go's evidence inside a Safe cache
    /// folder. `refusesDeletion` keeps every row from moving a folder that
    /// holds it.
    static var configuredRootPath: String? {
        state.configuredRoot
    }

    private static var state: State {
        if let testContext { return testContext.stored.withLock { $0 } }
        return store.withLock { $0 }
    }

    /// Reads the folder again. Off the main thread: it runs `launchctl` and
    /// lists the folder. The test host never reads the real one.
    @discardableResult
    static func refreshSnapshot(insideHomeOnly: Bool = false) -> Snapshot? {
        let read: State
        if let testContext {
            read = currentState(insideHomeOnly: insideHomeOnly)
            testContext.stored.withLock { $0 = read }
        } else {
            guard !RemovedAppHandoff.runsInTestHost else { return snapshot }
            LaunchdEnvironment.refresh()
            read = currentState(insideHomeOnly: insideHomeOnly)
            let changed = store.withLock { stored -> Bool in
                defer { stored = read }
                return stored != read
            }
            if !changed { return read.snapshot }
        }
        // `evaluate` reads the snapshot, so verdicts cached before it changed
        // are stale.
        DeletionSafetyPolicy.clearOfferedForCleanupCache()
        return read.snapshot
    }

    private static func currentRead(insideHomeOnly: Bool) -> Snapshot? {
        currentState(insideHomeOnly: insideHomeOnly).snapshot
    }

    /// `readState` with the test's values or the real ones.
    private static func currentState(insideHomeOnly: Bool) -> State {
        if let testContext {
            return readState(
                environment: testContext.environment,
                home: testContext.home,
                excludedPaths: testContext.excludedPaths,
                insideHomeOnly: insideHomeOnly
            )
        }
        return readState(
            environment: liveEnvironment,
            home: FileManager.default.homeDirectoryForCurrentUser,
            excludedPaths: ExcludedPathsStore.allExcludedPaths(),
            insideHomeOnly: insideHomeOnly
        )
    }

    /// Purge's own environment, with the Go names filled in from launchd.
    static var liveEnvironment: [String: String] {
        LaunchdEnvironment.merged(into: ProcessInfo.processInfo.environment)
    }

    private static let store = OSAllocatedUnfairLock<State>(initialState: State())

    // MARK: Row and gates

    /// The path the Go Module Cache row offers, if any: the whole folder, or
    /// its `cache`. Never both, so nothing is counted twice.
    static func rowPaths(home: URL) -> [URL] {
        guard let snapshot else { return [] }
        let root = URL(fileURLWithPath: snapshot.root, isDirectory: true)
        switch snapshot.offer {
        case .wholeCache: return [root]
        case .downloadsOnly: return [root.appendingPathComponent("cache", isDirectory: true)]
        case .nothing: return []
        }
    }

    /// Shape only, for `evaluate`: the folder itself when it was found to hold
    /// only modules, and its `cache` and below when anything is offered.
    /// Never one module folder on its own, never the folders above it, and
    /// never one of the exact folders `evaluate` refuses, whatever was read.
    static func isWhitelistedPath(_ path: String, home: String = DeletionSafetyPolicy.cachedHomePath) -> Bool {
        guard !judgingOtherRules, let snapshot, snapshot.offer != .nothing else { return false }
        if DeletionSafetyPolicy.neverDeleteExactPaths(home: home).contains(where: { $0.lowercased() == path.lowercased() }) {
            return false
        }
        if path == snapshot.root { return snapshot.isWholeCache }
        return PathContainment.isSameOrInside(path, snapshot.root + "/cache")
    }

    /// Whether `url` is the whole module cache as last read.
    static func isWholeCacheRoot(_ url: URL) -> Bool {
        guard let snapshot, snapshot.isWholeCache else { return false }
        return url.standardizedFileURL.path == snapshot.root
    }

    /// Checked before every move:
    /// - A folder that holds the module cache is never moved whole, by any
    ///   row, so a Safe row can't take the cache without its Check First.
    ///   Folders emptied entry by entry are judged by their entries.
    /// - The row's own target is moved only while the folder, read again from
    ///   disk with the scan's access, still offers it. So a `src` folder or
    ///   an exclusion added since the scan, or `GOMODCACHE` moved elsewhere,
    ///   stops the move.
    /// The Dev Tools filter asks on the main thread on every scan flush and
    /// takes the scan's answer for the second part.
    static func refusesDeletion(_ url: URL, reuseRecentRead: Bool = false) -> Bool {
        let current = Self.state
        guard let configured = current.configuredRoot else { return false }
        let path = url.standardizedFileURL.path
        // Only a shorter path can hold the root, so most calls stop at the
        // length test; this runs for every scanned item. It holds whether or
        // not the folder passed the checks below.
        if path.utf8.count < configured.utf8.count,
           PathContainment.isInside(configured.lowercased(), path.lowercased()),
           !DeletionSafetyPolicy.shouldDeleteContentsOnly(url) {
            return true
        }
        guard let snapshot = current.snapshot else { return false }
        let target: Snapshot.Offer
        if path == snapshot.root {
            target = .wholeCache
        } else if path == snapshot.root + "/cache" {
            target = .downloadsOnly
        } else {
            return false
        }
        guard snapshot.offer == target else { return true }
        if reuseRecentRead { return false }
        return currentRead(insideHomeOnly: snapshot.limited) != snapshot
    }

    // MARK: Before the move

    /// Gives the owner write permission on every folder under `root` that
    /// lacks it, so the Trash can be emptied. Files are left alone: removing
    /// a file needs write permission on its folder, not on the file. Links are
    /// never followed and other volumes never entered. Returns the inode
    /// numbers of the folders it changed, all on the root's volume, or nil when any folder could not be read or changed; the
    /// caller then leaves the cache where it is.
    static func makeFoldersWritable(in root: URL) -> Set<UInt64>? {
        let rootPath = root.standardizedFileURL.path
        var rootInfo = stat()
        guard lstat(rootPath, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let device = rootInfo.st_dev
        let user = getuid()
        var allWritable = true
        var changed: Set<UInt64> = []

        func makeWritable(_ path: String, _ info: stat) {
            guard info.st_uid == user else {
                // Another account's folder, such as one `sudo go` made. Purge
                // can't change it, and the Trash couldn't empty it.
                if access(path, W_OK) != 0 { allWritable = false }
                return
            }
            guard info.st_mode & S_IWUSR == 0 else { return }
            if fchmodat(AT_FDCWD, path, (info.st_mode & 0o7777) | S_IWUSR, AT_SYMLINK_NOFOLLOW) == 0 {
                changed.insert(UInt64(info.st_ino))
            } else {
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
        ) else { return nil }
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
        return allWritable ? changed : nil
    }

    // MARK: Helpers

    private static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

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

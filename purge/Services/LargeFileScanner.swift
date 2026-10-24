import AppKit
import Foundation

/// `nonisolated` is load-bearing, not tidiness. The project builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it this type — and the
/// `static run` below — are implicitly main-actor isolated, and the `Task.detached`
/// in `scanStream` immediately hops *back* to the main actor. A probe confirmed
/// `run` executing with `Thread.isMainThread == true`, i.e. the entire
/// home-directory walk was blocking the UI; it measured as a ~1.15s freeze on
/// first switch to the Large Files tab.
nonisolated final class LargeFileScanner {
    /// `roots` and `exclusions` default to the policy's home folders and the saved
    /// exclusion list. `isExcluded` is the final check on each file before it is
    /// listed and defaults to the store; tests pass their own.
    ///
    /// `virtualMachineRoots` are walked for VM bundles only. They default to the
    /// policy's VM folders, but only when `roots` is also left to default: a
    /// caller that names its own roots never walks the real `~/Parallels` by
    /// accident. `installedApps` defaults to a LaunchServices lookup, and
    /// `isAppRunning` to the running-apps list. `home` decides where a Safari
    /// download bundle may sit; tests pass a temporary one.
    ///
    /// `iCloudDriveRoots` are walked like the home folders, but their rows are
    /// offered for Remove Download only and an iCloud file there that can't
    /// have its download removed is left off (#106). They default to iCloud
    /// Drive's own folder, again only when `roots` is left to default.
    func scanStream(
        minBytes: Int64,
        staleDays: Int,
        roots: [URL]? = nil,
        virtualMachineRoots: [URL]? = nil,
        iCloudDriveRoots: [URL]? = nil,
        installedApps: Set<VirtualMachineApp>? = nil,
        isAppRunning: (@Sendable (String) -> Bool)? = nil,
        home: URL? = nil,
        exclusions: ScanExclusions? = nil,
        isExcluded: (@Sendable (URL) -> Bool)? = nil
    ) -> AsyncStream<LargeFile> {
        let events = scanEvents(
            minBytes: minBytes, staleDays: staleDays, roots: roots,
            virtualMachineRoots: virtualMachineRoots, iCloudDriveRoots: iCloudDriveRoots,
            installedApps: installedApps,
            isAppRunning: isAppRunning, home: home, exclusions: exclusions, isExcluded: isExcluded
        )
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    if case .file(let file) = event { continuation.yield(file) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The rows as `scanStream` gives them, then one `.finished` with what the
    /// walk skipped: cloud-only placeholders, media libraries and roots it
    /// couldn't list (#230). A cancelled scan ends without the summary.
    func scanEvents(
        minBytes: Int64,
        staleDays: Int,
        roots: [URL]? = nil,
        virtualMachineRoots: [URL]? = nil,
        iCloudDriveRoots: [URL]? = nil,
        installedApps: Set<VirtualMachineApp>? = nil,
        isAppRunning: (@Sendable (String) -> Bool)? = nil,
        home: URL? = nil,
        exclusions: ScanExclusions? = nil,
        isExcluded: (@Sendable (URL) -> Bool)? = nil
    ) -> AsyncStream<LargeFileScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let home = home ?? FileManager.default.homeDirectoryForCurrentUser
                var walks = (roots ?? LargeFileScanPolicy.scanRoots(home: home))
                    .map { Walk(root: $0, bundlesOnly: false, downloadOnly: false) }
                let driveRoots = iCloudDriveRoots
                    ?? (roots == nil ? [LargeFileScanPolicy.iCloudDriveRoot(home: home)] : [])
                walks += driveRoots.map { Walk(root: $0, bundlesOnly: false, downloadOnly: true) }
                let vmRoots = virtualMachineRoots
                    ?? (roots == nil ? LargeFileScanPolicy.virtualMachineRoots(home: home) : [])
                walks += vmRoots.map { Walk(root: $0, bundlesOnly: true, downloadOnly: false) }
                await Self.run(
                    minBytes: minBytes,
                    staleDays: staleDays,
                    walks: walks,
                    installedApps: installedApps ?? Self.installedVirtualMachineApps(),
                    isAppRunning: isAppRunning ?? { DeletionSafetyPolicy.isAppRunning(bundleID: $0) },
                    home: home,
                    exclusions: exclusions,
                    isExcluded: isExcluded ?? { ExcludedPathsStore.isExcluded($0) },
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// How many enumerator steps share one autorelease pool. `nextObject()` and
    /// `resourceValues` allocate Foundation objects per file; draining every step
    /// is slower, and never draining lets a Downloads walk hold megabytes of
    /// transients until the root finishes.
    private static let enumeratorAutoreleaseBatch = 256

    /// Asked once per scan, here off the main thread, so drawing a row never
    /// makes a LaunchServices call to decide what its explanation says.
    private static func installedVirtualMachineApps() -> Set<VirtualMachineApp> {
        Set(VirtualMachineApp.allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        })
    }

    /// One root and how it is walked. `bundlesOnly` lists VM bundles and
    /// nothing else; `downloadOnly` lists files whose iCloud download can be
    /// removed and offers nothing for the Trash.
    private struct Walk {
        let root: URL
        let bundlesOnly: Bool
        let downloadOnly: Bool
    }

    private static func run(
        minBytes: Int64,
        staleDays: Int,
        walks: [Walk],
        installedApps: Set<VirtualMachineApp>,
        isAppRunning: @Sendable (String) -> Bool,
        home: URL,
        exclusions: ScanExclusions?,
        isExcluded: @Sendable (URL) -> Bool,
        continuation: AsyncStream<LargeFileScanEvent>.Continuation
    ) async {
        let fm = FileManager.default
        let exclusions = exclusions ?? .current()
        let now = Date()
        var summary = LargeFileScanSummary(minBytes: minBytes)
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey,
            .contentAccessDateKey, .contentModificationDateKey, .isPackageKey,
            .isUserImmutableKey, .isSystemImmutableKey
        ]

        // A model store inside a walked folder (swift-transformers downloads to
        // `~/Documents/huggingface/models`, or a Hub cache `HF_HUB_CACHE` moved
        // into Documents) is `AIModelScanner`'s: one row per model there, not a
        // file per weight here. Both spellings are kept, because the enumerator
        // spells a root `/private/var/…` where the policy says `/var/…`, so each
        // folder costs one set lookup at any depth and no resolve.
        let modelStoreRoots = Set(
            AIModelScanPolicy.rootsInsideLargeFileScan(home: home).flatMap { root -> [String] in
                let path = root.resolvingSymlinksInPath().path
                return [path, "/private" + path]
            }
        )

        // A root the user moved and left a link in its place is walked where the
        // link leads (#273). Nil for a missing root, and for a link Large Files
        // doesn't follow.
        let exists = walks.map { fm.fileExists(atPath: $0.root.path) }
        let folders = walks.indices.map { index in
            exists[index] ? LargeFileScanPolicy.walkedFolder(for: walks[index].root, home: home) : nil
        }
        // Two roots can lead to one folder, or one into the other's
        // (`~/Desktop -> ~/Documents/Desktop`). That folder is walked once, by
        // the root that holds it. Listed twice, a file would be its own
        // duplicate, and trashing the "extra copy" would trash the only one.
        // Folders are compared by identity, not spelling: on the default volume
        // `~/documents` is `~/Documents` (2026-10-22 in `docs/safety-notes.md`).
        let identities = folders.map { $0.flatMap { FileIdentity(path: $0.path) } }
        func isCovered(_ index: Int) -> Bool {
            guard let folder = folders[index], let own = identities[index] else { return false }
            var above = Set<FileIdentity>()
            var parent = folder.resolvingSymlinksInPath()
            while parent.path != "/" {
                parent = parent.deletingLastPathComponent()
                if let identity = FileIdentity(path: parent.path) { above.insert(identity) }
            }
            return walks.indices.contains { other in
                guard other != index, !walks[other].bundlesOnly, !walks[other].downloadOnly,
                      let identity = identities[other] else { return false }
                return above.contains(identity) || (identity == own && other < index)
            }
        }
        // Skipping a covered root is the fast path. Each entry is also listed
        // once, by its folder's identity and its name, which holds for any mix
        // of roots, such as a home folder linked inside a VM folder. Hard links
        // in two folders are two entries and stay two rows, as before.
        var listedEntries = Set<ListedEntry>()
        func isFirstListing(_ file: LargeFile) -> Bool {
            guard let folder = FileIdentity(path: file.path.deletingLastPathComponent().path) else { return true }
            return listedEntries.insert(ListedEntry(folder: folder, name: file.path.lastPathComponent)).inserted
        }

        for (index, walk) in walks.enumerated() {
            let root = walk.root
            let bundlesOnly = walk.bundlesOnly
            if Task.isCancelled { break }
            guard exists[index] else { continue }
            guard let folder = folders[index] else {
                if !bundlesOnly {
                    summary.unreadableRoots.append(.init(path: root, reason: unwalkedLinkReason(root)))
                }
                continue
            }
            if isCovered(index) {
                if !bundlesOnly { summary.checkedRoots.append(root) }
                continue
            }
            // Folders the user excluded are never entered, not just hidden from the
            // results, so an excluded archive also stops costing scan time (#46).
            let excluded = exclusions.scoped(to: folder)
            if excluded.excludesRoot { continue }
            // How the enumerator spells the root, taken from its first child rather
            // than from `root`: it can differ (`/private/var` for `/var`), and
            // matching is on the path below this prefix. See `ScanExclusions`.
            var walkedRootPrefix: String?

            // A root macOS refuses to list used to look exactly like an empty one:
            // the enumerator reports the refusal here and then yields nothing. The
            // summary names it so the empty state can say the scan was incomplete.
            let rootFailure = RootFailure()
            let rootPath = folder.resolvingSymlinksInPath().path
            guard let enumerator = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    if url.resolvingSymlinksInPath().path == rootPath {
                        rootFailure.error = error
                    }
                    return true
                }
            ) else {
                if !bundlesOnly {
                    summary.unreadableRoots.append(.init(path: root, reason: ""))
                }
                continue
            }

            enumerateRoot: while true {
                let keepGoing: Bool = autoreleasepool {
                    for _ in 0..<enumeratorAutoreleaseBatch {
                        guard let next = enumerator.nextObject() else { return false }
                        if Task.isCancelled { return false }
                        guard let fileURL = next as? URL else { continue }

                        let values = try? fileURL.resourceValues(forKeys: resourceKeys)

                        var isUserExcluded: Bool {
                            guard !excluded.isEmpty else { return false }
                            if walkedRootPrefix == nil, enumerator.level == 1 {
                                walkedRootPrefix = fileURL.deletingLastPathComponent().path + "/"
                            }
                            let path = fileURL.path
                            guard let prefix = walkedRootPrefix, path.hasPrefix(prefix) else { return false }
                            return excluded.contains(relativePath: path.dropFirst(prefix.count))
                        }

                        if values?.isDirectory == true || values?.isPackage == true {
                            // A VM or a Safari download bundle is one item. Never walk
                            // into it, whether or not macOS calls it a package: without
                            // the VM app installed it is a plain folder, and a disk file
                            // listed from inside it could be trashed alone.
                            let isVirtualMachine = VirtualMachineApp(bundleExtension: fileURL.pathExtension) != nil
                            if isVirtualMachine
                                || (!bundlesOnly && LargeFileScanPolicy.isSafariDownloadBundle(fileURL, home: home)) {
                                enumerator.skipDescendants()
                                if isUserExcluded { continue }
                                // A VM that may be running is left off the list; the
                                // delete check refuses it again in case it starts later.
                                if isVirtualMachine,
                                   LargeFileScanPolicy.virtualMachineIsInUse(fileURL, isAppRunning: isAppRunning) {
                                    continue
                                }
                                let measured = FolderSizing.walkedSize(at: fileURL, skipsPackages: false)
                                if let file = listed(
                                    fileURL, size: measured.bytes, lastUsed: measured.lastUsed,
                                    minBytes: minBytes, staleDays: staleDays, now: now,
                                    installedApps: installedApps, isExcluded: isExcluded,
                                    home: home, downloadOnly: walk.downloadOnly
                                ), isFirstListing(file) {
                                    continuation.yield(.file(file))
                                }
                                continue
                            }
                            // A media library is skipped like any excluded folder, but
                            // its size goes in the summary: on a Mac whose big files
                            // all live in Photos, an empty list with no reason reads as
                            // a broken scan. Nothing inside it is ever listed.
                            if !bundlesOnly, !isUserExcluded,
                               LargeFileScanSummary.SkippedLibrary.extensions.contains(fileURL.pathExtension.lowercased()) {
                                enumerator.skipDescendants()
                                // The exclusion check comes before the walk: a library
                                // the user excluded must not cost the scan its size.
                                guard !isExcluded(fileURL) else { continue }
                                let measured = FolderSizing.walkedSize(at: fileURL, skipsPackages: false)
                                if measured.bytes >= minBytes {
                                    summary.skippedLibraries.append(
                                        .init(path: fileURL.standardizedFileURL, bytes: measured.bytes)
                                    )
                                }
                                continue
                            }
                            if LargeFileScanPolicy.isExcludedDirectory(fileURL) || isUserExcluded {
                                enumerator.skipDescendants()
                                continue
                            }
                            if modelStoreRoots.contains(fileURL.standardizedFileURL.path) {
                                enumerator.skipDescendants()
                            }
                            continue
                        }

                        // VM folders hold VM bundles. Anything else there is not
                        // this walk's business; the home roots cover the rest.
                        if bundlesOnly { continue }
                        guard values?.isRegularFile == true else { continue }
                        if isUserExcluded { continue }

                        // Zero allocated bytes is a real size, not a missing one. A dataless
                        // iCloud placeholder reports 0 here and a large logical `fileSize`;
                        // falling through on 0 would list files that aren't on this Mac.
                        let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                        let accessed = values?.contentAccessDate ?? .distantPast
                        let modified = values?.contentModificationDate ?? .distantPast

                        // The placeholder still counts, under the provider that holds
                        // it, so the empty state can say the files exist but take no
                        // space here. Same filters as a listed row, so the summary
                        // answers the question the chips ask.
                        if size < minBytes, values?.totalFileAllocatedSize == 0,
                           let logical = values?.fileSize, Int64(logical) >= minBytes,
                           passesStaleFilter(lastUsed: max(accessed, modified), staleDays: staleDays, now: now),
                           !isExcluded(fileURL) {
                            let isUbiquitous = (try? fileURL.resourceValues(
                                forKeys: [.isUbiquitousItemKey]
                            ))?.isUbiquitousItem == true
                            summary.addCloudOnly(
                                LargeFileScanSummary.CloudProvider.provider(for: fileURL, isUbiquitous: isUbiquitous, home: home),
                                bytes: Int64(logical)
                            )
                            continue
                        }
                        if let file = listed(
                            fileURL, size: size, lastUsed: max(accessed, modified),
                            minBytes: minBytes, staleDays: staleDays, now: now,
                            installedApps: installedApps, isExcluded: isExcluded,
                            home: home, downloadOnly: walk.downloadOnly
                        ), isFirstListing(file) {
                            continuation.yield(.file(file))
                        }
                    }
                    return true
                }
                if !keepGoing { break enumerateRoot }
            }

            if !bundlesOnly {
                if let error = rootFailure.error {
                    summary.unreadableRoots.append(.init(path: root, reason: error.localizedDescription))
                } else {
                    summary.checkedRoots.append(root)
                }
            }
        }

        if !Task.isCancelled {
            continuation.yield(.finished(summary))
        }
        continuation.finish()
    }

    /// Set by the enumerator's error handler, which must outlive the loop that
    /// reads it.
    private nonisolated final class RootFailure {
        var error: Error?
    }

    /// A directory entry: the folder it is in, by identity, and its name.
    private struct ListedEntry: Hashable {
        let folder: FileIdentity
        let name: String
    }

    /// Why a root that is a link was left out, with where it leads, so the
    /// summary doesn't read as a folder macOS refused to open.
    private static func unwalkedLinkReason(_ root: URL) -> String {
        let target = (root.resolvingSymlinksInPath().path as NSString).abbreviatingWithTildeInPath
        return String(localized: "It links to \(target), which Large Files doesn't scan.")
    }

    /// The last-used filter, shared by the rows and the summary's tallies.
    private static func passesStaleFilter(lastUsed: Date, staleDays: Int, now: Date) -> Bool {
        guard staleDays > 0 else { return true }
        let days = Calendar.current.dateComponents([.day], from: lastUsed, to: now).day ?? 0
        return days >= staleDays
    }

    /// The checks every listed item passes, file or bundle, and the row it
    /// becomes. Nil when the item stays off the list.
    private static func listed(
        _ fileURL: URL,
        size: Int64,
        lastUsed: Date,
        minBytes: Int64,
        staleDays: Int,
        now: Date,
        installedApps: Set<VirtualMachineApp>,
        isExcluded: (URL) -> Bool,
        home: URL,
        downloadOnly: Bool
    ) -> LargeFile? {
        guard size >= minBytes else { return nil }
        guard passesStaleFilter(lastUsed: lastUsed, staleDays: staleDays, now: now) else { return nil }

        // Never list a file the filesystem will refuse to give up — its own
        // flags or its directory's. Offering it can only end in "couldn't be
        // cleaned", so it does not belong in the list at all. The check runs
        // last because it costs syscalls and only a handful of files, already
        // past the size and staleness filters, get this far.
        if FileProtection.blocksRemoval(fileURL) { return nil }

        // The skip in the walk is the fast path, not the guarantee. It only
        // knows the list as it was when this root started, and it
        // misses a folder whose own entry couldn't be read (no
        // `isDirectory`, so no `skipDescendants`). This asks the store,
        // with symlinks resolved, about the few files that got this far.
        // It runs here, off the main actor, so a list that changes
        // mid-scan never costs the UI a check per file.
        if isExcluded(fileURL) { return nil }

        // Asked here, not in `resourceKeys`: inside an iCloud-synced folder
        // this key costs about 0.15 ms a file, which made a walk of a
        // 36,000-file Documents folder 20x slower when every file paid it.
        // Nil means the file is not an iCloud item, as for any local file.
        let syncsWithICloud = (try? fileURL.resourceValues(
            forKeys: [.isUbiquitousItemKey]
        ))?.isUbiquitousItem == true

        // The same checks the remover runs before it acts, asked only of synced
        // files that made the list. In iCloud Drive's own folder Remove Download
        // is the only thing on offer, so a file that can't have it isn't listed.
        let canRemoveDownload = syncsWithICloud
            && ICloudDownloadPolicy.evaluate(fileURL, home: home, now: now).decision == .removable
        if downloadOnly, !canRemoveDownload { return nil }

        var kind = LargeFileKind.kind(forExtension: fileURL.pathExtension)
        if case .virtualMachine(let app, _) = kind {
            kind = .virtualMachine(app, appInstalled: installedApps.contains(app))
        }

        return LargeFile(
            path: fileURL.standardizedFileURL,
            sizeBytes: size,
            lastUsed: lastUsed,
            category: LargeFileCategory.category(forExtension: fileURL.pathExtension),
            syncsWithICloud: syncsWithICloud,
            canMoveToTrash: !downloadOnly,
            canRemoveDownload: canRemoveDownload,
            kind: kind
        )
    }
}

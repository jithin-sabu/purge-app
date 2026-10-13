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
    /// accident. `installedApps` defaults to a LaunchServices lookup.
    func scanStream(
        minBytes: Int64,
        staleDays: Int,
        roots: [URL]? = nil,
        virtualMachineRoots: [URL]? = nil,
        installedApps: Set<VirtualMachineApp>? = nil,
        exclusions: ScanExclusions? = nil,
        isExcluded: (@Sendable (URL) -> Bool)? = nil
    ) -> AsyncStream<LargeFile> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let home = FileManager.default.homeDirectoryForCurrentUser
                var walks = (roots ?? LargeFileScanPolicy.scanRoots(home: home))
                    .map { (root: $0, bundlesOnly: false) }
                let vmRoots = virtualMachineRoots
                    ?? (roots == nil ? LargeFileScanPolicy.virtualMachineRoots(home: home) : [])
                walks += vmRoots.map { (root: $0, bundlesOnly: true) }
                await Self.run(
                    minBytes: minBytes,
                    staleDays: staleDays,
                    walks: walks,
                    installedApps: installedApps ?? Self.installedVirtualMachineApps(),
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

    private static func run(
        minBytes: Int64,
        staleDays: Int,
        walks: [(root: URL, bundlesOnly: Bool)],
        installedApps: Set<VirtualMachineApp>,
        exclusions: ScanExclusions?,
        isExcluded: @Sendable (URL) -> Bool,
        continuation: AsyncStream<LargeFile>.Continuation
    ) async {
        let fm = FileManager.default
        let exclusions = exclusions ?? .current()
        let now = Date()
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey,
            .contentAccessDateKey, .contentModificationDateKey, .isPackageKey,
            .isUserImmutableKey, .isSystemImmutableKey
        ]

        for (root, bundlesOnly) in walks {
            if Task.isCancelled { break }
            guard fm.fileExists(atPath: root.path) else { continue }
            // Folders the user excluded are never entered, not just hidden from the
            // results, so an excluded archive also stops costing scan time (#46).
            let excluded = exclusions.scoped(to: root)
            if excluded.excludesRoot { continue }
            // How the enumerator spells the root, taken from its first child rather
            // than from `root`: it can differ (`/private/var` for `/var`), and
            // matching is on the path below this prefix. See `ScanExclusions`.
            var walkedRootPrefix: String?

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

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
                            // A VM or an unfinished download bundle is one item. Never
                            // walk into it, whether or not macOS calls it a package:
                            // without the VM app installed it is a plain folder, and a
                            // disk file listed from inside it could be trashed alone.
                            let ext = fileURL.pathExtension.lowercased()
                            if LargeFileKind.wholeBundleExtensions.contains(ext) {
                                enumerator.skipDescendants()
                                if isUserExcluded { continue }
                                if bundlesOnly, VirtualMachineApp(bundleExtension: ext) == nil { continue }
                                let measured = FolderSizing.walkedSize(at: fileURL, skipsPackages: false)
                                if let file = listed(
                                    fileURL, size: measured.bytes, lastUsed: measured.lastUsed,
                                    minBytes: minBytes, staleDays: staleDays, now: now,
                                    installedApps: installedApps, isExcluded: isExcluded
                                ) {
                                    continuation.yield(file)
                                }
                                continue
                            }
                            if LargeFileScanPolicy.isExcludedDirectory(fileURL) || isUserExcluded {
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
                        if let file = listed(
                            fileURL, size: size, lastUsed: max(accessed, modified),
                            minBytes: minBytes, staleDays: staleDays, now: now,
                            installedApps: installedApps, isExcluded: isExcluded
                        ) {
                            continuation.yield(file)
                        }
                    }
                    return true
                }
                if !keepGoing { break enumerateRoot }
            }
        }

        continuation.finish()
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
        isExcluded: (URL) -> Bool
    ) -> LargeFile? {
        guard size >= minBytes else { return nil }
        if staleDays > 0 {
            let days = Calendar.current.dateComponents([.day], from: lastUsed, to: now).day ?? 0
            guard days >= staleDays else { return nil }
        }

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
            kind: kind
        )
    }
}

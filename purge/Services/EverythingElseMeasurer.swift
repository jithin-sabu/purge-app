import Foundation

/// Walks the folders Purge never lists and reports how much each holds (#220).
///
/// Read only. This measures; it never lists anything for cleaning, and nothing it
/// returns reaches `FileDeleter`. One pass per root: the folders directly inside
/// are sized with `du` in chunks through `FolderSizing`, which shares the
/// process-wide cap on `du` processes with the scanners, and the files beside
/// them are summed in place. Each root is reported as it finishes, so the groups
/// fill in while the rest of the walk runs.
///
/// `nonisolated` is load-bearing: the project defaults types to the main actor,
/// and the walk takes minutes on a big home folder.
nonisolated final class EverythingElseMeasurer {
    /// `home`, `steamLibraries`, `otherUserHomes` and `usersFolder` default to
    /// this Mac's; tests pass their own so nothing here reads the real home
    /// folder or `/Users`.
    func measureStream(
        access: ScanAccess,
        home: URL? = nil,
        steamLibraries: [URL]? = nil,
        otherUserHomes: [URL]? = nil,
        usersFolder: URL? = nil,
        readsSystemVolume: Bool = true
    ) -> AsyncStream<EverythingElseMeasureEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let home = (home ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL
                let usersFolder = usersFolder ?? URL(fileURLWithPath: "/Users", isDirectory: true)
                let homeNames = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
                let roots = EverythingElseRootPlan.roots(
                    home: home,
                    access: access,
                    steamLibraries: steamLibraries ?? Self.steamLibraries(home: home, access: access),
                    otherUserHomes: otherUserHomes ?? Self.otherUserHomes(home: home, usersFolder: usersFolder),
                    homeFolderNames: homeNames,
                    usersFolder: usersFolder
                )
                Self.run(roots: roots, access: access, home: home, readsSystemVolume: readsSystemVolume, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        roots: [EverythingElseMeasureRoot],
        access: ScanAccess,
        home: URL,
        readsSystemVolume: Bool,
        continuation: AsyncStream<EverythingElseMeasureEvent>.Continuation
    ) {
        defer { continuation.finish() }
        continuation.yield(.planned(roots))

        // The system volume first: one `diskutil` call, so the drill-in has its
        // macOS line before the long walk starts.
        if readsSystemVolume, let bytes = systemVolumeUsedBytes() {
            continuation.yield(.macOS(bytes))
        }

        for root in roots {
            if Task.isCancelled { return }
            if root.isLockedWithoutAccess {
                continuation.yield(.skipped(root, locked: true))
                continue
            }
            guard isDirectory(root.url) else {
                continuation.yield(.skipped(root, locked: false))
                continue
            }
            switch root.kind {
            case .whole:
                guard let bytes = FolderSizing.directoryByteSizeIfMeasurable(at: root.url) else {
                    continuation.yield(.skipped(root, locked: false))
                    continue
                }
                continuation.yield(.measured(EverythingElseMeasuredRoot(root: root, totalBytes: bytes)))
            case .children, .hiddenChildren, .childrenExcept:
                let measured = measureChildren(of: root, access: access, home: home) { fraction in
                    continuation.yield(.progress(root, fraction))
                }
                guard let measured else {
                    continuation.yield(.skipped(root, locked: false))
                    continue
                }
                if Task.isCancelled { return }
                continuation.yield(.measured(measured))
                let games = steamGames(inCommonFolder: root.url)
                if !games.isEmpty {
                    continuation.yield(.steamGames(games))
                }
            }
        }
    }

    /// Sizes every folder directly inside the root and sums the files beside them.
    /// A `hiddenChildren` root sizes only its dot folders, and a `childrenExcept`
    /// root only the visible folders no other root measures; neither counts
    /// loose files, which stay in the remainder.
    /// `progress` hears how far through the root's folders the sizing is, 0...1.
    private static func measureChildren(
        of root: EverythingElseMeasureRoot,
        access: ScanAccess,
        home: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) -> EverythingElseMeasuredRoot? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        let hiddenOnly: Bool
        let skippedNames: Set<String>
        switch root.kind {
        case .hiddenChildren:
            hiddenOnly = true
            skippedNames = []
        case .childrenExcept(let names):
            hiddenOnly = false
            skippedNames = names
        case .children, .whole:
            hiddenOnly = false
            skippedNames = []
        }
        let countsLooseFiles = root.kind == .children
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root.url,
            includingPropertiesForKeys: Array(keys),
            options: hiddenOnly ? [] : [.skipsHiddenFiles]
        ) else { return nil }

        var folders: [URL] = []
        var looseFileBytes: Int64 = 0
        for entry in entries {
            let name = entry.lastPathComponent
            if hiddenOnly {
                guard name.hasPrefix("."), !EverythingElseRootPlan.ignoredHiddenFolders.contains(name) else { continue }
            }
            if skippedNames.contains(name.lowercased()) { continue }
            guard let values = try? entry.resourceValues(forKeys: keys) else { continue }
            // A link is counted as the few bytes it is, never followed: the folder it
            // points at is measured where it really lives, or not at all.
            if values.isSymbolicLink == true {
                if countsLooseFiles { looseFileBytes += Int64(values.fileSize ?? 0) }
                continue
            }
            if values.isDirectory == true {
                // A limited walk leaves the protected roots and the media and
                // contacts folders alone, so no prompt ever comes from here.
                if access == .limited, !EverythingElseRootPlan.isReadableByLimitedWalk(entry, home: home) { continue }
                folders.append(entry)
            } else if countsLooseFiles {
                looseFileBytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        if Task.isCancelled { return nil }

        let sizes = FolderSizing.directorySizes(at: folders) { done, total in
            progress(Double(done) / Double(max(1, total)))
        }
        var items: [OverviewSizedItem] = []
        items.reserveCapacity(folders.count)
        for folder in folders {
            // A folder `du` could not read gets no row rather than a zero that
            // would read as empty.
            guard let bytes = sizes[folder.standardizedFileURL.path] else { continue }
            items.append(OverviewSizedItem(path: folder.path, bytes: bytes))
        }
        return EverythingElseMeasuredRoot(root: root, folders: items, looseFileBytes: looseFileBytes)
    }

    /// The manifests beside a Steam library's `common` folder, one per game.
    static func steamGames(inCommonFolder common: URL) -> [SteamGame] {
        let steamapps = common.deletingLastPathComponent()
        guard common.lastPathComponent == "common", steamapps.lastPathComponent == "steamapps",
              let names = try? FileManager.default.contentsOfDirectory(atPath: steamapps.path)
        else { return [] }
        return names
            .filter { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }
            .sorted()
            .compactMap { name in
                guard let text = try? String(contentsOf: steamapps.appendingPathComponent(name), encoding: .utf8) else { return nil }
                return SteamGame.parse(manifest: text, commonFolder: common)
            }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Steam's library roots on the startup disk, when the list is there and the
    /// scan may read it. Everything else is a share of the startup disk, so a
    /// library on another volume is left out. Links are resolved first, so a
    /// library reached through one is matched against Excluded Paths the way the
    /// store spells it.
    private static func steamLibraries(home: URL, access: ScanAccess) -> [URL] {
        let vdf = SteamLibraryFolders.vdfURL(home: home)
        guard ProtectedLocations.isReadable(vdf, access: access, home: home),
              let text = try? String(contentsOf: vdf, encoding: .utf8)
        else { return [] }
        let homeVolume = volumeIdentifier(of: home)
        return SteamLibraryFolders.libraryRoots(fromVDF: text)
            .map { $0.resolvingSymlinksInPath() }
            .filter { library in
                guard let homeVolume, let volume = volumeIdentifier(of: library) else { return false }
                return volume.isEqual(homeVolume)
            }
    }

    private static func volumeIdentifier(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    private static func otherUserHomes(home: URL, usersFolder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: usersFolder.path)) ?? []
        return EverythingElseRootPlan.otherUserHomes(in: usersFolder, names: names, home: home)
    }

    /// The system volume's used space, the figure System Settings calls macOS.
    /// `statfs` on `/` answers for the whole APFS container, so this asks
    /// `diskutil`, whose `CapacityInUse` is the sealed system volume alone.
    static func systemVolumeUsedBytes() -> Int64? {
        guard let output = ProcessRunner.run(
            executablePath: "/usr/sbin/diskutil",
            arguments: ["info", "-plist", "/"],
            timeout: 30
        ), output.succeeded else { return nil }
        return parseSystemVolumeUsedBytes(output.stdout)
    }

    static func parseSystemVolumeUsedBytes(_ plist: Data) -> Int64? {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, format: nil),
              let dictionary = object as? [String: Any]
        else { return nil }
        if let number = dictionary["CapacityInUse"] as? NSNumber {
            return number.int64Value
        }
        return nil
    }
}

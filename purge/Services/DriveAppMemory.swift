import Foundation

/// The apps Purge has seen on drives and in folders the user added (#99), kept
/// so an app on a drive that is unplugged still owns its leftovers.
///
/// An app's leftovers live in `~/Library` on the internal disk wherever the app
/// runs from. Without this, ejecting the drive would make its apps look
/// uninstalled: the orphan scan would offer their settings and caches, and
/// removing a second copy of the same app from `/Applications` would offer the
/// files the drive's copy still reads.
///
/// An entry is forgotten only when Purge can see it is gone: its folder is
/// there and the bundle is not. Until then it counts as installed, which keeps
/// files rather than offering them.
nonisolated enum DriveAppMemory {
    struct Entry: Codable, Equatable, Sendable {
        var bundlePath: String
        var bundleID: String?
        var name: String
        /// The app folder it was found in.
        var rootPath: String
        var lastSeen: Date
        /// `CFBundleVersion` when the claims below were read, so they are read
        /// again only after an update.
        var version: String?
        /// What the app and the code inside it claim, read from their
        /// signatures: the ids of nested helpers and extensions, the signing
        /// team, and the app groups. A group container is named after an app
        /// group, not the app (#197), so these keep one while the drive is out.
        var codeIDs: [String] = []
        var teamIDs: [String] = []
        var appGroups: [String] = []
    }

    static var file: URL {
        RemovedAppHandoff.root.appendingPathComponent("drive-apps.json", isDirectory: false)
    }

    static func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    /// The remembered apps that may still be installed: the bundle is there, or
    /// its folder is not, so Purge can't tell. `excluding` is the bundle path of
    /// an app being judged, which never counts as its own survivor.
    static func apps(excluding path: String? = nil) -> [InstalledApp] {
        presentEntries(excluding: path).map { entry in
            InstalledApp(
                name: entry.name,
                bundleURL: URL(fileURLWithPath: entry.bundlePath, isDirectory: true),
                bundleID: entry.bundleID,
                bundleSizeBytes: 0,
                isRunning: false
            )
        }
    }

    /// Notes the apps in `bundles` that sit in a drive's folder or one the user
    /// added, and forgets the entries Purge can see are gone. The test host
    /// never writes: its scans list the user's real apps.
    static func record(
        bundles: [URL],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        isTestHost: Bool = TestHost.isActive()
    ) {
        guard !isTestHost else { return }
        let builtIn = Set(AppFolders.builtInRoots(home: home).map(\.standardizedFileURL.path))
        let extraRoots = AppFolders.roots(home: home)
            .map(\.standardizedFileURL.path)
            .filter { !builtIn.contains($0) }
        let current = entries()
        let updated = merged(current, seen: seenEntries(bundles, roots: extraRoots, now: now, known: current))
        guard updated != current else { return }
        save(updated)
    }

    /// `current` with `seen` added or refreshed, less the entries that are gone.
    static func merged(_ current: [Entry], seen: [Entry]) -> [Entry] {
        var byPath: [String: Entry] = [:]
        for entry in current where mayStillBeInstalled(entry) {
            byPath[entry.bundlePath] = entry
        }
        for entry in seen {
            byPath[entry.bundlePath] = entry
        }
        return byPath.values.sorted { $0.bundlePath < $1.bundlePath }
    }

    /// `known` entries keep the claims they read for the same version, so a
    /// scan reads only new and updated apps' signatures.
    static func seenEntries(
        _ bundles: [URL],
        roots: [String],
        now: Date,
        known: [Entry] = [],
        readClaims: (URL) -> InstalledCodeEvidence = {
            InstalledCodeEvidence.gather(userAppBundles: [$0], systemAppRoots: [], runningApps: [], launchdJobRoots: [])
        }
    ) -> [Entry] {
        let knownByPath = Dictionary(known.map { ($0.bundlePath, $0) }, uniquingKeysWith: { first, _ in first })
        return bundles.compactMap { bundle -> Entry? in
            let path = bundle.standardizedFileURL.path
            guard let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { return nil }
            let version = AppBundleReach.readInfoPlist(at: bundle)["CFBundleVersion"] as? String
            var entry = Entry(
                bundlePath: path,
                bundleID: AppBundleReach.bundleID(at: bundle),
                name: bundle.deletingPathExtension().lastPathComponent,
                rootPath: root,
                lastSeen: now,
                version: version
            )
            if let old = knownByPath[path], old.version == version, old.bundleID == entry.bundleID {
                entry.codeIDs = old.codeIDs
                entry.teamIDs = old.teamIDs
                entry.appGroups = old.appGroups
            } else {
                let claims = readClaims(bundle)
                entry.codeIDs = claims.bundleIDs.sorted()
                entry.teamIDs = claims.teamIDs.sorted()
                entry.appGroups = claims.appGroups.sorted()
            }
            return entry
        }
    }

    /// The entries `apps(excluding:)` would return, for callers that need the
    /// claims as well.
    static func presentEntries(excluding path: String? = nil) -> [Entry] {
        entries().filter { $0.bundlePath != path && mayStillBeInstalled($0) }
    }

    /// False only when the folder it was found in is there and the bundle is not.
    static func mayStillBeInstalled(_ entry: Entry) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: entry.bundlePath) || !fm.fileExists(atPath: entry.rootPath)
    }

    private static func save(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? encoder.encode(entries).write(to: file, options: [.atomic])
    }
}

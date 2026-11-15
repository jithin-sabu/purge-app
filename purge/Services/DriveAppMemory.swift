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
        /// The drive's volume UUID when it was seen, so a different drive
        /// mounted under the same name does not make Purge forget the app.
        var volumeID: String?
        /// When the bundle's Info.plist and code signature last changed, so
        /// the claims are read again when an app is replaced in place, even at
        /// the same version.
        var signatureStamp: String?

        /// Two drives can mount at the same path with an app at the same
        /// place, so an entry is one bundle path on one drive.
        var key: String { bundlePath + "\u{0}" + (volumeID ?? "") }
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
    static func merged(
        _ current: [Entry],
        seen: [Entry],
        mayStillBeInstalled: (Entry) -> Bool = { DriveAppMemory.mayStillBeInstalled($0) }
    ) -> [Entry] {
        var byKey: [String: Entry] = [:]
        for entry in current where mayStillBeInstalled(entry) {
            byKey[entry.key] = entry
        }
        // A drive seen now replaces only its own entry, never another drive's
        // app that was at the same path.
        for entry in seen {
            byKey[entry.key] = entry
        }
        return byKey.values.sorted { ($0.bundlePath, $0.volumeID ?? "") < ($1.bundlePath, $1.volumeID ?? "") }
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
        let knownByKey = Dictionary(known.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
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
                version: version,
                volumeID: volumeID(of: URL(fileURLWithPath: root, isDirectory: true)),
                signatureStamp: signatureStamp(of: bundle)
            )
            if let old = knownByKey[entry.key],
               old.version == version,
               old.bundleID == entry.bundleID,
               old.signatureStamp != nil,
               old.signatureStamp == entry.signatureStamp {
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
        // Only the copy on the drive that holds `path` now is the app being
        // judged. Another drive's app at the same path is a different install.
        let excludedVolume = path.flatMap { volumeID(of: URL(fileURLWithPath: $0)) }
        return entries().filter { entry in
            let isJudged = entry.bundlePath == path && (entry.volumeID == nil || excludedVolume == nil || entry.volumeID == excludedVolume)
            return !isJudged && mayStillBeInstalled(entry)
        }
    }

    /// False only when the folder it was found in is there and the bundle is not.
    ///
    /// A folder at the same path on another drive, one that happens to have the
    /// same name, says nothing about this app: it still may be installed.
    static func mayStillBeInstalled(
        _ entry: Entry,
        volumeID: (URL) -> String? = { DriveAppMemory.volumeID(of: $0) }
    ) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: entry.bundlePath) || !fm.fileExists(atPath: entry.rootPath) { return true }
        guard let seenOn = entry.volumeID else { return false }
        return volumeID(URL(fileURLWithPath: entry.rootPath, isDirectory: true)) != seenOn
    }

    /// The modification times of the bundle's Info.plist and code signature.
    /// Replacing an app rewrites both, so its claims are read again.
    static func signatureStamp(of bundle: URL) -> String? {
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let files = [
            contents.appendingPathComponent("Info.plist"),
            contents.appendingPathComponent("_CodeSignature/CodeResources")
        ]
        let stamps = files.map { file -> String in
            guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                return "-"
            }
            return String(date.timeIntervalSince1970)
        }
        return stamps == ["-", "-"] ? nil : stamps.joined(separator: "/")
    }

    static func volumeID(of url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
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

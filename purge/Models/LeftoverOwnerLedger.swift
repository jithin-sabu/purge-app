import Foundation

/// Which installed app each human-named Library folder belonged to, as the
/// installed-apps scan saw it (#224). While Antigravity is installed, the
/// uninstaller matches `Application Support/Antigravity` to it by name. Once the
/// app is gone the name alone says nothing, because vendors share names
/// (`Docker`, `Google`), and the Leftovers scan leaves such folders alone (#197).
/// This ledger keeps the pairing Purge saw itself, so the folder can still be
/// attributed afterwards.
///
/// An entry only ever says "this app once matched this folder". Whether the app
/// is still installed is decided at scan time, never stored. Folders are
/// home-relative (`~/Library/...`) so the file survives a home folder move.
nonisolated struct LeftoverOwnerLedger: Codable, Equatable, Sendable {
    nonisolated struct Entry: Codable, Equatable, Sendable {
        /// The owning app's bundle id, as its bundle reported it.
        var bundleID: String
        /// The app's display name when the match was made. Shown on the row once
        /// the app is gone and nothing else can name it.
        var displayName: String
        /// Home-relative paths the app matched by name.
        var folders: [String]
        /// When the installed-apps scan last matched the app.
        var lastSeen: Date
    }

    static let currentVersion = 1

    var version = currentVersion
    var entries: [Entry] = []

    /// Records what one installed app matched. A later scan adds to the app's
    /// entry instead of duplicating it.
    mutating func record(bundleID: String, displayName: String, folders: [String], seenAt: Date = Date()) {
        let folders = folders.filter { !$0.isEmpty }
        guard !bundleID.isEmpty, !folders.isEmpty else { return }
        if let index = entries.firstIndex(where: { $0.bundleID.lowercased() == bundleID.lowercased() }) {
            var entry = entries[index]
            entry.displayName = displayName
            entry.lastSeen = seenAt
            for folder in folders where !entry.folders.contains(folder) {
                entry.folders.append(folder)
            }
            entries[index] = entry
        } else {
            entries.append(Entry(bundleID: bundleID, displayName: displayName, folders: folders, lastSeen: seenAt))
        }
    }

    /// Drops every folder that is gone, and every entry left with no folder.
    /// A folder the user trashed is forgotten; one a reinstall recreates is
    /// kept, and its owner is then installed again, which keeps the folder.
    mutating func prune(folderExists: (String) -> Bool) {
        entries = entries.compactMap { entry in
            var entry = entry
            entry.folders = entry.folders.filter(folderExists)
            return entry.folders.isEmpty ? nil : entry
        }
    }

    /// Every app recorded as matching this home-relative folder, newest first.
    func owners(ofFolder relativePath: String) -> [Entry] {
        entries
            .filter { $0.folders.contains(relativePath) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    /// `~/Library/...` for a path inside `home`, or nil for one outside it.
    static func relativePath(_ url: URL, home: URL) -> String? {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return nil }
        return "~" + path.dropFirst(homePath.count)
    }

    /// The folder a ledger path names, inside `home`.
    static func url(forRelativePath relativePath: String, home: URL) -> URL? {
        guard relativePath.hasPrefix("~/"), relativePath.count > 2 else { return nil }
        return home.appendingPathComponent(String(relativePath.dropFirst(2)), isDirectory: true)
    }
}

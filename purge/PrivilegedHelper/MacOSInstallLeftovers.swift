import Foundation

/// Files a finished macOS update left in `/System/Volumes/Data/macOS Install Data`
/// (#127). macOS doesn't remove them and Settings counts them as System Data.
///
/// The folder is root-owned, so its entries move to the Trash only through the root
/// helper. The app's scanner, `FileDeleter`, and the helper all read this one rule,
/// and the helper compiles this file too, so it uses Foundation only.
///
/// The path checks here are static. Whether the folder is a leftover at all is the
/// date rule in `isLeftover`, which changes on disk, so it is never part of the
/// memoised safety policy.
nonisolated enum MacOSInstallLeftovers {
    /// Only reachable through the Data volume: `/macOS Install Data` is not a firmlink.
    static let root = URL(fileURLWithPath: "/System/Volumes/Data/macOS Install Data", isDirectory: true)

    /// Written when the installed system was built, so anything an update downloads
    /// later is newer than it.
    static let systemVersionFile = URL(
        fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist",
        isDirectory: false
    )

    /// Carries the SIP `restricted` flag, so not even root can move it. Never listed.
    static let lockedFilesName = "Locked Files"

    /// True for a direct child of `root` that may be offered: not `Locked Files`, not
    /// hidden. The folder itself never qualifies, and neither does anything deeper.
    static func isEntryPath(_ path: String, root: URL = root) -> Bool {
        let rootPath = root.path
        guard path.hasPrefix(rootPath + "/") else { return false }
        let name = String(path.dropFirst(rootPath.count + 1))
        guard !name.isEmpty, !name.contains("/") else { return false }
        return name != "." && name != ".." && !name.hasPrefix(".") && name != lockedFilesName
    }

    /// The entries that may be offered, sorted by path. Empty when the folder is
    /// missing or can't be listed.
    static func entries(root: URL = root) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names
            .map { root.appendingPathComponent($0) }
            .filter { isEntryPath($0.path, root: root) }
            .sorted { $0.path < $1.path }
    }

    /// True only when the folder and every entry in it are older than the installed
    /// system. An update that is downloaded and waiting to install was written after
    /// the system it replaces, so it fails this and is left alone.
    ///
    /// Moving an entry out bumps the folder's date, so the helper works this out once
    /// per request, before it moves anything. After a partial move the rest are no
    /// longer offered; that is the safe side of the rule.
    ///
    /// A missing file, a symlinked folder, or an unreadable date answers `false`.
    static func isLeftover(root: URL = root, systemVersionFile: URL = systemVersionFile) -> Bool {
        guard let systemDate = modificationDate(atPath: systemVersionFile.path),
              let rootAttributes = try? FileManager.default.attributesOfItem(atPath: root.path),
              rootAttributes[.type] as? FileAttributeType == .typeDirectory,
              let rootDate = rootAttributes[.modificationDate] as? Date,
              rootDate < systemDate
        else { return false }

        let listed = entries(root: root)
        guard !listed.isEmpty else { return false }
        return listed.allSatisfy { entry in
            guard let date = modificationDate(atPath: entry.path) else { return false }
            return date < systemDate
        }
    }

    /// Never follows a symlink: `attributesOfItem` reports the link itself.
    private static func modificationDate(atPath path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

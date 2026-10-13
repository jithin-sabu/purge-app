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

    /// True only when the folder and everything in it, at every depth, are older than
    /// the installed system. An update that is downloaded and waiting to install was
    /// written after the system it replaces, so it fails this and is left alone.
    ///
    /// This checks more than what is offered: hidden items and `Locked Files` count
    /// too, and so does every file inside an entry, since writing deep inside a folder
    /// leaves the folders above it with their old dates. Each item's change time
    /// counts as well as its modification time, because a file copied or unpacked
    /// with its original dates still gets a fresh change time.
    ///
    /// Moving an entry out bumps the folder's date, so the helper works this out once
    /// per request, before it moves anything. After a partial move the rest are no
    /// longer offered; that is the safe side of the rule.
    ///
    /// Anything it can't read, a missing file, or a symlinked folder answers `false`.
    static func isLeftover(root: URL = root, systemVersionFile: URL = systemVersionFile) -> Bool {
        guard let systemDate = itemDates(atPath: systemVersionFile.path)?.modified,
              let rootDates = itemDates(atPath: root.path),
              rootDates.isDirectory,
              rootDates.newest < systemDate,
              !entries(root: root).isEmpty
        else { return false }

        var unreadable = false
        guard let walk = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                unreadable = true
                return false
            }
        ) else { return false }
        for case let item as URL in walk {
            guard let dates = itemDates(atPath: item.path), dates.newest < systemDate else { return false }
        }
        return !unreadable
    }

    /// `lstat`, so a symlink is judged by itself and never followed.
    private static func itemDates(atPath path: String) -> (modified: Date, newest: Date, isDirectory: Bool)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        func date(_ time: timespec) -> Date {
            Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
        }
        let modified = date(info.st_mtimespec)
        let changed = date(info.st_ctimespec)
        return (modified, max(modified, changed), (info.st_mode & S_IFMT) == S_IFDIR)
    }
}

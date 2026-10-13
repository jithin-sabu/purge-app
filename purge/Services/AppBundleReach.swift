import Foundation

/// Where the App Uninstaller looks for apps inside `/Applications` and
/// `~/Applications`: at any depth, but never inside another app or package,
/// never through a symlink, and never through a hidden folder.
///
/// Vendors nest their apps, like
/// `/Applications/Autodesk/AutoCAD 2026/AutoCAD 2026.app` (#143), and people
/// sort their own apps into folders. Every app found is listed, including a
/// suite's background parts, so the checks that hold back a leftover another
/// installed app still uses can see them all.
///
/// The picker, the delete gate, the Finder service check, the removal watcher,
/// the orphan index, and the root helper all read this one rule, so an app the
/// picker lists can always be trashed and is always watched, and nothing it
/// does not list passes the gate. The watch agent and the root helper compile
/// this file too, so it uses Foundation only.
nonisolated enum AppBundleReach {
    /// A guard against a runaway walk, not a product limit: no real app sits
    /// anywhere near this many folders down.
    static let maxFolderDepth = 32

    /// Folder extensions that mark a bundle or package. Paths are refused by
    /// name with these even when nothing is on disk to ask, as in a removal
    /// record or the tests. On disk, `isPackage` catches every other package
    /// type too.
    static let bundleFolderExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "xpc", "kext", "pkg", "mpkg",
        "prefpane", "saver", "qlgenerator", "mdimporter", "component", "wdgt", "systemextension"
    ]

    /// True when a path component names a bundle or package folder.
    static func isBundleFolderName(_ name: some StringProtocol) -> Bool {
        bundleFolderExtensions.contains((String(name) as NSString).pathExtension.lowercased())
    }

    /// How many folders sit between an app root and the `.app` at `path`: 0
    /// directly in a root, 1 for `/Applications/Utilities/X.app`, and so on.
    /// Nil when the path is not an `.app` or is outside every root, and nil when
    /// a folder on the way is a bundle or package, a symlink, or hidden: those
    /// are the folders the walk never enters, so the gate refuses exactly what
    /// the picker never lists.
    static func folderDepth(ofAppAtPath path: String, roots: [String]) -> Int? {
        guard (path as NSString).pathExtension == "app" else { return nil }
        for root in roots {
            guard path.hasPrefix(root + "/") else { continue }
            let folders = path.dropFirst(root.count + 1).split(separator: "/").dropLast()
            guard folders.count <= maxFolderDepth else { return nil }
            var folderPath = root
            for folder in folders {
                guard !folder.hasPrefix("."), !isBundleFolderName(folder) else { return nil }
                folderPath += "/" + folder
                let values = try? URL(fileURLWithPath: folderPath)
                    .resourceValues(forKeys: [.isPackageKey, .isSymbolicLinkKey, .isHiddenKey])
                if values?.isPackage == true || values?.isSymbolicLink == true || values?.isHidden == true {
                    return nil
                }
            }
            return folders.count
        }
        return nil
    }

    /// Every `.app` bundle in `root`, at any depth up to `maxFolderDepth`. Never
    /// looks inside a bundle or package and never follows a symlink, so an
    /// app's own internals are never listed.
    ///
    /// Returns nil when `root` cannot be listed, including when it is absent, so
    /// each caller decides what a missing or unreadable root means. A subfolder
    /// that cannot be listed is skipped: it only hides the apps inside it.
    static func appBundleURLs(in root: URL) -> [URL]? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var result: [URL] = []
        func walk(_ entries: [URL], depth: Int) {
            for entry in entries {
                if entry.pathExtension == "app" {
                    result.append(entry)
                    continue
                }
                guard depth < maxFolderDepth, !isBundleFolderName(entry.lastPathComponent) else { continue }
                // `isDirectory` is false for a symlink, so a link to a folder is
                // never followed.
                let values = try? entry.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true,
                      values?.isPackage != true,
                      values?.isSymbolicLink != true else { continue }
                let children = (try? fm.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                )) ?? []
                walk(children, depth: depth + 1)
            }
        }
        walk(entries, depth: 0)
        return result
    }

    /// Reads `Info.plist` directly rather than through `Bundle(url:)`, which
    /// caches per path for the life of the process.
    static func readInfoPlist(at bundleURL: URL) -> [String: Any] {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        return NSDictionary(contentsOf: plistURL) as? [String: Any] ?? [:]
    }
}

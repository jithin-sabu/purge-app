import Foundation

/// Where the App Uninstaller looks for apps inside `/Applications` and
/// `~/Applications`: how deep, which folders it never enters, and which apps it
/// leaves out.
///
/// The picker, the delete gate, the Finder service check, the removal watcher,
/// the orphan index, and the root helper all read this one rule, so an app the
/// picker lists can always be trashed and is always watched. The watch agent and
/// the root helper compile this file too, so it uses Foundation only.
nonisolated enum AppBundleReach {
    /// How many folders below an app root an app bundle can sit and still be
    /// listed. One covers vendor folders like `/Applications/Utilities/X.app`; two
    /// covers vendors that add a product folder, like
    /// `/Applications/Autodesk/AutoCAD 2026/AutoCAD 2026.app` (#143). Deeper is
    /// left out: on a real Mac it holds suite parts, such as Adobe's
    /// `/Applications/Utilities/Adobe Sync/CoreSync/Core Sync.app`, that break the
    /// suite if removed on their own.
    static let maxFolderDepth = 2

    /// Folder extensions that mark a bundle or package. The walk never goes
    /// inside one, so an app's own internals are never listed or deletable.
    static let bundleFolderExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "xpc", "kext", "pkg", "mpkg"
    ]

    /// True when a path component names a bundle or package folder.
    static func isBundleFolderName(_ name: some StringProtocol) -> Bool {
        bundleFolderExtensions.contains((String(name) as NSString).pathExtension.lowercased())
    }

    /// How many folders sit between an app root and the `.app` at `path`: 0
    /// directly in a root, 1 for `/Applications/Utilities/X.app`, and so on.
    /// Nil when the path is not an `.app`, is outside every root, is deeper than
    /// `maxFolderDepth`, or passes through another bundle on the way.
    static func folderDepth(ofAppAtPath path: String, roots: [String]) -> Int? {
        guard (path as NSString).pathExtension == "app" else { return nil }
        for root in roots {
            guard path.hasPrefix(root + "/") else { continue }
            let folders = path.dropFirst(root.count + 1).split(separator: "/").dropLast()
            guard folders.count <= maxFolderDepth,
                  !folders.contains(where: { isBundleFolderName($0) }) else { return nil }
            return folders.count
        }
        return nil
    }

    /// Whether an app's `Info.plist` marks it as a background part of another
    /// app (`LSUIElement` or `LSBackgroundOnly`). Menu bar apps set the same key,
    /// so this only filters bundles at the deepest level (see `isListedApp`).
    static func isBackgroundHelper(info: [String: Any]) -> Bool {
        func isOn(_ value: Any?) -> Bool {
            if let flag = value as? Bool { return flag }
            if let text = value as? String { return ["1", "yes", "true"].contains(text.lowercased()) }
            return false
        }
        return isOn(info["LSUIElement"]) || isOn(info["LSBackgroundOnly"])
    }

    /// Whether a bundle found `depth` folders down is an app the uninstaller
    /// lists. At the deepest level a background helper is left out: that deep
    /// it is almost always part of a suite (Adobe keeps Creative Cloud's helpers
    /// in folders inside Utilities), not an app someone installed.
    static func isListedApp(depth: Int, info: [String: Any]) -> Bool {
        depth < maxFolderDepth || !isBackgroundHelper(info: info)
    }

    /// Every `.app` bundle in `root` up to `maxFolderDepth` folders down, never
    /// looking inside a bundle or package. Bundles at the deepest level that are
    /// background helpers are left out unless `includingHelpers` is set; the
    /// orphan index sets it, since knowing about more apps only makes it keep more.
    ///
    /// Returns nil when `root` cannot be listed, including when it is absent, so
    /// each caller decides what a missing or unreadable root means. A subfolder
    /// that cannot be listed is skipped: it only hides the apps inside it.
    static func appBundleURLs(in root: URL, includingHelpers: Bool = false) -> [URL]? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var result: [URL] = []
        func walk(_ entries: [URL], depth: Int) {
            for entry in entries {
                if entry.pathExtension == "app" {
                    if includingHelpers || depth < maxFolderDepth
                        || isListedApp(depth: depth, info: readInfoPlist(at: entry)) {
                        result.append(entry)
                    }
                    continue
                }
                guard depth < maxFolderDepth, !isBundleFolderName(entry.lastPathComponent) else { continue }
                let values = try? entry.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true, values?.isPackage != true else { continue }
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

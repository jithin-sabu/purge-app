import AppKit
import Foundation

nonisolated func displayDirectoryPath(for directoryURL: URL) -> String {
    abbreviatingHome(
        in: directoryURL.standardizedFileURL.path,
        home: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    )
}

/// `path` with `home` written as `~`, or `path` as it is when it is not in `home`.
nonisolated func abbreviatingHome(in path: String, home homePath: String) -> String {
    let home = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
    guard !home.isEmpty else { return path }
    if path == home { return "~" }
    // A string prefix is not a path prefix: with home `/Users/alice`, the sibling
    // home `/Users/alice2/cache` would abbreviate to `~2/cache`, naming a folder
    // that does not exist. Only a match on a path boundary counts.
    guard PathContainment.isInside(path, home) else { return path }
    return "~" + path.dropFirst(home.count)
}

/// The folder an item sits in, short enough for a row's one detail line:
/// "Application Support" for `~/Library/Application Support/com.app`, and
/// "Application Support › Google" a level deeper. The full path stays in the
/// row's tooltip and Reveal in Finder.
nonisolated func shortLocationLabel(for itemURL: URL) -> String {
    let parent = displayDirectoryPath(for: itemURL.deletingLastPathComponent())
    if parent == "~" { return String(localized: "Home folder") }
    if parent == "~/Library" { return String(localized: "Library") }
    let libraryPrefix = "~/Library/"
    guard parent.hasPrefix(libraryPrefix) else { return parent }
    return parent.dropFirst(libraryPrefix.count)
        .split(separator: "/")
        .joined(separator: " › ")
}

/// Friendly application name for a bundle identifier, or `nil` if no installed app matches.
nonisolated func appDisplayName(forBundleID bundleID: String) -> String? {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        return nil
    }
    return appNameWithoutExtension(FileManager.default.displayName(atPath: appURL.path))
}

/// `FileManager.displayName` keeps ".app" when Finder is set to show every
/// extension, so the same row read "Slack" on one Mac and "Slack.app" on
/// another (#176). The localized name it gives is kept.
nonisolated func appNameWithoutExtension(_ displayName: String) -> String {
    guard displayName.lowercased().hasSuffix(".app"), displayName.count > 4 else { return displayName }
    return String(displayName.dropLast(4))
}

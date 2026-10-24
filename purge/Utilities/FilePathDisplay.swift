import AppKit
import Foundation

nonisolated func displayDirectoryPath(for directoryURL: URL) -> String {
    let directory = directoryURL.standardizedFileURL
    let path = directory.path
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    guard path.hasPrefix(home) else { return path }
    let remainder = String(path.dropFirst(home.count))
    if remainder.isEmpty { return "~" }
    // A string prefix is not a path prefix: with home `/Users/alice`, the sibling
    // home `/Users/alice2/cache` also passes `hasPrefix` and would abbreviate to
    // `~2/cache`, naming a folder that does not exist. Only substitute when the
    // match ends on a path boundary.
    guard remainder.hasPrefix("/") else { return path }
    return "~" + remainder
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

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

/// Friendly application name for a bundle identifier, or `nil` if no installed app matches.
nonisolated func appDisplayName(forBundleID bundleID: String) -> String? {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        return nil
    }
    return FileManager.default.displayName(atPath: appURL.path)
}

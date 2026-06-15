import AppKit
import Foundation

func displayDirectoryPath(for directoryURL: URL) -> String {
    let directory = directoryURL.standardizedFileURL
    let path = directory.path
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    guard path.hasPrefix(home) else { return path }
    let remainder = String(path.dropFirst(home.count))
    if remainder.isEmpty { return "~" }
    return "~" + remainder
}

/// Friendly application name for a bundle identifier, or `nil` if no installed app matches.
func appDisplayName(forBundleID bundleID: String) -> String? {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        return nil
    }
    return FileManager.default.displayName(atPath: appURL.path)
}

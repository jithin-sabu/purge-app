import Foundation

nonisolated struct PermissionChecker {
    /// Returns true when protected Library locations used by deep cache scans are readable.
    /// This is the app's only permission probe: with Full Disk Access granted, every
    /// scanned location (including Downloads/Documents/Desktop) is readable without
    /// per-folder TCC prompts, so nothing may list user content folders before this
    /// returns true — listing them without FDA is exactly what makes macOS show
    /// "Purge would like to access files in your … folder" dialogs.
    func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes: [URL] = [
            home.appendingPathComponent("Library/Safari", isDirectory: true),
            home.appendingPathComponent("Library/Containers", isDirectory: true),
            home.appendingPathComponent("Library/Application Support", isDirectory: true)
        ]

        return probes.allSatisfy(Self.canList)
    }

    /// Reads the first entry rather than the whole listing (#190). macOS refuses a
    /// protected folder on opening it, so the answer is the same, and Containers
    /// alone holds hundreds of entries. An empty folder passes and a missing one
    /// fails, as they did with the full listing.
    static func canList(_ url: URL) -> Bool {
        var failed = false
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [],
            options: [.skipsSubdirectoryDescendants]
        ) { _, _ in
            failed = true
            return false
        }
        guard let enumerator else { return false }
        _ = enumerator.nextObject()
        return !failed
    }
}

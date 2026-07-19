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

        for url in probes {
            do {
                _ = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants]
                )
            } catch {
                return false
            }
        }
        return true
    }
}

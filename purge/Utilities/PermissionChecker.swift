import Foundation

nonisolated struct PermissionChecker {
    /// Returns true when the Large Files feature can read common user content folders.
    /// These locations do not require Full Disk Access; they are separate from Library cache scans.
    func canScanLargeFiles() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let probeFolders = ["Downloads", "Documents", "Desktop", "Movies", "Music", "Pictures"]

        for folder in probeFolders {
            let url = home.appendingPathComponent(folder, isDirectory: true)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                _ = try fm.contentsOfDirectory(
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

    /// Returns true when protected Library locations used by deep cache scans are readable.
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

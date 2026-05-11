import Foundation

struct PermissionChecker {
    func hasFullDiskAccess() -> Bool {
        let protectedURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari", isDirectory: true)

        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: protectedURL,
                includingPropertiesForKeys: nil
            )
            return true
        } catch {
            return false
        }
    }
}

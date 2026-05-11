import Foundation

struct CacheItem: Identifiable, Hashable {
    let id = UUID()
    var appName: String
    let bundleID: String
    let path: URL
    let sizeBytes: Int64
    let lastModified: Date
    var isSelected: Bool
    var safetyInfo: SafetyInfo
    /// Filled asynchronously after scans (Dev Tools use tighter rules elsewhere).
    var reinstallSafety: ReinstallSafetyStatus
    /// Filled asynchronously; `.clean` means no Git repo touched or repo is tidy.
    var gitStatus: GitWorktreeStatus

    var formattedSize: String {
        formatBytes(sizeBytes)
    }

    mutating func applyMetadata(reinstall: ReinstallSafetyStatus, git: GitWorktreeStatus) {
        reinstallSafety = reinstall
        gitStatus = git
    }
}

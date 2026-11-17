import Foundation

enum DeveloperCleaningSettings {
    static let enabledKey = "developerCleaning.enabled"
    static let rootsKey = "developerCleaning.projectRoots"
}

nonisolated struct DeepScanCacheFolder: Identifiable, Sendable {
    let url: URL
    let sizeBytes: Int64
    var id: String { url.path }
}

nonisolated struct DeveloperScanIssue: Hashable, Sendable, Identifiable {
    enum Reason: Hashable, Sendable {
        case unreadable
        case missing
        case depthLimit(Int)
        case entryLimit(Int)
        case unmeasurable
        case linkedCache
    }
    let path: String
    let reason: Reason
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var canScanFromHere: Bool {
        if case .depthLimit = reason { return true }
        return false
    }
    var explanation: String {
        switch reason {
        case .unreadable: return String(localized: "This folder couldn't be read. Check its access permissions in Finder.")
        case .missing: return String(localized: "This folder wasn't found. Update your developer project folders in Settings.")
        case .depthLimit(let depth): return String(localized: "Reached the scan limit of \(depth) folder levels. Scan from here to check this branch directly.")
        case .entryLimit(let count): return String(localized: "More than \(count) entries in this folder. Add a smaller subfolder in Settings to scan it directly.")
        case .unmeasurable: return String(localized: "This folder's size couldn't be measured. Check its access permissions in Finder.")
        case .linkedCache: return String(localized: "The cache folder is a symbolic link. Purge doesn't follow it during this scan.")
        }
    }
}

/// Collects incomplete paths and their actual reasons from the background walk.
nonisolated final class DeepScanIssues: @unchecked Sendable {
    private let lock = NSLock()
    private var issues: [String: DeveloperScanIssue] = [:]
    func add(_ issue: DeveloperScanIssue) { lock.withLock { issues[issue.path] = issue } }
    func snapshot() -> [DeveloperScanIssue] { lock.withLock { issues.values.sorted { $0.path < $1.path } } }
}

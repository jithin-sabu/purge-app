import Foundation

struct CacheLocation: Hashable {
    let path: URL
    let sizeBytes: Int64
    let lastModified: Date
    /// Bundle ID or folder name used when matching explanations.
    let folderName: String
}

struct CacheItem: Identifiable, Hashable {
    /// Canonical `explanations.json` key; `nil` means this row is not merged with others.
    let definitionKey: String?
    let locations: [CacheLocation]
    var appName: String
    var isSelected: Bool
    var safetyInfo: SafetyInfo
    /// Filled asynchronously after scans (Dev Tools use tighter rules elsewhere).
    var reinstallSafety: ReinstallSafetyStatus
    /// Filled asynchronously; `.clean` means no Git repo touched or repo is tidy.
    var gitStatus: GitWorktreeStatus

    var id: String {
        if let definitionKey {
            return "def:\(definitionKey)"
        }
        return "path:\(path.standardizedFileURL.path)"
    }

    var paths: [URL] {
        locations.map(\.path)
    }

    /// Primary path for overrides and legacy call sites.
    var path: URL {
        locations[0].path
    }

    var bundleID: String {
        locations[0].folderName
    }

    var sizeBytes: Int64 {
        locations.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    var lastModified: Date {
        locations.map(\.lastModified).max() ?? .distantPast
    }

    var formattedSize: String {
        formatBytes(sizeBytes)
    }

    func sizeBytes(at path: URL) -> Int64 {
        let key = path.standardizedFileURL.path
        return locations.first { $0.path.standardizedFileURL.path == key }?.sizeBytes ?? 0
    }

    func withLocations(_ locations: [CacheLocation]) -> CacheItem {
        if let definitionKey {
            return CacheItem(
                definitionKey: definitionKey,
                locations: locations,
                appName: appName,
                isSelected: isSelected,
                safetyInfo: safetyInfo,
                reinstallSafety: reinstallSafety,
                gitStatus: gitStatus
            )
        }
        return CacheItem(
            definitionKey: nil,
            location: locations[0],
            appName: appName,
            isSelected: isSelected,
            safetyInfo: safetyInfo,
            reinstallSafety: reinstallSafety,
            gitStatus: gitStatus
        )
    }

    /// Single-location row (ungrouped or provisional before grouping).
    init(
        definitionKey: String?,
        location: CacheLocation,
        appName: String,
        isSelected: Bool = false,
        safetyInfo: SafetyInfo,
        reinstallSafety: ReinstallSafetyStatus = .notApplicable,
        gitStatus: GitWorktreeStatus = .unknown
    ) {
        self.definitionKey = definitionKey
        self.locations = [location]
        self.appName = appName
        self.isSelected = isSelected
        self.safetyInfo = safetyInfo
        self.reinstallSafety = reinstallSafety
        self.gitStatus = gitStatus
    }

    /// Grouped row with one or more locations.
    init(
        definitionKey: String,
        locations: [CacheLocation],
        appName: String,
        isSelected: Bool = false,
        safetyInfo: SafetyInfo,
        reinstallSafety: ReinstallSafetyStatus = .notApplicable,
        gitStatus: GitWorktreeStatus = .unknown
    ) {
        self.definitionKey = definitionKey
        self.locations = locations
        self.appName = appName
        self.isSelected = isSelected
        self.safetyInfo = safetyInfo
        self.reinstallSafety = reinstallSafety
        self.gitStatus = gitStatus
    }
}

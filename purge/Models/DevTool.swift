import Foundation

nonisolated struct DevTool: Identifiable, Hashable {
    /// Canonical `explanations.json` key used for safety copy and grouping.
    let definitionKey: String
    let toolName: String
    let paths: [URL]
    let sizeBytes: Int64
    let pathSizeBytesByPath: [String: Int64]
    let lastModified: Date
    var isSelected: Bool
    let isDetected: Bool
    var safetyInfo: SafetyInfo
    let reinstallSafety: ReinstallSafetyStatus

    /// Built once at init. Every access previously standardized each path (a filesystem
    /// stat), sorted, and joined — and `id` is read per row and per selection lookup
    /// during SwiftUI body evaluation. All inputs are `let`, so this cannot go stale.
    let id: String

    /// Standardized `paths`, in order. Same reasoning as `id`: the safe-cleanup row-hiding
    /// check reads these per tool per render while a cleanup is running.
    let standardizedPaths: [String]

    /// Path used as the user-override key. Defaults to the first declared path
    /// because a tool entry typically resolves to a single canonical folder.
    var primaryOverridePath: URL? { paths.first }

    var formattedSize: String {
        formatBytes(sizeBytes)
    }

    init(
        definitionKey: String,
        toolName: String,
        paths: [URL],
        sizeBytes: Int64,
        pathSizeBytesByPath: [String: Int64] = [:],
        lastModified: Date = .distantPast,
        isSelected: Bool = false,
        isDetected: Bool,
        safetyInfo: SafetyInfo,
        reinstallSafety: ReinstallSafetyStatus = .notApplicable
    ) {
        self.definitionKey = definitionKey
        self.toolName = toolName
        self.paths = paths
        self.sizeBytes = sizeBytes
        self.pathSizeBytesByPath = pathSizeBytesByPath
        self.lastModified = lastModified
        self.isSelected = isSelected
        self.isDetected = isDetected
        self.safetyInfo = safetyInfo
        self.reinstallSafety = reinstallSafety
        let standardized = paths.map { $0.standardizedFileURL.path }
        self.standardizedPaths = standardized
        self.id = Self.id(definitionKey: definitionKey, standardizedPaths: standardized)
    }

    /// A tool from the last scan's saved file (#283). Same id as the scan builds,
    /// from the standardized paths saved with it, so restoring never stats the disk.
    init(
        restoringDefinitionKey definitionKey: String,
        toolName: String,
        paths: [URL],
        standardizedPaths: [String],
        sizeBytes: Int64,
        pathSizeBytesByPath: [String: Int64],
        lastModified: Date,
        isDetected: Bool,
        safetyInfo: SafetyInfo,
        reinstallSafety: ReinstallSafetyStatus
    ) {
        self.definitionKey = definitionKey
        self.toolName = toolName
        self.paths = paths
        self.sizeBytes = sizeBytes
        self.pathSizeBytesByPath = pathSizeBytesByPath
        self.lastModified = lastModified
        self.isSelected = false
        self.isDetected = isDetected
        self.safetyInfo = safetyInfo
        self.reinstallSafety = reinstallSafety
        self.standardizedPaths = standardizedPaths
        self.id = Self.id(definitionKey: definitionKey, standardizedPaths: standardizedPaths)
    }

    private static func id(definitionKey: String, standardizedPaths: [String]) -> String {
        "dev:\(definitionKey):\(standardizedPaths.sorted().joined(separator: "|"))"
    }
}

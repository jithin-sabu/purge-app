import Foundation

struct DevTool: Identifiable, Hashable {
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

    var id: String {
        let pathKey = paths
            .map { $0.standardizedFileURL.path }
            .sorted()
            .joined(separator: "|")
        return "dev:\(definitionKey):\(pathKey)"
    }

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
    }
}

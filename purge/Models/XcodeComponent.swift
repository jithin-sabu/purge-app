import Foundation

/// An optional Xcode component in Apple's asset store, as
/// `xcodebuild -showComponent <name> -json` reports it (#132). Today that is the
/// Metal Toolchain, about 900 MB that many developers never use.
///
/// Purge removes it with `xcodebuild -deleteComponent`, never by touching the
/// files. The asset folder is SIP-protected and Apple's to remove; here it is
/// only a handle for the row, the history entry and Reveal in Finder.
nonisolated struct XcodeComponent: Identifiable, Hashable {
    /// The components Purge offers. `xcodebuild` takes the raw value.
    enum Kind: String, CaseIterable, Sendable {
        case metalToolchain

        /// The folder under AssetsV2 that holds this component's downloads.
        var assetTypeFolderName: String {
            switch self {
            case .metalToolchain: return "com_apple_MobileAsset_MetalToolchain"
            }
        }

        /// The row's name, and the name History gives the asset folder.
        var displayName: String {
            switch self {
            case .metalToolchain: return String(localized: "Metal Toolchain")
            }
        }

        /// The kind whose download `url` is: an `<id>.asset` folder directly in
        /// the kind's AssetsV2 folder. History names such a path by its kind,
        /// since the folder's own name is a hash.
        init?(assetFolder url: URL) {
            let folder = url.standardizedFileURL
            guard folder.pathExtension == "asset" else { return nil }
            let parent = folder.deletingLastPathComponent().lastPathComponent
            guard let kind = Self.allCases.first(where: { $0.assetTypeFolderName == parent }) else { return nil }
            self = kind
        }

        /// The command that brings it back, as the explanation names it.
        var downloadCommand: String {
            switch self {
            case .metalToolchain: return "xcodebuild -downloadComponent MetalToolchain"
            }
        }
    }

    let kind: Kind
    let build: String
    /// The `<id>.asset` folder under AssetsV2 that `xcodebuild` names.
    let assetURL: URL
    let sizeBytes: Int64
    let safetyInfo: SafetyInfo

    var id: String { assetURL.standardizedFileURL.path }
    var formattedSize: String { formatBytes(sizeBytes) }

    /// `safetyInfo` is for tests that force a level; the app always takes the
    /// kind's own, which is Check First.
    init(kind: Kind, build: String, assetURL: URL, sizeBytes: Int64, safetyInfo: SafetyInfo? = nil) {
        self.kind = kind
        self.build = build
        self.assetURL = assetURL
        self.sizeBytes = sizeBytes
        self.safetyInfo = safetyInfo ?? Self.safetyInfo(kind: kind, sizeBytes: sizeBytes)
    }

    // MARK: - Apple's asset store

    /// The folder that holds `kind`'s downloads. Purge only reads here.
    static func assetTypeFolder(for kind: Kind, in root: URL = SimulatorRuntime.mobileAssetRoot) -> URL {
        root.appendingPathComponent(kind.assetTypeFolderName, isDirectory: true)
    }

    /// Whether any `<id>.asset` folder sits in `kind`'s folder. The scan asks this
    /// before it launches `xcodebuild`, because `-showComponent` can mount the
    /// toolchain as a side effect, and most Macs have nothing to find. A folder
    /// that can't be read counts as one that may hold a download.
    static func mayBeInstalled(_ kind: Kind, in root: URL = SimulatorRuntime.mobileAssetRoot) -> Bool {
        let folder = assetTypeFolder(for: kind, in: root)
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .contains { $0.pathExtension == "asset" }
        } catch CocoaError.fileReadNoSuchFile {
            return false
        } catch {
            return true
        }
    }

    // MARK: - What xcodebuild says

    /// One `-showComponent` answer.
    struct Status: Equatable, Sendable {
        /// The component's own `<id>.asset` folder when it is installed. `nil` when
        /// it is not installed, or when the path `xcodebuild` gave is not a direct
        /// child of the component's AssetsV2 folder: Purge never offers or deletes
        /// a component it can't place.
        let installedAsset: URL?
        let build: String?
    }

    /// Reads `xcodebuild -showComponent <name> -json`, or the plain text form,
    /// from stdout. `nil` when neither form can be read. stderr carries log lines
    /// such as "Failed to remount the Metal Toolchain" and is never read.
    static func parseShowComponent(_ data: Data, kind: Kind, assetsRoot: URL = SimulatorRuntime.mobileAssetRoot) -> Status? {
        let fields: [String: String]
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            fields = json.compactMapValues { $0 as? String }
        } else if let text = String(data: data, encoding: .utf8), let parsed = textFields(text) {
            fields = parsed
        } else {
            return nil
        }
        guard let status = fields["status"] else { return nil }
        let build = fields["buildVersion"].flatMap { $0.isEmpty ? nil : $0 }
        guard status.caseInsensitiveCompare("installed") == .orderedSame,
              let assetPath = fields["assetPath"]
        else { return Status(installedAsset: nil, build: build) }
        return Status(installedAsset: assetFolder(fromAssetPath: assetPath, kind: kind, assetsRoot: assetsRoot), build: build)
    }

    /// "Asset Path: …" lines into the JSON keys, so both forms read the same.
    private static func textFields(_ text: String) -> [String: String]? {
        let keys = ["Asset Path": "assetPath", "Build Version": "buildVersion", "Status": "status"]
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard let key = keys[label] else { continue }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields["status"] == nil ? nil : fields
    }

    /// `…/com_apple_MobileAsset_MetalToolchain/<id>.asset/AssetData` to its
    /// `<id>.asset` folder, which must sit directly in the component's own folder.
    static func assetFolder(fromAssetPath path: String, kind: Kind, assetsRoot: URL) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        var folder = URL(fileURLWithPath: path).standardizedFileURL
        while folder.pathExtension != "asset" {
            let parent = folder.deletingLastPathComponent()
            guard parent.path != folder.path else { return nil }
            folder = parent
        }
        let typeFolder = assetTypeFolder(for: kind, in: assetsRoot).standardizedFileURL
        guard folder.deletingLastPathComponent().path == typeFolder.path else { return nil }
        return folder
    }

    // MARK: - Safety

    /// Always Check First. Safe means Clean Safe Items and scheduled cleans take
    /// the item without asking, and they only move things to the Trash, while
    /// `xcodebuild` deletes a component permanently (#136).
    static func safetyInfo(kind: Kind, sizeBytes: Int64) -> SafetyInfo {
        switch kind {
        case .metalToolchain:
            return SafetyInfo(
                level: .medium,
                headline: kind.displayName,
                explanation: String(localized: "Xcode's compiler for Metal shaders, an optional download that every account on this Mac shares. Xcode downloads it again (\(formatBytes(sizeBytes))) when a project needs it, or run \(kind.downloadCommand)."),
                recoverySteps: "",
                reinstallCommand: nil
            )
        }
    }
}

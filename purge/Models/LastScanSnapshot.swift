import Foundation

/// What the last finished scan found, kept across launches so a reopen has rows to
/// show while the new scan runs (#283).
///
/// These rows are for looking at only. The store keeps them apart from its live
/// lists, so no selection, clean, menu bar count or scheduled clean ever reads them;
/// each one gives way to its live twin as the scan finds it again. Large Files keeps
/// only its total (`ScanRecord`), and no row under a protected folder is ever
/// written, so the file holds nothing from Desktop, Documents, Downloads or iCloud.
nonisolated struct LastScanSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = Self.currentVersion
    /// The build that wrote it. Another build may judge the same folder differently,
    /// so its rows are dropped rather than shown with an old safety level.
    var appBuild: String
    var appCaches: Section<SavedCacheItem>?
    var devTools: Section<SavedDevTool>?
    var simulators: Section<SavedSimulatorDevice>?
    var runtimes: Section<SavedSimulatorRuntime>?
    var projects: Section<SavedProjectGroup>?
    var apps: Section<SavedInstalledApp>?
    var leftovers: Section<SavedLeftover>?

    struct Section<Row: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        var savedAt: Date
        var rows: [Row]
    }

    init(appBuild: String) {
        self.appBuild = appBuild
    }

    /// The build number of the running app, which a snapshot must match to be shown.
    static func currentAppBuild(bundle: Bundle = .main) -> String {
        bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    /// True when `url` sits outside every folder macOS protects, by name and through
    /// any link on the way: `~/Developer` linked to `~/Documents/dev` puts a project
    /// "in Developer" inside Documents. A path that fails is never written, since the
    /// file lives where any app can read it. Follows links with `readlink` only (the
    /// same walk a limited scan uses), so it never prompts, but it reads the disk:
    /// call it off the main thread.
    static func isWritable(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        !ProtectedLocations.contains(url, home: home)
            && ProtectedLocations.isReadable(url, access: .limited, home: home)
    }

    /// Takes `section` from `other`, including its absence.
    mutating func copy(_ section: LastScanSection, from other: LastScanSnapshot) {
        switch section {
        case .appCaches: appCaches = other.appCaches
        case .devTools: devTools = other.devTools
        case .simulators: simulators = other.simulators
        case .runtimes: runtimes = other.runtimes
        case .projects: projects = other.projects
        case .apps: apps = other.apps
        case .leftovers: leftovers = other.leftovers
        }
    }

    /// Drops the rows `isRemoved` matches. A cache row or a project loses only the
    /// matching locations or folders, and goes once it has none left.
    mutating func removeRows(where isRemoved: (URL) -> Bool) {
        if var section = appCaches {
            section.rows = section.rows.compactMap { row in
                var row = row
                row.locations.removeAll { isRemoved($0.path) }
                return row.locations.isEmpty ? nil : row
            }
            appCaches = section
        }
        devTools?.rows.removeAll { $0.paths.contains(where: isRemoved) }
        simulators?.rows.removeAll { isRemoved($0.folderURL) }
        runtimes?.rows.removeAll { isRemoved($0.locationURL) }
        if var section = projects {
            section.rows = section.rows.compactMap { group in
                guard !isRemoved(group.rootPath) else { return nil }
                var group = group
                group.artifacts.removeAll { isRemoved($0.path) }
                return group.artifacts.isEmpty ? nil : group
            }
            projects = section
        }
        apps?.rows.removeAll { isRemoved($0.bundleURL) }
        leftovers?.rows.removeAll { isRemoved($0.path) }
    }
}

/// One list the snapshot keeps, and the scan step that refreshes it.
nonisolated enum LastScanSection: String, CaseIterable, Sendable {
    case appCaches
    case devTools
    case simulators
    case runtimes
    case projects
    case apps
    case leftovers

    var step: ScanStep {
        switch self {
        case .appCaches, .devTools, .simulators, .runtimes, .projects: return .cachesAndDevTools
        case .apps: return .apps
        case .leftovers: return .leftovers
        }
    }
}

// MARK: - Rows

nonisolated struct SavedSafety: Codable, Equatable, Sendable {
    var level: SafetyLevel
    var headline: String
    var explanation: String
    var recoverySteps: String
    var reinstallCommand: String?

    init(_ info: SafetyInfo) {
        level = info.level
        headline = info.headline
        explanation = info.explanation
        recoverySteps = info.recoverySteps
        reinstallCommand = info.reinstallCommand
    }

    var info: SafetyInfo {
        SafetyInfo(
            level: level,
            headline: headline,
            explanation: explanation,
            recoverySteps: recoverySteps,
            reinstallCommand: reinstallCommand
        )
    }
}

nonisolated struct SavedCacheItem: Codable, Equatable, Sendable {
    struct Location: Codable, Equatable, Sendable {
        var path: URL
        var standardizedPath: String
        var sizeBytes: Int64
        var lastModified: Date
        var folderName: String
    }

    var definitionKey: String?
    var locations: [Location]
    var appName: String
    var safety: SavedSafety
    var reinstallSafety: String
    var gitStatus: String

    init(_ item: CacheItem) {
        definitionKey = item.definitionKey
        locations = zip(item.locations, item.standardizedPaths).map { location, standardized in
            Location(
                path: location.path,
                standardizedPath: standardized,
                sizeBytes: location.sizeBytes,
                lastModified: location.lastModified,
                folderName: location.folderName
            )
        }
        appName = item.appName
        safety = SavedSafety(item.safetyInfo)
        reinstallSafety = item.reinstallSafety.rawValue
        gitStatus = item.gitStatus.rawValue
    }

    var urls: [URL] { locations.map(\.path) }

    /// Nil when the saved row is unusable, for example an empty location list.
    var restored: CacheItem? {
        guard !locations.isEmpty else { return nil }
        return CacheItem(
            restoringDefinitionKey: definitionKey,
            locations: locations.map {
                CacheLocation(path: $0.path, sizeBytes: $0.sizeBytes, lastModified: $0.lastModified, folderName: $0.folderName)
            },
            standardizedPaths: locations.map(\.standardizedPath),
            appName: appName,
            safetyInfo: safety.info,
            reinstallSafety: ReinstallSafetyStatus(rawValue: reinstallSafety) ?? .notApplicable,
            gitStatus: GitWorktreeStatus(rawValue: gitStatus) ?? .unknown
        )
    }
}

nonisolated struct SavedDevTool: Codable, Equatable, Sendable {
    var definitionKey: String
    var toolName: String
    var paths: [URL]
    var standardizedPaths: [String]
    var sizeBytes: Int64
    var pathSizeBytesByPath: [String: Int64]
    var lastModified: Date
    var isDetected: Bool
    var safety: SavedSafety
    var reinstallSafety: String

    init(_ tool: DevTool) {
        definitionKey = tool.definitionKey
        toolName = tool.toolName
        paths = tool.paths
        standardizedPaths = tool.standardizedPaths
        sizeBytes = tool.sizeBytes
        pathSizeBytesByPath = tool.pathSizeBytesByPath
        lastModified = tool.lastModified
        isDetected = tool.isDetected
        safety = SavedSafety(tool.safetyInfo)
        reinstallSafety = tool.reinstallSafety.rawValue
    }

    var urls: [URL] { paths }

    var restored: DevTool? {
        guard !paths.isEmpty, paths.count == standardizedPaths.count else { return nil }
        return DevTool(
            restoringDefinitionKey: definitionKey,
            toolName: toolName,
            paths: paths,
            standardizedPaths: standardizedPaths,
            sizeBytes: sizeBytes,
            pathSizeBytesByPath: pathSizeBytesByPath,
            lastModified: lastModified,
            isDetected: isDetected,
            safetyInfo: safety.info,
            reinstallSafety: ReinstallSafetyStatus(rawValue: reinstallSafety) ?? .notApplicable
        )
    }
}

nonisolated struct SavedSimulatorDevice: Codable, Equatable, Sendable {
    var id: UUID
    var deviceName: String
    var runtimeVersion: String
    var isAvailable: Bool
    var lastBootedAt: Date?
    var sizeOnDisk: Int64?
    var folderURL: URL
    var safety: SavedSafety

    init(_ device: SimulatorDevice) {
        id = device.id
        deviceName = device.deviceName
        runtimeVersion = device.runtimeVersion
        isAvailable = device.isAvailable
        lastBootedAt = device.lastBootedAt
        sizeOnDisk = device.sizeOnDisk
        folderURL = device.folderURL
        safety = SavedSafety(device.safetyInfo)
    }

    var urls: [URL] { [folderURL] }

    var restored: SimulatorDevice? {
        SimulatorDevice(
            id: id,
            deviceName: deviceName,
            runtimeVersion: runtimeVersion,
            isAvailable: isAvailable,
            lastBootedAt: lastBootedAt,
            sizeOnDisk: sizeOnDisk,
            folderURL: folderURL,
            isSelected: false,
            safetyInfo: safety.info
        )
    }
}

nonisolated struct SavedSimulatorRuntime: Codable, Equatable, Sendable {
    var id: String
    var runtimeIdentifier: String
    var platformName: String
    var version: String
    var build: String
    var kind: String
    var state: String
    var sizeBytes: Int64
    var lastUsedAt: Date?
    var deviceCount: Int?
    var locationURL: URL
    var safety: SavedSafety

    init(_ runtime: SimulatorRuntime) {
        id = runtime.id
        runtimeIdentifier = runtime.runtimeIdentifier
        platformName = runtime.platformName
        version = runtime.version
        build = runtime.build
        kind = runtime.kind
        state = runtime.state
        sizeBytes = runtime.sizeBytes
        lastUsedAt = runtime.lastUsedAt
        deviceCount = runtime.deviceCount
        locationURL = runtime.locationURL
        safety = SavedSafety(runtime.safetyInfo)
    }

    var urls: [URL] { [locationURL] }

    var restored: SimulatorRuntime? {
        SimulatorRuntime(
            id: id,
            runtimeIdentifier: runtimeIdentifier,
            platformName: platformName,
            version: version,
            build: build,
            kind: kind,
            state: state,
            sizeBytes: sizeBytes,
            lastUsedAt: lastUsedAt,
            deviceCount: deviceCount,
            locationURL: locationURL,
            safetyInfo: safety.info
        )
    }
}

nonisolated struct SavedProjectGroup: Codable, Equatable, Sendable {
    struct Artifact: Codable, Equatable, Sendable {
        var kind: String
        var path: URL
        var projectRoot: URL
        var sizeBytes: Int64
        var lastModified: Date
        var safety: SavedSafety
        var reinstallSafety: String
        var gitStatus: String
        var checkFirstReason: String?
    }

    var displayName: String
    var rootPath: URL
    var inferredTypes: [String]
    var artifacts: [Artifact]

    init(_ group: ProjectGroup) {
        displayName = group.displayName
        rootPath = group.rootPath
        inferredTypes = group.inferredTypes.map(\.rawValue)
        artifacts = group.artifacts.map { artifact in
            Artifact(
                kind: artifact.kind.rawValue,
                path: artifact.path,
                projectRoot: artifact.projectRoot,
                sizeBytes: artifact.sizeBytes,
                lastModified: artifact.lastModified,
                safety: SavedSafety(artifact.safetyInfo),
                reinstallSafety: artifact.reinstallSafety.rawValue,
                gitStatus: artifact.gitStatus.rawValue,
                checkFirstReason: artifact.checkFirstReason.map(Self.name(of:))
            )
        }
    }

    var urls: [URL] { [rootPath] + artifacts.map(\.path) }

    /// Nil when nothing in it can be rebuilt, for example an artifact kind this
    /// build no longer knows.
    var restored: ProjectGroup? {
        let rebuilt: [ProjectCacheArtifact] = artifacts.compactMap { saved in
            guard let kind = DeletableArtifactKind(rawValue: saved.kind) else { return nil }
            return ProjectCacheArtifact(
                kind: kind,
                path: saved.path,
                projectRoot: saved.projectRoot,
                sizeBytes: saved.sizeBytes,
                lastModified: saved.lastModified,
                isSelected: false,
                safetyInfo: saved.safety.info,
                reinstallSafety: ReinstallSafetyStatus(rawValue: saved.reinstallSafety) ?? .notApplicable,
                gitStatus: GitWorktreeStatus(rawValue: saved.gitStatus) ?? .unknown,
                checkFirstReason: saved.checkFirstReason.flatMap(Self.reason(named:))
            )
        }
        guard !rebuilt.isEmpty else { return nil }
        return ProjectGroup(
            displayName: displayName,
            rootPath: rootPath,
            inferredTypes: inferredTypes.compactMap(ProjectType.init(rawValue:)),
            artifacts: rebuilt
        )
    }

    private static func name(of reason: ProjectCheckFirstReason) -> String {
        switch reason {
        case .usedRecently: return "usedRecently"
        case .tooBigToCheck: return "tooBigToCheck"
        }
    }

    private static func reason(named name: String) -> ProjectCheckFirstReason? {
        switch name {
        case "usedRecently": return .usedRecently
        case "tooBigToCheck": return .tooBigToCheck
        default: return nil
        }
    }
}

nonisolated struct SavedInstalledApp: Codable, Equatable, Sendable {
    var name: String
    var bundleURL: URL
    var bundleID: String?
    var bundleSizeBytes: Int64
    var lastOpened: Date?
    var caskToken: String?
    var caskPrefix: URL?
    /// The app plus its leftovers, as measured; nil when the scan had not got to it.
    var removableBytes: Int64?

    init(_ app: InstalledApp, removableBytes: Int64?) {
        name = app.name
        bundleURL = app.bundleURL
        bundleID = app.bundleID
        bundleSizeBytes = app.bundleSizeBytes
        lastOpened = app.lastOpened
        caskToken = app.homebrewCask?.token
        caskPrefix = app.homebrewCask?.prefix
        self.removableBytes = removableBytes
    }

    var urls: [URL] { [bundleURL] }

    /// Never running: whether it runs now is this session's question.
    var restored: InstalledApp? {
        var cask: HomebrewCask?
        if let caskToken, let caskPrefix {
            cask = HomebrewCask(token: caskToken, prefix: caskPrefix)
        }
        return InstalledApp(
            name: name,
            bundleURL: bundleURL,
            bundleID: bundleID,
            bundleSizeBytes: bundleSizeBytes,
            isRunning: false,
            lastOpened: lastOpened,
            homebrewCask: cask
        )
    }
}

nonisolated struct SavedLeftover: Codable, Equatable, Sendable {
    var path: URL
    var sizeBytes: Int64
    var category: String
    var safety: SavedSafety
    var matchReason: String
    var keptForApp: String?
    var lastModified: Date
    var ownerBundleIDs: [String]

    init(_ item: UninstallItem) {
        path = item.path
        sizeBytes = item.sizeBytes
        category = item.category.rawValue
        safety = SavedSafety(item.safetyInfo)
        matchReason = Self.name(of: item.matchReason)
        keptForApp = item.keptForApp
        lastModified = item.lastModified
        ownerBundleIDs = item.ownerBundleIDs
    }

    var urls: [URL] { [path] }

    var restored: UninstallItem? {
        guard let category = UninstallCategory(rawValue: category),
              let reason = Self.reason(named: matchReason) else { return nil }
        return UninstallItem(
            path: path,
            sizeBytes: sizeBytes,
            category: category,
            safetyInfo: safety.info,
            matchReason: reason,
            isSelected: false,
            keptForApp: keptForApp,
            lastModified: lastModified,
            ownerBundleIDs: ownerBundleIDs
        )
    }

    private static func name(of reason: MatchReason) -> String {
        switch reason {
        case .appBundle: return "appBundle"
        case .bundleID: return "bundleID"
        case .groupID: return "groupID"
        case .appName: return "appName"
        case .ownerLedger: return "ownerLedger"
        case .libraryCrossEvidence: return "libraryCrossEvidence"
        case .dotFolderCatalog: return "dotFolderCatalog"
        }
    }

    private static func reason(named name: String) -> MatchReason? {
        switch name {
        case "appBundle": return .appBundle
        case "bundleID": return .bundleID
        case "groupID": return .groupID
        case "appName": return .appName
        case "ownerLedger": return .ownerLedger
        case "libraryCrossEvidence": return .libraryCrossEvidence
        case "dotFolderCatalog": return .dotFolderCatalog
        default: return nil
        }
    }
}

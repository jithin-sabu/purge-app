import Foundation

enum DeveloperScanEvent {
    case status(String)
    case devToolFound(DevTool)
    case devToolSizeResolved(id: String, pathSizeBytesByPath: [String: Int64], sizeBytes: Int64, lastModified: Date)
    case projectGroupFound(ProjectGroup)
    case simulatorFound(SimulatorDevice)
    case simulatorSizeResolved(id: UUID, sizeBytes: Int64)
}

final class DevScanner {
    private struct DevToolSizeJob {
        let toolID: String
        let toolLabel: String
        let paths: [URL]
    }

    /// Maps scanner labels to keys in `explanations.json`.
    private static let toolExplanationKeys: [String: String] = [
        "Xcode Derived Data": "DerivedData",
        "Xcode iOS DeviceSupport": "xcode-device-support",
        "Xcode Archives": "xcode-archives",
        "Xcode Caches": "xcode-app",
        "Homebrew Cache": "homebrew-cache",
        "Gradle Cache": "gradle-cache",
        "Docker Desktop": "docker",
        "npm Cache": "npm-cache",
        "pnpm Store": "pnpm-store",
        "Yarn Cache": "yarn-cache",
        "CocoaPods": "cocoapods-cache",
        "Flutter Cache": "flutter-cache",
        "Android SDK .gradle": "android-sdk",
        "Git Worktrees": "gitworktrees",
        "VS Code Cache": "vscode",
        "Cursor Cache": "cursor",
        "JetBrains Cache": "jetbrains",
        "Zed Cache": "zed",
        "Go Module Cache": "go",
        "Maven Cache": "maven",
        "SBT Cache": "sbt",
        "Ruby Gems": "rubygems",
        "Bundler Cache": "bundler",
        "Composer Cache": "composer",
        "Cargo Registry": "cargo",
        "Terraform Cache": "terraform",
        "GitHub Actions Cache": "githubactions",
        "Vagrant Cache": "vagrant",
        "Zsh Cache": "zsh",
        "Electron App Caches": "electron",
        "Playwright Browsers": "ms-playwright",
        "npm npx Cache": "npm-npx-cache",
        "npm Logs": "npm-logs",
        "Xcode Documentation Cache": "xcode-docs-cache",
        "Corepack Cache": "corepack-cache",
        "Obsolete Cursor Extension": "obsolete-cursor-extension",
        "Obsolete VS Code Extension": "obsolete-vscode-extension"
    ]

    private func safetyInfo(forToolLabel toolLabel: String, primaryPath: URL?) -> SafetyInfo {
        Self.automaticSafetyInfo(forDevToolLabel: toolLabel, primaryPath: primaryPath)
    }

    /// Shared automatic safety resolution for global dev tool rows (scan + reset/recategorize).
    nonisolated static func automaticSafetyInfo(forDevToolLabel toolLabel: String, primaryPath: URL?) -> SafetyInfo {
        let key = toolExplanationKeys[toolLabel] ?? toolLabel
        if toolLabel == "Xcode Archives", let path = primaryPath {
            let base = SafetyInfo.fromExplanationDatabase(
                key: key,
                friendlyFallback: toolLabel,
                path: path
            )
            if UserOverridesStore.read(path: path) != nil { return base }
            if folderContainsXCArchive(at: path) { return base }
            return SafetyInfo(
                level: .safe,
                headline: base.headline,
                explanation: base.explanation,
                recoverySteps: base.recoverySteps,
                reinstallCommand: base.reinstallCommand
            )
        }
        return SafetyInfo.fromExplanationDatabase(
            key: key,
            friendlyFallback: toolLabel,
            path: primaryPath
        )
    }

    nonisolated static func folderContainsXCArchive(at root: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(".xcarchive") else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return true
            }
        }
        return false
    }

    nonisolated static func daysBetween(_ start: Date, _ end: Date) -> Int {
        Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
    }

    func scanDevToolsStream() -> AsyncStream<DeveloperScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runDeveloperScan(continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func discoverProjectsStream() -> AsyncStream<DeveloperScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .background) { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                continuation.yield(.status("Scanning Developer Projects..."))
                _ = await self.discoverProjects(continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runDeveloperScan(continuation: AsyncStream<DeveloperScanEvent>.Continuation) async {
        continuation.yield(.status("Scanning Dev Tools..."))
        let globalDiscoveryStart = Date()
        let (tools, toolSizeJobs) = scanGlobalCachePlaceholders()
        ScanPhaseTiming.finish(
            "global dev tool discovery",
            since: globalDiscoveryStart,
            detail: "\(tools.count) tools, \(toolSizeJobs.count) size jobs"
        )
        for tool in tools {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            continuation.yield(.devToolFound(tool))
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [toolSizeJobs] in
                continuation.yield(.status("Calculating Dev Tool sizes..."))
                let sizingStart = Date()
                await self.runDevToolSizeJobs(toolSizeJobs, continuation: continuation)
                let pathCount = toolSizeJobs.reduce(0) { $0 + $1.paths.count }
                ScanPhaseTiming.finish(
                    "global dev tool sizing",
                    since: sizingStart,
                    detail: "\(toolSizeJobs.count) tools, \(pathCount) paths"
                )
            }

            group.addTask {
                if Task.isCancelled { return }
                continuation.yield(.status("Scanning iOS Simulators..."))
                let simDiscoveryStart = Date()
                let simulators = await self.discoverShutdownSimulatorsWithoutSizes()
                ScanPhaseTiming.finish(
                    "simulator discovery",
                    since: simDiscoveryStart,
                    detail: "\(simulators.count) shutdown simulators"
                )
                for simulator in simulators {
                    if Task.isCancelled { return }
                    continuation.yield(.simulatorFound(simulator))
                }
                let simSizingStart = Date()
                await self.runSimulatorSizeJobs(simulators, continuation: continuation)
                ScanPhaseTiming.finish(
                    "simulator sizing",
                    since: simSizingStart,
                    detail: "\(simulators.count) device folders"
                )
            }
        }

        continuation.finish()
    }

    // MARK: - iOS Simulators

    /// Metadata only (`sizeOnDisk` is `nil`). Requires `xcrun` and a CoreSimulator devices folder.
    func discoverShutdownSimulatorsWithoutSizes() async -> [SimulatorDevice] {
        let devicesRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
        guard FileManager.default.fileExists(atPath: devicesRoot.path) else { return [] }
        guard FileManager.default.isExecutableFile(atPath: Self.xcrunPath) else { return [] }

        let devices = await loadSimulatorsFromSimctl(devicesRoot: devicesRoot)
            ?? loadSimulatorsFromPlistFiles(devicesRoot: devicesRoot)
        return devices.filter { !ExcludedPathsStore.isExcluded($0.folderURL) }
    }

    private static let xcrunPath = "/usr/bin/xcrun"

    private func loadSimulatorsFromSimctl(devicesRoot: URL) async -> [SimulatorDevice]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.xcrunPath)
        process.arguments = ["simctl", "list", "devices", "--json"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesMap = root["devices"] as? [String: Any] else {
            return nil
        }

        var built: [SimulatorDevice] = []
        for (runtimeKey, rawList) in devicesMap {
            guard let deviceDicts = rawList as? [[String: Any]] else { continue }
            let runtimeVersion = Self.runtimeVersionLabel(from: runtimeKey)

            for dict in deviceDicts {
                guard let udidString = dict["udid"] as? String,
                      let id = UUID(uuidString: udidString) else { continue }

                let stateString = dict["state"] as? String ?? ""
                if stateString == "Booted" { continue }

                let name = dict["name"] as? String ?? "Simulator"
                let isAvailable = (dict["isAvailable"] as? Bool) ?? true

                let lastBootedAt: Date?
                if let iso = dict["lastBootedAt"] as? String {
                    lastBootedAt = ISO8601DateFormatter().date(from: iso)
                } else {
                    lastBootedAt = nil
                }

                let folderURL: URL
                if let dataPathStr = dict["dataPath"] as? String {
                    let dataURL = URL(fileURLWithPath: dataPathStr, isDirectory: true)
                    folderURL = dataURL.deletingLastPathComponent()
                } else {
                    folderURL = devicesRoot.appendingPathComponent(udidString, isDirectory: true)
                }

                guard folderURL.standardizedFileURL.path.hasPrefix(devicesRoot.standardizedFileURL.path) else { continue }
                guard FileManager.default.fileExists(atPath: folderURL.path) else { continue }

                let safety = SimulatorDevice.safetyInfo(
                    isAvailable: isAvailable,
                    lastBootedAt: lastBootedAt,
                    deviceName: name,
                    runtimeVersion: runtimeVersion
                )

                built.append(
                    SimulatorDevice(
                        id: id,
                        deviceName: name,
                        runtimeVersion: runtimeVersion,
                        isAvailable: isAvailable,
                        lastBootedAt: lastBootedAt,
                        sizeOnDisk: nil,
                        folderURL: folderURL,
                        isSelected: false,
                        safetyInfo: safety
                    )
                )
            }
        }

        return dedupeSimulators(built)
    }

    private func loadSimulatorsFromPlistFiles(devicesRoot: URL) -> [SimulatorDevice] {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let top = try? fm.contentsOfDirectory(
            at: devicesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for u in top {
                guard (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let name = u.lastPathComponent
                if name == "unavailable" {
                    if let inner = try? fm.contentsOfDirectory(
                        at: u,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) {
                        for innerURL in inner where (try? innerURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                            candidates.append(innerURL)
                        }
                    }
                } else if UUID(uuidString: name) != nil {
                    candidates.append(u)
                }
            }
        }

        var built: [SimulatorDevice] = []
        for folder in candidates {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            let plistURL = folder.appendingPathComponent("device.plist")
            guard let plist = NSDictionary(contentsOf: plistURL) as? [String: Any] else { continue }

            if let stateNum = plist["state"] as? Int, stateNum == 3 { continue }
            if let stateStr = plist["state"] as? String, stateStr == "Booted" { continue }

            let name = plist["name"] as? String ?? "Simulator"
            let runtimeKey = plist["runtime"] as? String ?? ""
            let runtimeVersion = Self.runtimeVersionLabel(from: runtimeKey)

            let lastBootedAt = plist["lastBootedAt"] as? Date
                ?? (plist["lastBootedAt"] as? TimeInterval).map { Date(timeIntervalSinceReferenceDate: $0) }

            let isAvailable = !folder.path.contains("/Devices/unavailable/")

            let safety = SimulatorDevice.safetyInfo(
                isAvailable: isAvailable,
                lastBootedAt: lastBootedAt,
                deviceName: name,
                runtimeVersion: runtimeVersion.isEmpty ? "Unknown runtime" : runtimeVersion
            )

            built.append(
                SimulatorDevice(
                    id: id,
                    deviceName: name,
                    runtimeVersion: runtimeVersion.isEmpty ? "Unknown runtime" : runtimeVersion,
                    isAvailable: isAvailable,
                    lastBootedAt: lastBootedAt,
                    sizeOnDisk: nil,
                    folderURL: folder,
                    isSelected: false,
                    safetyInfo: safety
                )
            )
        }

        return dedupeSimulators(built)
    }

    private func dedupeSimulators(_ items: [SimulatorDevice]) -> [SimulatorDevice] {
        var seen = Set<UUID>()
        var out: [SimulatorDevice] = []
        for d in items where !seen.contains(d.id) {
            seen.insert(d.id)
            out.append(d)
        }
        return out
    }

    private nonisolated static func runtimeVersionLabel(from runtimeKey: String) -> String {
        guard !runtimeKey.isEmpty else { return "Unknown runtime" }
        guard let range = runtimeKey.range(of: "SimRuntime.") else {
            return runtimeKey.replacingOccurrences(of: "-", with: " ")
        }
        let tail = String(runtimeKey[range.upperBound...])
        let parts = tail.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            return tail.replacingOccurrences(of: "-", with: ".")
        }
        let platform = String(parts[0])
        let version = String(parts[1]).replacingOccurrences(of: "-", with: ".")
        return "\(platform) \(version)"
    }

    // MARK: - Global dev tool caches

    /// Standardized paths owned by the Dev Tools scan. The general cache scan skips
    /// these up front so they don't surface under App Caches and then get removed
    /// once the dev scan claims them.
    nonisolated static func claimedGlobalCachePaths() -> Set<String> {
        Set(globalCacheDefinitions().flatMap(\.paths).map { $0.standardizedFileURL.path })
    }

    private nonisolated static func globalCacheDefinitions() -> [(label: String, paths: [URL])] {
        let home = FileManager.default.homeDirectoryForCurrentUser

        return [
            ("Xcode Derived Data", [home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)]),
            ("Xcode Archives", [home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true)]),
            ("Xcode iOS DeviceSupport", [home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true)]),
            ("Xcode Caches", [home.appendingPathComponent("Library/Caches/com.apple.dt.Xcode", isDirectory: true)]),
            ("Xcode Documentation Cache", [
                home.appendingPathComponent("Library/Developer/Xcode/DocumentationCache", isDirectory: true)
            ]),
            ("CocoaPods", [home.appendingPathComponent(".cocoapods/repos", isDirectory: true)]),
            ("Homebrew Cache", [home.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)]),
            ("npm Cache", [home.appendingPathComponent(".npm/_cacache", isDirectory: true)]),
            ("npm npx Cache", [home.appendingPathComponent(".npm/_npx", isDirectory: true)]),
            ("npm Logs", [home.appendingPathComponent(".npm/_logs", isDirectory: true)]),
            ("Corepack Cache", [home.appendingPathComponent(".cache/node/corepack", isDirectory: true)]),
            ("pnpm Store", [home.appendingPathComponent(".pnpm-store", isDirectory: true)]),
            ("Yarn Cache", [home.appendingPathComponent("Library/Caches/Yarn", isDirectory: true)]),
            ("Gradle Cache", [home.appendingPathComponent(".gradle/caches", isDirectory: true)]),
            ("Flutter Cache", [home.appendingPathComponent(".flutter", isDirectory: true)]),
            ("Android SDK .gradle", [home.appendingPathComponent(".android", isDirectory: true)]),
            ("Docker Desktop", [home.appendingPathComponent("Library/Containers/com.docker.docker", isDirectory: true)]),

            ("Git Worktrees", [
                home.appendingPathComponent(".git/worktrees", isDirectory: true)
            ]),

            ("VS Code Cache", [
                home.appendingPathComponent("Library/Application Support/Code/Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Code/CachedData", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Code/CachedExtensionVSIXs", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Code/User/workspaceStorage", isDirectory: true)
            ]),
            ("Cursor Cache", [
                home.appendingPathComponent("Library/Application Support/Cursor/Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Cursor/CachedData", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage", isDirectory: true)
            ]),
            ("JetBrains Cache", [
                home.appendingPathComponent("Library/Caches/JetBrains", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/JetBrains", isDirectory: true)
            ]),
            ("Zed Cache", [
                home.appendingPathComponent("Library/Application Support/Zed/db", isDirectory: true),
                home.appendingPathComponent("Library/Caches/Zed", isDirectory: true)
            ]),

            ("Go Module Cache", [
                home.appendingPathComponent("go/pkg/mod/cache", isDirectory: true),
                home.appendingPathComponent(".cache/go-build", isDirectory: true)
            ]),

            ("Maven Cache", [
                home.appendingPathComponent(".m2/repository", isDirectory: true)
            ]),
            ("SBT Cache", [
                home.appendingPathComponent(".sbt", isDirectory: true),
                home.appendingPathComponent(".ivy2/cache", isDirectory: true)
            ]),

            ("Ruby Gems", [
                home.appendingPathComponent(".gem", isDirectory: true)
            ]),
            ("Bundler Cache", [
                home.appendingPathComponent(".bundle/cache", isDirectory: true)
            ]),

            ("Composer Cache", [
                home.appendingPathComponent(".composer/cache", isDirectory: true)
            ]),

            ("Cargo Registry", [
                home.appendingPathComponent(".cargo/registry", isDirectory: true),
                home.appendingPathComponent(".cargo/git", isDirectory: true)
            ]),

            ("Terraform Cache", [
                home.appendingPathComponent(".terraform.d/plugin-cache", isDirectory: true)
            ]),

            ("GitHub Actions Cache", [
                home.appendingPathComponent(".cache/act", isDirectory: true)
            ]),

            ("Vagrant Cache", [
                home.appendingPathComponent(".vagrant.d/boxes", isDirectory: true),
                home.appendingPathComponent(".vagrant.d/tmp", isDirectory: true)
            ]),

            ("Zsh Cache", [
                home.appendingPathComponent(".zsh_sessions", isDirectory: true),
                home.appendingPathComponent(".zcompdump", isDirectory: false)
            ]),

            ("Electron App Caches", [
                home.appendingPathComponent("Library/Application Support/Slack/Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Slack/Code Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/discord/Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/discord/Code Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Notion/Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Figma/Cache", isDirectory: true)
            ]),

            ("Playwright Browsers", [
                home.appendingPathComponent("Library/Caches/ms-playwright", isDirectory: true),
                home.appendingPathComponent(".cache/ms-playwright", isDirectory: true)
            ])
        ]
    }

    private func scanGlobalCachePlaceholders() -> ([DevTool], [DevToolSizeJob]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let staticDefinitions = Self.globalCacheDefinitions() + discoverObsoleteEditorExtensionDefinitions(home: home)

        let built = staticDefinitions.compactMap { entry -> DevTool? in
            let label = entry.label
            let paths = entry.paths
            let existing = paths.filter {
                FileManager.default.fileExists(atPath: $0.path)
                    && DeletionSafetyPolicy.isOfferedForCleanup($0)
                    && !ExcludedPathsStore.isExcluded($0)
            }
            guard !existing.isEmpty else { return nil }

            let definitionKey = Self.toolExplanationKeys[label] ?? label
            let reinstall = reinstallRollup(for: existing)
            return DevTool(
                definitionKey: definitionKey,
                toolName: label,
                paths: existing.map(\.standardizedFileURL),
                sizeBytes: 0,
                pathSizeBytesByPath: [:],
                lastModified: .distantPast,
                isSelected: false,
                isDetected: true,
                safetyInfo: safetyInfo(
                    forToolLabel: label,
                    primaryPath: existing.first
                ),
                reinstallSafety: reinstall
            )
        }

        let tools = groupDevToolsByDefinitionKey(built)
        let jobs = tools.map {
            DevToolSizeJob(toolID: $0.id, toolLabel: $0.toolName, paths: $0.paths)
        }
        return (tools, jobs)
    }

    private func discoverObsoleteEditorExtensionDefinitions(home: URL) -> [(label: String, paths: [URL])] {
        let cursor = obsoleteExtensionPaths(
            in: home.appendingPathComponent(".cursor/extensions", isDirectory: true),
            label: "Obsolete Cursor Extension"
        )
        let vscode = obsoleteExtensionPaths(
            in: home.appendingPathComponent(".vscode/extensions", isDirectory: true),
            label: "Obsolete VS Code Extension"
        )
        return cursor + vscode
    }

    private func obsoleteExtensionPaths(in extensionsRoot: URL, label: String) -> [(label: String, paths: [URL])] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: extensionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var grouped: [String: [(version: String, url: URL)]] = [:]
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let folderName = entry.lastPathComponent
            if let parsed = Self.parseExtensionFolderName(folderName) {
                grouped[parsed.base, default: []].append((parsed.version, entry.standardizedFileURL))
            } else {
                grouped[folderName, default: []].append(("0", entry.standardizedFileURL))
            }
        }

        var results: [(label: String, paths: [URL])] = []
        for (_, versions) in grouped {
            guard versions.count > 1 else { continue }
            let sorted = versions.sorted { Self.compareExtensionVersions($0.version, $1.version) == .orderedDescending }
            for obsolete in sorted.dropFirst() {
                let folderName = obsolete.url.lastPathComponent
                results.append(("\(label): \(folderName)", [obsolete.url]))
            }
        }
        return results
    }

    nonisolated static func parseExtensionFolderName(_ folderName: String) -> (base: String, version: String)? {
        let pattern = #"^(.+)-(\d+\.\d+\.\d+(?:[-.][A-Za-z0-9]+)*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: folderName, range: NSRange(folderName.startIndex..., in: folderName)),
              match.numberOfRanges == 3,
              let baseRange = Range(match.range(at: 1), in: folderName),
              let versionRange = Range(match.range(at: 2), in: folderName) else {
            return nil
        }
        return (String(folderName[baseRange]), String(folderName[versionRange]))
    }

    nonisolated static func compareExtensionVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: "-").first.map(String.init) ?? lhs
        let right = rhs.split(separator: "-").first.map(String.init) ?? rhs
        let leftParts = left.split(separator: ".").compactMap { Int($0) }
        let rightParts = right.split(separator: ".").compactMap { Int($0) }
        let maxCount = max(leftParts.count, rightParts.count)
        for index in 0..<maxCount {
            let l = index < leftParts.count ? leftParts[index] : 0
            let r = index < rightParts.count ? rightParts[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private func groupDevToolsByDefinitionKey(_ tools: [DevTool]) -> [DevTool] {
        var byKey: [String: [DevTool]] = [:]
        for tool in tools {
            byKey[tool.definitionKey, default: []].append(tool)
        }

        return byKey.map { key, members in
            mergeDevTools(definitionKey: key, members: members)
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func mergeDevTools(definitionKey: String, members: [DevTool]) -> DevTool {
        guard members.count > 1 else { return members[0] }

        let anchor = members.max(by: { $0.paths.count < $1.paths.count }) ?? members[0]
        var seenPaths = Set<String>()
        var mergedPaths: [URL] = []
        for member in members {
            for path in member.paths {
                let pathKey = path.standardizedFileURL.path
                guard !seenPaths.contains(pathKey) else { continue }
                seenPaths.insert(pathKey)
                mergedPaths.append(path)
            }
        }

        let existing = mergedPaths.filter { FileManager.default.fileExists(atPath: $0.path) }
        var pathSizes: [String: Int64] = [:]
        for path in existing {
            let key = path.standardizedFileURL.path
            pathSizes[key] = members.compactMap { $0.pathSizeBytesByPath[key] }.first ?? 0
        }
        let size = pathSizes.values.reduce(Int64(0), +)
        let modified = members.map(\.lastModified).max() ?? .distantPast

        return DevTool(
            definitionKey: definitionKey,
            toolName: anchor.toolName,
            paths: existing.map(\.standardizedFileURL),
            sizeBytes: size,
            pathSizeBytesByPath: pathSizes,
            lastModified: modified,
            isSelected: members.contains(where: \.isSelected),
            isDetected: !existing.isEmpty,
            safetyInfo: anchor.safetyInfo,
            reinstallSafety: reinstallRollup(for: existing)
        )
    }

    private func runDevToolSizeJobs(
        _ jobs: [DevToolSizeJob],
        continuation: AsyncStream<DeveloperScanEvent>.Continuation
    ) async {
        guard !jobs.isEmpty else { return }

        let allPaths = jobs.flatMap(\.paths)
        let sizesByPath = FolderSizing.directorySizes(at: allPaths)

        for job in jobs {
            if Task.isCancelled { return }

            var pathSizes: [String: Int64] = [:]
            var modified = Date.distantPast
            for path in job.paths {
                let standardized = path.standardizedFileURL
                let pathKey = standardized.path
                pathSizes[pathKey] = sizesByPath[pathKey] ?? 0
                modified = max(modified, FolderSizing.contentModificationDate(at: standardized))
            }

            let total = pathSizes.values.reduce(Int64(0), +)
            continuation.yield(.devToolSizeResolved(
                id: job.toolID,
                pathSizeBytesByPath: pathSizes,
                sizeBytes: total,
                lastModified: modified
            ))
        }
    }

    private func runSimulatorSizeJobs(
        _ devices: [SimulatorDevice],
        continuation: AsyncStream<DeveloperScanEvent>.Continuation
    ) async {
        guard !devices.isEmpty else { return }

        let folderURLs = devices.map(\.folderURL)
        let sizesByPath = FolderSizing.directorySizes(at: folderURLs)

        for device in devices {
            if Task.isCancelled { return }
            let pathKey = device.folderURL.standardizedFileURL.path
            let size = sizesByPath[pathKey] ?? 0
            continuation.yield(.simulatorSizeResolved(id: device.id, sizeBytes: size))
        }
    }

    private func reinstallRollup(for paths: [URL]) -> ReinstallSafetyStatus {
        guard !paths.isEmpty else { return .notApplicable }
        let values = paths.map { ReinstallSafetyEvaluator.evaluateByFolderNameDeleting(path: $0) }
        if values.contains(.missingLockfile) { return .missingLockfile }
        if values.allSatisfy({ $0 == .notApplicable }) { return .notApplicable }
        return .reinstallable
    }

    // MARK: - Project-aware scan

    private static let maxDirectoryEntriesBeforeSkip = 2000

    private func discoverProjects(
        maxDepth: Int = 4,
        continuation: AsyncStream<DeveloperScanEvent>.Continuation? = nil
    ) async -> [ProjectGroup] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home,
            home.appendingPathComponent("Developer", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Projects", isDirectory: true),
            home.appendingPathComponent("projects", isDirectory: true),
            home.appendingPathComponent("Code", isDirectory: true),
            home.appendingPathComponent("code", isDirectory: true),
            home.appendingPathComponent("Work", isDirectory: true),
            home.appendingPathComponent("work", isDirectory: true),
            home.appendingPathComponent("dev", isDirectory: true),
            home.appendingPathComponent("Dev", isDirectory: true),
            home.appendingPathComponent("src", isDirectory: true),
            home.appendingPathComponent("Src", isDirectory: true),
            home.appendingPathComponent("repos", isDirectory: true),
            home.appendingPathComponent("Repos", isDirectory: true),
            home.appendingPathComponent("GitHub", isDirectory: true),
            home.appendingPathComponent("github", isDirectory: true),
            home.appendingPathComponent("GitLab", isDirectory: true),
            home.appendingPathComponent("gitlab", isDirectory: true),
            home.appendingPathComponent("Sites", isDirectory: true),
            home.appendingPathComponent("sites", isDirectory: true),
            home.appendingPathComponent("workspace", isDirectory: true),
            home.appendingPathComponent("Workspace", isDirectory: true),
            home.appendingPathComponent("coding", isDirectory: true),
            home.appendingPathComponent("Coding", isDirectory: true),
            home.appendingPathComponent("apps", isDirectory: true),
            home.appendingPathComponent("Apps", isDirectory: true),
        ]

        let walkStart = Date()
        let fm = FileManager.default
        var discoveredRoots: [(URL, [ProjectType])] = []
        var directoriesWalked = 0

        func shouldSkipDescending(into name: String) -> Bool {
            switch name {
            case ".git", "node_modules", "Pods", "DerivedData", ".gradle":
                return true
            case ".dart_tool":
                return true
            case "venv", ".venv":
                return true
            case "target":
                return true
            case "build":
                return true
            case "android", "ios":
                return true
            default:
                return false
            }
        }

        func listTypes(at directory: URL) -> [ProjectType] {
            var result: Set<ProjectType> = []

            let packageJSON = directory.appendingPathComponent("package.json").path
            if fm.fileExists(atPath: packageJSON) {
                result.insert(.node)
            }

            if fm.fileExists(atPath: directory.appendingPathComponent("Cargo.toml").path) {
                result.insert(.rust)
            }

            if fm.fileExists(atPath: directory.appendingPathComponent("pubspec.yaml").path) {
                result.insert(.flutter)
            }

            if fm.fileExists(atPath: directory.appendingPathComponent("requirements.txt").path)
                || fm.fileExists(atPath: directory.appendingPathComponent("pyproject.toml").path) {
                result.insert(.python)
            }

            if hasGradleMarker(in: directory) {
                result.insert(.androidGradle)
            }

            if containsXcodeBundle(in: directory) {
                result.insert(.xcode)
            }

            return Array(result).sorted { String(describing: $0) < String(describing: $1) }
        }

        func walk(directory: URL, depth: Int, maxDepth: Int) {
            guard depth <= maxDepth else { return }
            directoriesWalked += 1

            let types = listTypes(at: directory)
            if !types.isEmpty {
                discoveredRoots.append((directory, types))
            }

            guard depth < maxDepth else { return }

            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                    options: [.skipsPackageDescendants]
                )
            } catch {
                return
            }

            guard entries.count <= Self.maxDirectoryEntriesBeforeSkip else { return }

            for entry in entries {
                let name = entry.lastPathComponent
                /// Skip invisible dot folders (noise and huge caches handled elsewhere).
                if name.hasPrefix(".") { continue }

                if shouldSkipDescending(into: name) { continue }

                var isDirectory = false
                if let v = try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
                    isDirectory = v
                }
                guard isDirectory else { continue }

                walk(directory: entry, depth: depth + 1, maxDepth: maxDepth)
            }
        }

        for root in roots where fm.fileExists(atPath: root.path) {
            // When the root is the home directory itself, limit to depth 1
            // to avoid scanning deep into personal folders like Documents recursively
            // since those are already covered by their own dedicated root entries above
            let effectiveMaxDepth = (root.path == home.path) ? 1 : maxDepth
            walk(directory: root, depth: 0, maxDepth: effectiveMaxDepth)
        }

        // Deduplicate by project root path, keeping the first occurrence
        var seen = Set<String>()
        discoveredRoots = discoveredRoots.filter { root in
            guard !seen.contains(root.0.path) else { return false }
            seen.insert(root.0.path)
            return true
        }

        discoveredRoots.sort { $0.0.path.count < $1.0.path.count }

        ScanPhaseTiming.finish(
            "discoverProjects walk",
            since: walkStart,
            detail: "walked \(directoriesWalked) directories, found \(discoveredRoots.count) project roots"
        )

        /// Build artifact list per root (expensive sizing runs concurrently).
        let sizingStart = Date()
        let (groups, artifactsSized) = await buildProjectGroups(for: discoveredRoots, continuation: continuation)
        ScanPhaseTiming.finish(
            "project artifact sizing",
            since: sizingStart,
            detail: "\(artifactsSized) artifacts sized, \(groups.count) project groups"
        )
        return groups
    }

    private func containsXcodeBundle(in directory: URL) -> Bool {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return children.contains { child in
            let name = child.lastPathComponent
            return name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace")
        }
    }

    private func hasGradleMarker(in directory: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("build.gradle").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("build.gradle.kts").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("settings.gradle").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("settings.gradle.kts").path) {
            return true
        }
        let android = directory.appendingPathComponent("android", isDirectory: true)
        return fm.fileExists(atPath: android.appendingPathComponent("build.gradle").path)
            || fm.fileExists(atPath: android.appendingPathComponent("build.gradle.kts").path)
    }

    private func buildProjectGroups(
        for discovered: [(URL, [ProjectType])],
        continuation: AsyncStream<DeveloperScanEvent>.Continuation? = nil
    ) async -> (groups: [ProjectGroup], artifactsSized: Int) {
        guard !discovered.isEmpty else { return ([], 0) }

        return await withTaskGroup(of: (ProjectGroup?, Int).self) { group in
            for (rootURL, types) in discovered {
                group.addTask { [rootURL, types] in
                    let rows = DevScanner.collectArtifacts(projectRoot: rootURL, types: types)
                    guard !rows.isEmpty else { return (nil, 0) }

                    let artifactPaths = rows.map(\.path)
                    let sizesByPath = FolderSizing.directorySizes(at: artifactPaths)

                    var sized: [ProjectCacheArtifact] = []
                    for row in rows {
                        let pathKey = row.path.standardizedFileURL.path
                        let bytes = sizesByPath[pathKey] ?? 0
                        let modified = FolderSizing.contentModificationDate(at: row.path)
                        sized.append(
                            ProjectCacheArtifact(
                                kind: row.kind,
                                path: row.path,
                                projectRoot: row.projectRoot,
                                sizeBytes: bytes,
                                lastModified: modified,
                                isSelected: false,
                                safetyInfo: row.safetyInfo,
                                reinstallSafety: row.reinstallSafety,
                                gitStatus: .unknown
                            )
                        )
                    }
                    sized.sort { $0.sizeBytes > $1.sizeBytes }

                    let staleDays = DevToolsStalenessOption.currentThresholdDays()
                    let now = Date()
                    let staleArtifacts: [ProjectCacheArtifact]
                    if staleDays == DevToolsStalenessOption.showAll.rawValue {
                        staleArtifacts = sized
                    } else {
                        staleArtifacts = sized.filter {
                            Self.daysBetween($0.lastModified, now) >= staleDays
                        }
                    }

                    guard !staleArtifacts.isEmpty else { return (nil, rows.count) }

                    return (
                        ProjectGroup(
                            displayName: rootURL.lastPathComponent,
                            rootPath: rootURL,
                            inferredTypes: types,
                            artifacts: staleArtifacts
                        ),
                        rows.count
                    )
                }
            }

            var groups: [ProjectGroup] = []
            var artifactsSized = 0
            for await result in group {
                artifactsSized += result.1
                if let g = result.0 {
                    groups.append(g)
                    continuation?.yield(.projectGroupFound(g))
                }
            }
            return (groups, artifactsSized)
        }
    }

    private struct SizedArtifactIntermediate {
        let kind: DeletableArtifactKind
        let path: URL
        let projectRoot: URL
        let safetyInfo: SafetyInfo
        let reinstallSafety: ReinstallSafetyStatus
    }

    private nonisolated static func collectArtifacts(projectRoot root: URL, types: [ProjectType]) -> [SizedArtifactIntermediate] {
        let fm = FileManager.default
        var artifacts: [SizedArtifactIntermediate] = []

        func addIfDir(kind: DeletableArtifactKind, url: URL) {
            guard fm.fileExists(atPath: url.path) else { return }
            guard DeletionSafetyPolicy.isOfferedForCleanup(url) else { return }
            // Also drops every artifact under an excluded project root, since the store
            // matches ancestors — that is how a whole-project exclusion takes effect.
            guard !ExcludedPathsStore.isExcluded(url) else { return }
            var isDir = false
            if let rv = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
                isDir = rv
            }
            guard isDir else { return }

            let reinstall = Self.reinstallCommand(kind: kind, root: root)
            let safety = SafetyInfo.forStaleProjectArtifact(
                kind: kind,
                path: url,
                reinstallCommand: reinstall
            )
            let reinstallStatus = ReinstallSafetyEvaluator.evaluate(artifactKind: kind, artifactURL: url)
            artifacts.append(
                SizedArtifactIntermediate(
                    kind: kind,
                    path: url,
                    projectRoot: root,
                    safetyInfo: safety,
                    reinstallSafety: reinstallStatus
                )
            )
        }

        var hasNode = false
        var hasRust = false
        var hasFlutter = false
        var hasPython = false
        var hasAndroidGradle = false
        var hasXcode = false
        for t in types {
            switch t {
            case .node: hasNode = true
            case .rust: hasRust = true
            case .flutter: hasFlutter = true
            case .python: hasPython = true
            case .androidGradle: hasAndroidGradle = true
            case .xcode: hasXcode = true
            }
        }

        if hasNode,
           fm.fileExists(atPath: root.appendingPathComponent("package.json").path) {
            addIfDir(kind: .nodeModules, url: root.appendingPathComponent("node_modules", isDirectory: true))
        }

        if hasRust,
           fm.fileExists(atPath: root.appendingPathComponent("Cargo.toml").path) {
            addIfDir(kind: .target, url: root.appendingPathComponent("target", isDirectory: true))
        }

        if hasFlutter,
           fm.fileExists(atPath: root.appendingPathComponent("pubspec.yaml").path) {
            addIfDir(kind: .dartTool, url: root.appendingPathComponent(".dart_tool", isDirectory: true))
            addIfDir(kind: .flutterBuild, url: root.appendingPathComponent("build", isDirectory: true))
        }

        if hasPython {
            addIfDir(kind: .venv, url: root.appendingPathComponent("venv", isDirectory: true))
            addIfDir(kind: .venv, url: root.appendingPathComponent(".venv", isDirectory: true))
        }

        if hasAndroidGradle {
            addIfDir(kind: .dotGradle, url: root.appendingPathComponent(".gradle", isDirectory: true))
        }

        if hasXcode {
            addIfDir(kind: .pods, url: root.appendingPathComponent("Pods", isDirectory: true))
            addIfDir(kind: .pods, url: root.appendingPathComponent("ios").appendingPathComponent("Pods", isDirectory: true))
        }

        var unique: [String: SizedArtifactIntermediate] = [:]
        for a in artifacts {
            unique[a.path.path] = a
        }
        return Array(unique.values)
    }

    private nonisolated static func reinstallCommand(kind: DeletableArtifactKind, root: URL) -> String? {
        switch kind {
        case .nodeModules:
            let pm = NodePackageManager.detect(in: root)
            return "cd \"\(root.path)\" && \(pm.installCommand)"
        case .target:
            return "cd \"\(root.path)\" && cargo build"
        case .venv:
            return "Use your usual steps to recreate the Python environment for this folder."
        case .dotGradle:
            return "Run your usual project build so Android or Java tools fetch what they need again."
        case .pods:
            let ios = root.appendingPathComponent("ios", isDirectory: true)
            if FileManager.default.fileExists(atPath: ios.appendingPathComponent("Podfile").path) {
                return "cd \"\(ios.path)\" && pod install"
            }
            return "cd \"\(root.path)\" && pod install"
        case .dartTool, .flutterBuild:
            return "cd \"\(root.path)\" && flutter pub get"
        }
    }
}

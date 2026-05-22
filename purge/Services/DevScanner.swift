import Foundation

/// Result of filesystem discovery for Dev Tools.
struct DeveloperScanOutcome {
    let tools: [DevTool]
    let projects: [ProjectGroup]
    let simulators: [SimulatorDevice]
}

final class DevScanner {
    /// Maps scanner labels to keys in `explanations.json`.
    private static let toolExplanationKeys: [String: String] = [
        "Xcode Derived Data": "DerivedData",
        "Xcode iOS DeviceSupport": "iOS DeviceSupport",
        "Xcode Archives": "archives",
        "Xcode Caches": "xcode",
        "Homebrew Cache": "homebrew",
        "Gradle Cache": "gradle",
        "Docker Desktop": "docker",
        "npm Cache": "npm",
        "pnpm Store": "pnpm",
        "Yarn Cache": "yarn",
        "CocoaPods": "cocoapods",
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
        "Playwright Browsers": "playwright"
    ]

    private func safetyInfo(forToolLabel toolLabel: String, primaryPath: URL?) -> SafetyInfo {
        let key = Self.toolExplanationKeys[toolLabel] ?? toolLabel
        return SafetyInfo.fromExplanationDatabase(
            key: key,
            friendlyFallback: toolLabel,
            path: primaryPath
        )
    }

    func scanDevTools() async -> DeveloperScanOutcome {
        let tools = scanGlobalCaches()
        async let projects = discoverProjects()
        async let simulators = discoverShutdownSimulatorsWithoutSizes()
        let (projectList, simulatorList) = await (projects, simulators)
        return DeveloperScanOutcome(
            tools: tools.sorted { $0.sizeBytes > $1.sizeBytes },
            projects: projectList.sorted { $0.totalBytes > $1.totalBytes },
            simulators: simulatorList.sorted { ($0.sizeOnDisk ?? 0) > ($1.sizeOnDisk ?? 0) }
        )
    }

    // MARK: - iOS Simulators

    /// Full pipeline: discover shutdown simulators, then measure every device folder on disk.
    func loadSimulators() async -> [SimulatorDevice] {
        let discovered = await discoverShutdownSimulatorsWithoutSizes()
        return await measureSimulatorFolderSizes(discovered)
    }

    /// Metadata only (`sizeOnDisk` is `nil`). Requires `xcrun` and a CoreSimulator devices folder.
    func discoverShutdownSimulatorsWithoutSizes() async -> [SimulatorDevice] {
        let devicesRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
        guard FileManager.default.fileExists(atPath: devicesRoot.path) else { return [] }
        guard FileManager.default.isExecutableFile(atPath: Self.xcrunPath) else { return [] }

        if let fromSimctl = await loadSimulatorsFromSimctl(devicesRoot: devicesRoot) {
            return fromSimctl
        }
        return loadSimulatorsFromPlistFiles(devicesRoot: devicesRoot)
    }

    /// Fills `sizeOnDisk` for each row (can be slow for many devices).
    func measureSimulatorFolderSizes(_ devices: [SimulatorDevice]) async -> [SimulatorDevice] {
        guard !devices.isEmpty else { return [] }
        return await withTaskGroup(of: (UUID, Int64).self) { group in
            for device in devices {
                let id = device.id
                let folderURL = device.folderURL
                group.addTask {
                    let bytes = FolderSizing.directoryByteSize(at: folderURL)
                    return (id, bytes)
                }
            }
            var sizeByID: [UUID: Int64] = [:]
            for await (id, size) in group {
                sizeByID[id] = size
            }
            return devices.map { d in
                var copy = d
                copy.sizeOnDisk = sizeByID[d.id] ?? 0
                return copy
            }
        }
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

    // MARK: - Docker size calculation

    private func dockerDiskUsageBytes() -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        process.arguments = ["system", "df", "--format", "{{json .}}"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    return parseDockerDFOutput(output)
                }
            }
        } catch {}

        let home = FileManager.default.homeDirectoryForCurrentUser
        let rawPaths = [
            home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"),
            home.appendingPathComponent("Library/Group Containers/group.com.docker/Data/vms/0/data/Docker.raw")
        ]

        for path in rawPaths {
            if FileManager.default.fileExists(atPath: path.path) {
                if let values = try? path.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                   let allocated = values.totalFileAllocatedSize, allocated > 0 {
                    return Int64(allocated)
                }
            }
        }

        let containerPath = home.appendingPathComponent(
            "Library/Containers/com.docker.docker", isDirectory: true
        )
        return FolderSizing.directoryByteSize(at: containerPath)
    }

    private func parseDockerDFOutput(_ output: String) -> Int64 {
        var total: Int64 = 0
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sizeString = json["Size"] as? String else { continue }
            total += parseDockerSizeString(sizeString)
        }
        return total
    }

    private func parseDockerSizeString(_ size: String) -> Int64 {
        let trimmed = size.trimmingCharacters(in: .whitespaces)
        if trimmed == "0B" || trimmed == "0" { return 0 }

        let units: [(String, Int64)] = [
            ("TB", 1_000_000_000_000),
            ("GB", 1_000_000_000),
            ("MB", 1_000_000),
            ("KB", 1_000),
            ("B", 1)
        ]

        for (unit, multiplier) in units {
            if trimmed.hasSuffix(unit) {
                let numberString = String(trimmed.dropLast(unit.count))
                if let value = Double(numberString) {
                    return Int64(value * Double(multiplier))
                }
            }
        }
        return 0
    }

    // MARK: - Folder sizing (hard-link-aware)

    private func accurateFolderSize(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", url.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return FolderSizing.directoryByteSize(at: url)
            }

            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""

            // du -sk returns "SIZE\tPATH" where SIZE is in 512-byte blocks
            // multiply by 512 to get bytes
            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\t")
            if let blocks = Int64(parts.first ?? "") {
                return blocks * 512
            }

            return FolderSizing.directoryByteSize(at: url)
        } catch {
            return FolderSizing.directoryByteSize(at: url)
        }
    }

    // MARK: - Global dev tool caches

    private func scanGlobalCaches() -> [DevTool] {
        let home = FileManager.default.homeDirectoryForCurrentUser

        let mapped: [(String, String, [URL])] = [
            ("Xcode Derived Data", "hammer.fill", [home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)]),
            ("Xcode Archives", "archivebox.fill", [home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true)]),
            ("Xcode iOS DeviceSupport", "iphone.gen3", [home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true)]),
            ("Xcode Caches", "shippingbox.fill", [home.appendingPathComponent("Library/Caches/com.apple.dt.Xcode", isDirectory: true)]),
            ("CocoaPods", "shippingbox", [home.appendingPathComponent(".cocoapods/repos", isDirectory: true)]),
            ("Homebrew Cache", "cup.and.saucer.fill", [home.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)]),
            ("npm Cache", "shippingbox.circle.fill", [home.appendingPathComponent(".npm/_cacache", isDirectory: true)]),
            ("pnpm Store", "shippingbox.circle", [home.appendingPathComponent(".pnpm-store", isDirectory: true)]),
            ("Yarn Cache", "tray.full.fill", [home.appendingPathComponent("Library/Caches/Yarn", isDirectory: true)]),
            ("Gradle Cache", "gearshape.2.fill", [home.appendingPathComponent(".gradle/caches", isDirectory: true)]),
            ("Flutter Cache", "swift", [home.appendingPathComponent(".flutter", isDirectory: true)]),
            ("Android SDK .gradle", "android", [home.appendingPathComponent(".android", isDirectory: true)]),
            ("Docker Desktop", "shippingbox.fill", [home.appendingPathComponent("Library/Containers/com.docker.docker", isDirectory: true)]),

            // Git
            ("Git Worktrees", "arrow.triangle.branch", [
                home.appendingPathComponent(".git/worktrees", isDirectory: true)
            ]),

            // IDE Caches
            ("VS Code Cache", "chevron.left.forwardslash.chevron.right", [
                home.appendingPathComponent("Library/Application Support/Code/Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Code/CachedData", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Code/CachedExtensionVSIXs", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Code/User/workspaceStorage", isDirectory: true)
            ]),
            ("Cursor Cache", "cursorarrow", [
                home.appendingPathComponent("Library/Application Support/Cursor/Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Cursor/CachedData", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage", isDirectory: true)
            ]),
            ("JetBrains Cache", "gearshape.2.fill", [
                home.appendingPathComponent("Library/Caches/JetBrains", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/JetBrains", isDirectory: true)
            ]),
            ("Zed Cache", "bolt.fill", [
                home.appendingPathComponent("Library/Application Support/Zed/db", isDirectory: true),
                home.appendingPathComponent("Library/Caches/Zed", isDirectory: true)
            ]),

            // Go
            ("Go Module Cache", "arrow.right.circle.fill", [
                home.appendingPathComponent("go/pkg/mod/cache", isDirectory: true),
                home.appendingPathComponent(".cache/go-build", isDirectory: true)
            ]),

            // Java
            ("Maven Cache", "cup.and.saucer.fill", [
                home.appendingPathComponent(".m2/repository", isDirectory: true)
            ]),
            ("SBT Cache", "terminal.fill", [
                home.appendingPathComponent(".sbt", isDirectory: true),
                home.appendingPathComponent(".ivy2/cache", isDirectory: true)
            ]),

            // Ruby
            ("Ruby Gems", "circle.hexagongrid.fill", [
                home.appendingPathComponent(".gem", isDirectory: true)
            ]),
            ("Bundler Cache", "shippingbox.circle.fill", [
                home.appendingPathComponent(".bundle/cache", isDirectory: true)
            ]),

            // PHP
            ("Composer Cache", "globe", [
                home.appendingPathComponent(".composer/cache", isDirectory: true)
            ]),

            // Rust
            ("Cargo Registry", "gearshape.fill", [
                home.appendingPathComponent(".cargo/registry", isDirectory: true),
                home.appendingPathComponent(".cargo/git", isDirectory: true)
            ]),

            // Terraform
            ("Terraform Cache", "cloud.fill", [
                home.appendingPathComponent(".terraform.d/plugin-cache", isDirectory: true)
            ]),

            // CI/CD
            ("GitHub Actions Cache", "arrow.clockwise.circle.fill", [
                home.appendingPathComponent(".cache/act", isDirectory: true)
            ]),

            // Virtualization
            ("Vagrant Cache", "server.rack", [
                home.appendingPathComponent(".vagrant.d/boxes", isDirectory: true),
                home.appendingPathComponent(".vagrant.d/tmp", isDirectory: true)
            ]),

            // Shell
            ("Zsh Cache", "terminal", [
                home.appendingPathComponent(".zsh_sessions", isDirectory: true),
                home.appendingPathComponent(".zcompdump", isDirectory: false)
            ]),

            // Electron apps
            ("Electron App Caches", "app.badge", [
                home.appendingPathComponent("Library/Application Support/Slack/Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Slack/Code Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/discord/Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/discord/Code Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Notion/Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Figma/Cache", isDirectory: true)
            ]),

            // Playwright
            ("Playwright Browsers", "theatermasks.fill", [
                home.appendingPathComponent("Library/Caches/ms-playwright", isDirectory: true),
                home.appendingPathComponent(".cache/ms-playwright", isDirectory: true)
            ])
        ]

        let xcodeAndDockerLabels: Set<String> = [
            "Xcode Derived Data",
            "Xcode Archives",
            "Xcode iOS DeviceSupport",
            "Xcode Caches",
            "Docker Desktop"
        ]

        return mapped.map { entry -> DevTool in
            let label = entry.0
            let existing = entry.2.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }

            let size: Int64
            if xcodeAndDockerLabels.contains(label) {
                size = existing.reduce(Int64(0)) {
                    $0 + accurateFolderSize(at: $1)
                }
            } else {
                size = existing.reduce(Int64(0)) {
                    $0 + FolderSizing.directoryByteSize(at: $1)
                }
            }

            return DevTool(
                toolName: label,
                iconName: entry.1,
                paths: entry.2,
                sizeBytes: size,
                isSelected: false,
                isDetected: !existing.isEmpty,
                safetyInfo: safetyInfo(
                    forToolLabel: label,
                    primaryPath: entry.2.first
                )
            )
        }
    }

    // MARK: - Project-aware scan

    private func discoverProjects(maxDepth: Int = 6) async -> [ProjectGroup] {
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

        let fm = FileManager.default
        var discoveredRoots: [(URL, [ProjectType])] = []

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

        /// Build artifact list per root (expensive sizing runs concurrently).
        return await buildProjectGroups(for: discoveredRoots)
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

    private func buildProjectGroups(for discovered: [(URL, [ProjectType])]) async -> [ProjectGroup] {
        guard !discovered.isEmpty else { return [] }

        return await withTaskGroup(of: ProjectGroup?.self) { group in
            for (rootURL, types) in discovered {
                group.addTask { [rootURL, types] in
                    let rows = DevScanner.collectArtifacts(projectRoot: rootURL, types: types)
                    guard !rows.isEmpty else { return nil }

                    let sized = await withTaskGroup(of: ProjectCacheArtifact.self) { inner in
                        for row in rows {
                            inner.addTask {
                                let bytes = FolderSizing.directoryByteSize(at: row.path)
                                let modified = FolderSizing.contentModificationDate(at: row.path)
                                return ProjectCacheArtifact(
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
                            }
                        }

                        var built: [ProjectCacheArtifact] = []
                        for await artifact in inner {
                            built.append(artifact)
                        }
                        built.sort { $0.sizeBytes > $1.sizeBytes }
                        return built
                    }

                    guard !sized.isEmpty else { return nil }

                    return ProjectGroup(
                        displayName: rootURL.lastPathComponent,
                        rootPath: rootURL,
                        inferredTypes: types,
                        artifacts: sized
                    )
                }
            }

            var groups: [ProjectGroup] = []
            for await g in group {
                if let g { groups.append(g) }
            }
            return groups
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
            var isDir = false
            if let rv = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
                isDir = rv
            }
            guard isDir else { return }

            let reinstall = Self.reinstallCommand(kind: kind, root: root)
            let safety = SafetyInfo.fromExplanationDatabase(
                key: kind.explanationKey,
                friendlyFallback: kind.rowTag,
                reinstallCommand: reinstall,
                path: url
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

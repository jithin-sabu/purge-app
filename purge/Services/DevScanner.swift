import Foundation

enum DeveloperScanEvent {
    case devToolFound(DevTool)
    case devToolSizeResolved(id: String, pathSizeBytesByPath: [String: Int64], sizeBytes: Int64, lastModified: Date)
    case projectGroupFound(ProjectGroup)
    case simulatorFound(SimulatorDevice)
    case simulatorSizeResolved(id: UUID, sizeBytes: Int64)
    /// Booted simulators, already sized. Shown so their space is accounted for, never
    /// offered: `simctl delete` is not run on a device something may be using.
    case runningSimulatorsFound([SimulatorDevice])
    /// Sized on arrival: `simctl` reports the image size, so there is no sizing pass.
    case simulatorRuntimeFound(SimulatorRuntime)
}

/// `nonisolated` for the same reason as `CacheScanner` — a probe confirmed
/// `runDeveloperScan` was executing on the main thread despite `Task.detached`.
nonisolated final class DevScanner {
    private struct DevToolSizeJob {
        let toolID: String
        let toolLabel: String
        let paths: [URL]
    }

    /// Maps scanner labels to keys in `explanations.json`.
    private static let toolExplanationKeys: [String: String] = [
        "Xcode Derived Data": "DerivedData",
        "Xcode Device Support": "xcode-device-support",
        "Xcode Archives": "xcode-archives",
        "Xcode Caches": "xcode-app",
        "Homebrew Cache": "homebrew-cache",
        "Gradle Cache": "gradle-global-cache",
        "Docker Desktop": "docker",
        "npm Cache": "npm-cache",
        "pnpm Store": "pnpm-store",
        "Yarn Cache": "yarn-cache",
        "CocoaPods": "cocoapods-spec-repos",
        "Android Build Cache": "android-sdk",
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
        PlaywrightBuildScanPolicy.label: PlaywrightBuildScanPolicy.explanationKey,
        "npm npx Cache": "npm-npx-cache",
        "npm Logs": "npm-logs",
        "Xcode Documentation Cache": "xcode-docs-cache",
        "Corepack Cache": "corepack-cache",
        "Cursor Agent Leftovers": "cursor-agent-leftover",
        "Orphaned Git Worktrees": "orphaned-git-worktree",
        "Deno Cache": "deno-cache",
        "Simulator Caches": "coresimulator-caches",
        "Xcode Test Devices": "xctest-devices",
        "Old Claude Code Versions": "old-cli-versions",
        "Old Cursor Agent Versions": "old-cli-versions",
        "Old Grok Versions": "old-cli-versions",
        "Cursor Agent Install Leftovers": "cursor-agent-install-leftovers",
        "Old Claude Code Downloads": "claude-code-downloads",
        "Unused Android System Images": "android-system-images",
        "Old Figma Profiles": "old-figma-profiles",
        "Dart Pub Cache": "pub-cache",
        "pre-commit Environments": "pre-commit-cache",
        "Prisma Engines": "prisma-nodejs",
        "Expo Cache": "expo-cache",
        "pyenv and rbenv Downloads": "version-manager-downloads",
        "Oh My Zsh Cache": "oh-my-zsh-cache",
        "opam Download Cache": "opam-download-cache",
        "Puppeteer Browsers": "puppeteer-browsers",
        "Conda Package Cache": "conda-packages",
        "Dart Analysis Cache": "dart-analysis-cache",
        "Hermes Agent Cache": "hermes-agent-cache",
        "Antigravity Browser Cache": "antigravity-browser-cache",
        "Bun Cache": "bun-cache",
        "nvm Download Cache": "nvm-download-cache",
        "giget Template Cache": "giget-cache",
        "Firebase Emulators": "firebase-emulators",
        "Gradle Logs and Temp Files": "gradle-leftovers",
        "Clang Module Cache": "clang-module-cache",
        "VS Code Old Workspace Data": "orphaned-editor-workspace-storage",
        "Cursor Old Workspace Data": "orphaned-editor-workspace-storage"
    ]

    private func safetyInfo(forToolLabel toolLabel: String, primaryPath: URL?) -> SafetyInfo {
        Self.automaticSafetyInfo(forDevToolLabel: toolLabel, primaryPath: primaryPath)
    }

    /// Shared automatic safety resolution for global dev tool rows (scan + reset).
    nonisolated static func automaticSafetyInfo(forDevToolLabel toolLabel: String, primaryPath: URL?) -> SafetyInfo {
        // One row per NDK version. Each label is its own definition key, so the
        // rows stay apart, and the headline names the version (#324).
        if let version = OldToolVersionScanPolicy.ndkVersion(inLabel: toolLabel) {
            let base = SafetyInfo.fromExplanationDatabase(
                key: OldToolVersionScanPolicy.ndkExplanationKey,
                friendlyFallback: toolLabel,
                path: primaryPath
            )
            return SafetyInfo(
                level: base.level,
                headline: String(localized: "Android NDK \(version)"),
                explanation: base.explanation,
                recoverySteps: base.recoverySteps,
                reinstallCommand: base.reinstallCommand
            )
        }
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

    func scanDevToolsStream(access: ScanAccess) -> AsyncStream<DeveloperScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runDeveloperScan(access: access, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func discoverProjectsStream(access: ScanAccess) -> AsyncStream<DeveloperScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                _ = await self.discoverProjects(access: access, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runDeveloperScan(
        access: ScanAccess,
        continuation: AsyncStream<DeveloperScanEvent>.Continuation
    ) async {
        let globalDiscoveryStart = Date()
        let (tools, toolSizeJobs) = scanGlobalCachePlaceholders(access: access)
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

        // The device rows and the runtime rows' counts read the same device list,
        // so `simctl` lists devices once per scan (#178).
        let deviceListing = DeviceListingOnce.live()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [toolSizeJobs] in
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
                let simDiscoveryStart = Date()
                let listing = await self.discoverSimulatorsWithoutSizes(access: access, deviceListing: deviceListing)
                let simulators = listing.shutdown
                ScanPhaseTiming.finish(
                    "simulator discovery",
                    since: simDiscoveryStart,
                    detail: "\(simulators.count) shutdown simulators, \(listing.running.count) running"
                )
                for simulator in simulators {
                    if Task.isCancelled { return }
                    continuation.yield(.simulatorFound(simulator))
                }
                let simSizingStart = Date()
                await self.runSimulatorSizeJobs(simulators, continuation: continuation)
                if !listing.running.isEmpty, !Task.isCancelled {
                    continuation.yield(.runningSimulatorsFound(Self.sized(listing.running)))
                }
                ScanPhaseTiming.finish(
                    "simulator sizing",
                    since: simSizingStart,
                    detail: "\(simulators.count) device folders"
                )
            }

            group.addTask {
                if Task.isCancelled { return }
                let runtimeStart = Date()
                let runtimes = await self.discoverSimulatorRuntimes(deviceListing: deviceListing)
                ScanPhaseTiming.finish(
                    "simulator runtime discovery",
                    since: runtimeStart,
                    detail: "\(runtimes.count) runtimes"
                )
                for runtime in runtimes {
                    if Task.isCancelled { return }
                    continuation.yield(.simulatorRuntimeFound(runtime))
                }
            }
        }

        continuation.finish()
    }

    // MARK: - Simulator runtimes

    /// Every deletable runtime image `simctl` knows about, sized by `simctl` itself.
    /// Needs no Full Disk Access: the images live outside the home folder and the
    /// listing comes from CoreSimulator, not a directory walk. Works without Xcode
    /// too, through the framework's own `simctl` (see `Simctl`). On a Mac with no
    /// trace of CoreSimulator it launches nothing: the launch scan runs this on
    /// every Mac, and a `/usr/bin` shim run there asks to install the developer
    /// tools (#298).
    func discoverSimulatorRuntimes(
        now: Date = Date(),
        coreSimulatorPresent: Bool = Simctl.coreSimulatorPresent(),
        deviceListing: DeviceListingOnce = .live()
    ) async -> [SimulatorRuntime] {
        guard coreSimulatorPresent else { return [] }
        guard let listing = await Simctl.runAsync(["runtime", "list", "-j"], timeout: Self.simctlListTimeout),
              listing.succeeded else { return [] }

        // Device counts decide Safe versus Check First, so a failed device listing
        // is passed on as "unknown" rather than "none".
        var deviceCounts: [String: Int]?
        if let devices = await deviceListing.output(), devices.succeeded {
            deviceCounts = SimulatorRuntime.deviceCounts(fromDevicesList: devices.stdout)
        }

        // Same for the runtime Xcode builds new simulators on: a failed or empty
        // lookup is "unknown", not "none". The one exception is a Mac without Xcode,
        // reached through the framework's own simctl: there is no SDK to match, so
        // nothing can be a default, and the lookup comes back empty for that reason
        // alone. A refused xcrun leaves the launcher at `.xcrun`, so a Mac whose
        // Xcode license is pending stays "unknown".
        var xcodeBuilds: Set<String>?
        if let match = await Simctl.runAsync(["runtime", "match", "list", "-j"], timeout: Self.simctlListTimeout),
           match.succeeded {
            xcodeBuilds = SimulatorRuntime.xcodeRuntimeBuilds(fromMatchList: match.stdout)
        }
        if xcodeBuilds == nil, Simctl.launcher() == .framework {
            xcodeBuilds = []
        }

        // Only adds a warning, so a failed lookup just leaves it out.
        var deviceReach: [String: SimulatorRuntime.DeviceReach] = [:]
        if let runtimes = await Simctl.runAsync(["list", "runtimes", "-j"], timeout: Self.simctlListTimeout),
           runtimes.succeeded {
            deviceReach = SimulatorRuntime.deviceReachByBuild(fromRuntimesList: runtimes.stdout)
        }

        // An older-format runtime that lives in Apple's download is left out, so a
        // failed read is "unknown" and leaves every older-format one out (#165).
        let downloadBuilds = SimulatorRuntime.downloads().map { Set($0.map(\.build)) }

        return SimulatorRuntime.parseRuntimeList(
            listing.stdout,
            deviceCountsByRuntimeIdentifier: deviceCounts,
            xcodeRuntimeBuilds: xcodeBuilds,
            downloadBuilds: downloadBuilds,
            deviceReachByBuild: deviceReach,
            now: now
        )
        .filter { $0.safetyInfo.level.canSurfaceInScanResults }
        .filter { !ExcludedSimulatorRuntimesStore.isExcluded($0) }
    }

    // MARK: - iOS Simulators

    /// Shut-down simulators, which can be deleted, and every other one, which is
    /// only shown. A booted device is skipped rather than offered, because something
    /// (a test run, the Simulator app) may be using it; one booting, shutting down
    /// or being created is skipped too, and so is a state Purge doesn't know (#178).
    struct SimulatorListing: Equatable {
        var shutdown: [SimulatorDevice] = []
        var running: [SimulatorDevice] = []
    }

    /// Metadata only (`sizeOnDisk` is `nil`). Requires a `simctl` that runs (see
    /// `Simctl`) and a CoreSimulator devices folder.
    func discoverShutdownSimulatorsWithoutSizes(access: ScanAccess = .full) async -> [SimulatorDevice] {
        await discoverSimulatorsWithoutSizes(access: access).shutdown
    }

    func discoverSimulatorsWithoutSizes(
        access: ScanAccess = .full,
        deviceListing: DeviceListingOnce = .live()
    ) async -> SimulatorListing {
        let devicesRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
        guard ProtectedLocations.isReadable(devicesRoot, access: access),
              FileManager.default.fileExists(atPath: devicesRoot.path) else { return SimulatorListing() }

        // `nil` here also covers `Simctl.launcher()` finding no simctl at all.
        let listing = await deviceListing.output()
        var result = simulatorListing(fromListing: listing, devicesRoot: devicesRoot)
        result.shutdown.removeAll { ExcludedPathsStore.isExcluded($0.folderURL) }
        result.running.removeAll { ExcludedPathsStore.isExcluded($0.folderURL) }
        return result
    }

    private static func sized(_ devices: [SimulatorDevice]) -> [SimulatorDevice] {
        let sizesByPath = FolderSizing.directorySizes(at: devices.map(\.folderURL), split: .spread)
        return devices.map { device in
            var sized = device
            sized.sizeOnDisk = sizesByPath[device.folderURL.standardizedFileURL.path] ?? 0
            return sized
        }
    }

    /// CoreSimulator can take a while to answer on a cold first call; past this the plist
    /// fallback is a better answer than a stalled scan.
    fileprivate static let simctlListTimeout: TimeInterval = 30

    /// Runs `simctl list devices -j` the first time it is asked and hands every
    /// later asker the same answer. Nothing runs until someone asks, so a part of
    /// the scan that stops early (no CoreSimulator, no devices folder) launches
    /// nothing (#298).
    actor DeviceListingOnce {
        private let run: @Sendable () async -> ProcessRunner.Output?
        private var listing: Task<ProcessRunner.Output?, Never>?

        init(run: @escaping @Sendable () async -> ProcessRunner.Output?) {
            self.run = run
        }

        static func live() -> DeviceListingOnce {
            DeviceListingOnce { await Simctl.runAsync(["list", "devices", "-j"], timeout: DevScanner.simctlListTimeout) }
        }

        func output() async -> ProcessRunner.Output? {
            if let listing { return await listing.value }
            let run = self.run
            let started = Task { await run() }
            listing = started
            return await started.value
        }
    }

    /// Devices come only from a `simctl` that can also delete them, because the
    /// delete goes through the same `simctl`. The `device.plist` files stand in
    /// only when simctl ran but was slow to list. When it could not be launched,
    /// or failed (Xcode license, out-of-date CoreSimulator), every row offered
    /// would fail to delete (#161), so none are.
    func simulatorDevices(fromListing listing: ProcessRunner.Output?, devicesRoot: URL) -> [SimulatorDevice] {
        simulatorListing(fromListing: listing, devicesRoot: devicesRoot).shutdown
    }

    func simulatorListing(fromListing listing: ProcessRunner.Output?, devicesRoot: URL) -> SimulatorListing {
        guard let listing else { return SimulatorListing() }
        if listing.timedOut { return loadSimulatorsFromPlistFiles(devicesRoot: devicesRoot) }
        guard listing.succeeded else { return SimulatorListing() }
        return parseSimulatorList(listing.stdout, devicesRoot: devicesRoot) ?? SimulatorListing()
    }

    private func parseSimulatorList(_ data: Data, devicesRoot: URL) -> SimulatorListing? {
        guard let list = SimulatorDeviceList.parse(data) else { return nil }

        var built: [SimulatorDevice] = []
        var running: [SimulatorDevice] = []
        // Like before #178, a runtime whose list Purge can't read whole offers none
        // of its devices.
        for (runtimeKey, devices) in list.devicesByRuntime where !list.unreadableRuntimes.contains(runtimeKey) {
            let runtimeVersion = Self.runtimeVersionLabel(from: runtimeKey)

            for entry in devices {
                guard let udidString = entry.udid,
                      let id = UUID(uuidString: udidString) else { continue }

                let isShutDown = entry.state == "Shutdown"
                let name = entry.name ?? String(localized: "Simulator")

                let folderURL: URL
                if let dataPathStr = entry.dataPath {
                    let dataURL = URL(fileURLWithPath: dataPathStr, isDirectory: true)
                    folderURL = dataURL.deletingLastPathComponent()
                } else {
                    folderURL = devicesRoot.appendingPathComponent(udidString, isDirectory: true)
                }

                guard PathContainment.isInside(folderURL.standardizedFileURL.path, devicesRoot.standardizedFileURL.path) else { continue }
                guard FileManager.default.fileExists(atPath: folderURL.path) else { continue }

                let safety = !isShutDown
                    ? SimulatorDevice.runningSafetyInfo(
                        deviceName: name,
                        runtimeVersion: runtimeVersion,
                        isBooted: entry.state == "Booted"
                    )
                    : SimulatorDevice.safetyInfo(
                        isAvailable: entry.isAvailable,
                        lastBootedAt: entry.lastBootedAt,
                        deviceName: name,
                        runtimeVersion: runtimeVersion
                    )

                let device = SimulatorDevice(
                    id: id,
                    deviceName: name,
                    runtimeVersion: runtimeVersion,
                    isAvailable: entry.isAvailable,
                    lastBootedAt: entry.lastBootedAt,
                    sizeOnDisk: nil,
                    folderURL: folderURL,
                    isSelected: false,
                    safetyInfo: safety
                )
                if isShutDown {
                    built.append(device)
                } else {
                    running.append(device)
                }
            }
        }

        return SimulatorListing(shutdown: dedupeSimulators(built), running: dedupeSimulators(running))
    }

    private func loadSimulatorsFromPlistFiles(devicesRoot: URL) -> SimulatorListing {
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
        var running: [SimulatorDevice] = []
        for folder in candidates {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            let plistURL = folder.appendingPathComponent("device.plist")
            guard let plist = NSDictionary(contentsOf: plistURL) as? [String: Any] else { continue }

            // CoreSimulator's numbers: 0 creating, 1 shut down, 2 booting, 3 booted,
            // 4 shutting down. Only a shut-down device is offered, and a missing
            // state is not taken for one (#178).
            let isShutDown = (plist["state"] as? Int) == 1 || (plist["state"] as? String) == "Shutdown"
            let isBooted = (plist["state"] as? Int) == 3 || (plist["state"] as? String) == "Booted"

            let name = plist["name"] as? String ?? String(localized: "Simulator")
            let runtimeKey = plist["runtime"] as? String ?? ""
            let runtimeVersion = Self.runtimeVersionLabel(from: runtimeKey)

            let lastBootedAt = plist["lastBootedAt"] as? Date
                ?? (plist["lastBootedAt"] as? TimeInterval).map { Date(timeIntervalSinceReferenceDate: $0) }

            let isAvailable = !folder.path.contains("/Devices/unavailable/")

            let shownVersion = runtimeVersion.isEmpty ? String(localized: "Unknown runtime") : runtimeVersion
            let safety = !isShutDown
                ? SimulatorDevice.runningSafetyInfo(deviceName: name, runtimeVersion: shownVersion, isBooted: isBooted)
                : SimulatorDevice.safetyInfo(
                    isAvailable: isAvailable,
                    lastBootedAt: lastBootedAt,
                    deviceName: name,
                    runtimeVersion: shownVersion
                )

            let device = SimulatorDevice(
                id: id,
                deviceName: name,
                runtimeVersion: shownVersion,
                isAvailable: isAvailable,
                lastBootedAt: lastBootedAt,
                sizeOnDisk: nil,
                folderURL: folder,
                isSelected: false,
                safetyInfo: safety
            )
            if isShutDown {
                built.append(device)
            } else {
                running.append(device)
            }
        }

        return SimulatorListing(shutdown: dedupeSimulators(built), running: dedupeSimulators(running))
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
        guard !runtimeKey.isEmpty else { return String(localized: "Unknown runtime") }
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Set((globalCacheDefinitions().flatMap(\.paths) + claimedRoots(home: home)).map { $0.standardizedFileURL.path })
    }

    /// Folders claimed by name although no row lists them whole. The JetBrains and
    /// Playwright rows list entries inside their folders, so each folder is
    /// claimed here to keep App Caches off it. Reads nothing.
    nonisolated static func claimedRoots(home: URL) -> [URL] {
        [home.appendingPathComponent("Library/Caches/JetBrains", isDirectory: true)]
            + PlaywrightBuildScanPolicy.roots.map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// `~/.gem/specs` plus each `~/.gem/ruby/<version>/cache`. Installed gems in
    /// `~/.gem/ruby/<version>/gems` are left alone.
    nonisolated static func gemDownloadCachePaths(home: URL) -> [URL] {
        let fm = FileManager.default
        var paths = [home.appendingPathComponent(".gem/specs", isDirectory: true)]
        let rubyRoot = home.appendingPathComponent(".gem/ruby", isDirectory: true)
        // Listing follows a link, so a `~/.gem` linked into Documents is skipped.
        guard ProtectedLocations.isReadable(rubyRoot, access: .limited) else { return paths }
        let versions = (try? fm.contentsOfDirectory(
            at: rubyRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for version in versions.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            paths.append(version.appendingPathComponent("cache", isDirectory: true))
        }
        return paths
    }

    /// Each `~/.gradle/daemon/<version>` folder and `~/.gradle/.tmp`. Which of them
    /// may go is the policy's call, made again at delete time.
    nonisolated static func gradleLeftoverPaths(home: URL) -> [URL] {
        let gradle = home.appendingPathComponent(".gradle", isDirectory: true)
        // Listing follows a link, so a `~/.gradle` linked into Documents is skipped.
        guard ProtectedLocations.isReadable(gradle, access: .limited, home: home) else { return [] }
        let daemonFolder = gradle.appendingPathComponent("daemon", isDirectory: true)
        // The same for `daemon` itself, which is listed below.
        let readable = ProtectedLocations.isReadable(daemonFolder, access: .limited, home: home)
        // Built from the names, so each path keeps the spelling of `home`.
        let versions = ((readable ? try? FileManager.default.contentsOfDirectory(atPath: daemonFolder.path) : nil) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { daemonFolder.appendingPathComponent($0, isDirectory: true) }
        return (versions + [gradle.appendingPathComponent(".tmp", isDirectory: true)])
            .filter { DeletionSafetyPolicy.gradleLeftover(at: $0.path, home: home.path) != nil }
    }

    /// Every child of each `~/Library/Caches/JetBrains/<IDE><version>` folder except
    /// `LocalHistory`, which is the IDE's record of your file edits.
    nonisolated static func jetBrainsCachePaths(home: URL) -> [URL] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("Library/Caches/JetBrains", isDirectory: true)
        guard ProtectedLocations.isReadable(root, access: .limited) else { return [] }
        let ideFolders = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var paths: [URL] = []
        for ide in ideFolders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where (try? ide.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let children = (try? fm.contentsOfDirectory(
                at: ide,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            paths += children
                .filter { $0.lastPathComponent != DeletionSafetyPolicy.jetBrainsLocalHistoryFolderName }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return paths
    }

    private nonisolated static func globalCacheDefinitions() -> [(label: String, paths: [URL])] {
        let home = FileManager.default.homeDirectoryForCurrentUser

        return [
            ("Xcode Derived Data", [home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)]),
            ("Xcode Archives", [home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true)]),
            ("Xcode Device Support", [
                home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true),
                home.appendingPathComponent("Library/Developer/Xcode/watchOS DeviceSupport", isDirectory: true),
                home.appendingPathComponent("Library/Developer/Xcode/tvOS DeviceSupport", isDirectory: true),
                home.appendingPathComponent("Library/Developer/Xcode/visionOS DeviceSupport", isDirectory: true),
                home.appendingPathComponent("Library/Developer/Xcode/xrOS DeviceSupport", isDirectory: true)
            ]),
            ("Simulator Caches", [
                home.appendingPathComponent("Library/Developer/CoreSimulator/Caches", isDirectory: true)
            ]),
            ("Xcode Test Devices", [
                home.appendingPathComponent("Library/Developer/XCTestDevices", isDirectory: true)
            ]),
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
            // pnpm's default store on macOS is ~/Library/pnpm/store; ~/.pnpm-store is
            // the older location and what some setups still use.
            ("pnpm Store", [
                home.appendingPathComponent(".pnpm-store", isDirectory: true),
                home.appendingPathComponent("Library/pnpm/store", isDirectory: true)
            ]),
            ("Yarn Cache", [
                home.appendingPathComponent("Library/Caches/Yarn", isDirectory: true),
                home.appendingPathComponent(".yarn/berry/cache", isDirectory: true)
            ]),
            ("Dart Pub Cache", [
                home.appendingPathComponent(".pub-cache/hosted", isDirectory: true),
                home.appendingPathComponent(".pub-cache/git", isDirectory: true)
            ]),
            ("pre-commit Environments", [home.appendingPathComponent(".cache/pre-commit", isDirectory: true)]),
            ("Prisma Engines", [home.appendingPathComponent(".cache/prisma", isDirectory: true)]),
            ("Expo Cache", [
                "android-apk-cache", "ios-simulator-app-cache", "native-modules-cache",
                "schema-cache", "template-cache", "versions-cache", "expo-go"
            ].map { home.appendingPathComponent(".expo/\($0)", isDirectory: true) }),
            ("pyenv and rbenv Downloads", [
                home.appendingPathComponent(".pyenv/cache", isDirectory: true),
                home.appendingPathComponent(".rbenv/cache", isDirectory: true)
            ]),
            ("Oh My Zsh Cache", [home.appendingPathComponent(".oh-my-zsh/cache", isDirectory: true)]),
            ("opam Download Cache", [home.appendingPathComponent(".opam/download-cache", isDirectory: true)]),
            ("Puppeteer Browsers", [home.appendingPathComponent(".cache/puppeteer", isDirectory: true)]),
            // The analysis server's byte store only. `.prompts`, `.instrumentation` and
            // the pub package details next to it are not caches of any size.
            ("Dart Analysis Cache", [home.appendingPathComponent(".dartServer/.analysis-driver", isDirectory: true)]),
            // Check First: Hermes runs tasks unattended and keeps their scratch space
            // here. Config, API keys, sessions and memories elsewhere in ~/.hermes are
            // never listed.
            ("Hermes Agent Cache", [home.appendingPathComponent(".hermes/cache", isDirectory: true)]),
            ("Conda Package Cache", [
                ".conda/pkgs", "anaconda3/pkgs", "miniconda3/pkgs", "miniforge3/pkgs",
                "mambaforge/pkgs", "opt/anaconda3/pkgs", "opt/miniconda3/pkgs"
            ].map { home.appendingPathComponent($0, isDirectory: true) }),
            ("Gradle Cache", [
                home.appendingPathComponent(".gradle/caches", isDirectory: true),
                home.appendingPathComponent(".gradle/wrapper/dists", isDirectory: true)
            ]),
            // Stopped daemons' folders and a week-old temp folder; the policy keeps the rest.
            ("Gradle Logs and Temp Files", gradleLeftoverPaths(home: home)),
            ("nvm Download Cache", [home.appendingPathComponent(".nvm/.cache", isDirectory: true)]),
            ("giget Template Cache", [home.appendingPathComponent(".cache/giget", isDirectory: true)]),
            ("Firebase Emulators", [home.appendingPathComponent(".cache/firebase/emulators", isDirectory: true)]),
            // In the per-user cache folder under /var/folders, not the home folder.
            ("Clang Module Cache", DeletionSafetyPolicy.clangModuleCachePaths.prefix(1).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }),
            ("Hex Package Cache", [home.appendingPathComponent(".hex/packages", isDirectory: true)]),
            ("Rebar3 Cache", [home.appendingPathComponent(".cache/rebar3", isDirectory: true)]),
            ("NuGet Packages", [home.appendingPathComponent(".nuget/packages", isDirectory: true)]),
            // `~/.deno` deliberately not listed: `deno upgrade` and `deno install` put the
            // deno binary and script shims in `~/.deno/bin`, so offering it would offer
            // the toolchain itself. DENO_DIR (the real cache) lives under Library/Caches.
            ("Deno Cache", [home.appendingPathComponent("Library/Caches/deno", isDirectory: true)]),
            ("Bun Cache", [home.appendingPathComponent(".bun/install/cache", isDirectory: true)]),
            ("Cabal Packages", [home.appendingPathComponent(".cabal/packages", isDirectory: true)]),
            ("Stack Cache", [
                home.appendingPathComponent(".stack/pantry", isDirectory: true),
                home.appendingPathComponent(".stack/snapshots", isDirectory: true)
            ]),
            ("Bazel Cache", [home.appendingPathComponent(".cache/bazel", isDirectory: true)]),
            ("Swift Package Cache", [
                home.appendingPathComponent("Library/Caches/org.swift.swiftpm", isDirectory: true),
                home.appendingPathComponent(".swiftpm/cache", isDirectory: true)
            ]),
            ("Android Build Cache", [
                home.appendingPathComponent(".android/cache", isDirectory: true),
                home.appendingPathComponent(".android/build-cache", isDirectory: true)
            ]),
            ("Docker Desktop", [home.appendingPathComponent("Library/Containers/com.docker.docker", isDirectory: true)]),

            ("VS Code Cache", [
                home.appendingPathComponent("Library/Application Support/Code/Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Code/CachedData", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Code/CachedExtensionVSIXs", isDirectory: true)
            ]),
            ("Cursor Cache", [
                home.appendingPathComponent("Library/Application Support/Cursor/Cache", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Cursor/CachedData", isDirectory: true)
            ]),
            // Only ~/Library/Caches/JetBrains is a real cache (indexes, compiler
            // output), rebuilt on next launch. ~/Library/Application Support/JetBrains
            // holds installed plugins and all settings, so it must never be cleaned.
            // Each IDE folder's LocalHistory is left out; see `jetBrainsCachePaths`.
            ("JetBrains Cache", jetBrainsCachePaths(home: home)),
            // `Zed/db` is Zed's workspace state, not a cache, so only the real cache is listed.
            ("Zed Cache", [
                home.appendingPathComponent("Library/Caches/Zed", isDirectory: true)
            ]),

            // Go keeps its build cache in `~/Library/Caches/go-build` on macOS.
            // `~/.cache/go-build` is only used when `GOCACHE` points there.
            ("Go Module Cache", [
                home.appendingPathComponent("go/pkg/mod/cache", isDirectory: true),
                home.appendingPathComponent("Library/Caches/go-build", isDirectory: true),
                home.appendingPathComponent(".cache/go-build", isDirectory: true)
            ]),

            ("Maven Cache", [
                home.appendingPathComponent(".m2/repository", isDirectory: true)
            ]),
            // `~/.sbt` is not listed: it holds the user's own sbt settings.
            ("SBT Cache", [
                home.appendingPathComponent(".ivy2/cache", isDirectory: true)
            ]),

            ("Ruby Gems", gemDownloadCachePaths(home: home)),
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
            ])
            // Playwright's browser folders are not a row as a whole: a project still
            // runs some of the builds. `PlaywrightBuildScanPolicy` offers the rest (#328).
        ] + chromiumUserDataCacheDefinitions(home: home)
    }

    /// One row per Chromium profile folder outside Application Support, listing
    /// only its cache folders. The profile itself (cookies, saved passwords,
    /// history, extensions) is never a path here, and the policy refuses it too.
    /// Listed with limited access: a hidden home folder needs no permission, and a
    /// store linked into Documents is skipped rather than followed.
    private nonisolated static func chromiumUserDataCacheDefinitions(home: URL) -> [(label: String, paths: [URL])] {
        DeletionSafetyPolicy.chromiumUserDataStores.map { store in
            (store.label, CacheDiscoveryPaths.chromiumUserDataCacheURLs(
                userData: home.appendingPathComponent(store.relative, isDirectory: true),
                access: .limited
            ))
        }
    }

    private func scanGlobalCachePlaceholders(access: ScanAccess) -> ([DevTool], [DevToolSizeJob]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var staticDefinitions = Self.globalCacheDefinitions()
            + discoverOrphanedEditorWorkspaceDefinitions(home: home, access: access)
            + Self.oldCLIVersionDefinitions(home: home)
            + OldToolVersionScanPolicy.definitions(home: home)
            + PlaywrightBuildScanPolicy.definitions(home: home, access: access)
        // Agent worktrees are judged by reading the git dir their `.git` file points
        // at, which is usually a repo in Documents or Desktop, and Claude Code's live
        // inside those projects. A limited scan cannot look there without a prompt,
        // so it skips them rather than guess.
        if access == .full {
            staticDefinitions += discoverAgentLeftoverDefinitions(home: home)
        }

        let built = staticDefinitions.compactMap { entry -> DevTool? in
            let label = entry.label
            let paths = entry.paths
            let existing = paths.filter {
                // Checked before `fileExists`: the check itself is what would prompt.
                ProtectedLocations.isReadable($0, access: access)
                    && FileManager.default.fileExists(atPath: $0.path)
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

    private func discoverAgentLeftoverDefinitions(home: URL) -> [(label: String, paths: [URL])] {
        typealias Worktrees = AgentWorktreeScanPolicy
        typealias Cursor = CursorAgentLeftoverScanPolicy
        // One row for every tool's orphaned worktrees, so the label says why they are listed.
        let entries: [(label: String, paths: [URL])] = [
            (Worktrees.toolLabel, Worktrees.orphanedWorktrees(
                home: home,
                claudeProjects: Worktrees.claudeCodeProjects(home: home),
                live: Worktrees.LiveContext.current(home: home)
            )),
            (Cursor.toolLabel, Cursor.unusedJunkProjectNamespaces(
                home: home,
                live: Cursor.LiveContext.current(home: home)
            ))
        ]
        return entries.filter { !$0.paths.isEmpty }
    }

    /// Old Claude Code, Cursor Agent and Grok versions, keeping the one each command
    /// runs and the newest. The policy re-checks this before anything is deleted.
    nonisolated static func oldCLIVersionDefinitions(home: URL) -> [(label: String, paths: [URL])] {
        let homePath = home.standardizedFileURL.path
        return DeletionSafetyPolicy.cliVersionStores.compactMap { store in
            let label = store.label
            let root = "\(homePath)/\(store.versions)"
            guard ProtectedLocations.isReadable(URL(fileURLWithPath: root), access: .limited),
                  let kept = DeletionSafetyPolicy.keptCLIVersions(
                    versionsRoot: root,
                    command: "\(homePath)/\(store.command)",
                    entry: store.entry
                  ),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
            let old = names
                .filter { !$0.hasPrefix(".") && !kept.contains($0) && store.entry.accepts(name: $0, in: root) }
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
                .map { URL(fileURLWithPath: "\(root)/\($0)") }
            return old.isEmpty ? nil : (label, old)
        }
    }

    /// One row per editor listing the `workspaceStorage` entries whose project
    /// folder is gone. See `EditorWorkspaceStoragePolicy` for why the folder as a
    /// whole is never offered.
    private func discoverOrphanedEditorWorkspaceDefinitions(
        home: URL,
        access: ScanAccess
    ) -> [(label: String, paths: [URL])] {
        EditorWorkspaceStoragePolicy.relativeRoots.compactMap { root in
            let entries = EditorWorkspaceStoragePolicy.orphanedEntries(
                inRoot: home.appendingPathComponent(root.relative, isDirectory: true),
                access: access,
                home: home
            )
            return entries.isEmpty ? nil : ("\(root.editor) Old Workspace Data", entries)
        }
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
        let sizesByPath = FolderSizing.directorySizes(at: allPaths, split: .spread)

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
        let sizesByPath = FolderSizing.directorySizes(at: folderURLs, split: .spread)

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

    /// Whether a root still needs walking to `depth`. `~/Developer` and `~/developer`
    /// are one folder on the default case-insensitive volume, and a root can be a
    /// link to another, so a folder already walked as deep is skipped, and the first
    /// spelling listed is the one walked (#175). A root that links to home still gets
    /// the deeper walk home itself never has. A root whose identity can't be read is
    /// walked, as before.
    nonisolated static func shouldWalk(
        _ root: URL,
        toDepth depth: Int,
        walkedDepths: inout [FileIdentity: Int]
    ) -> Bool {
        guard let identity = FileIdentity(path: root.path) else { return true }
        if let walked = walkedDepths[identity], walked >= depth { return false }
        walkedDepths[identity] = depth
        return true
    }

    /// Keeps the first of each project found more than once: by path, then by file
    /// identity, since two spellings can name one folder. The home walk and a root
    /// can reach a project as `~/developer/app` and `~/Developer/app`, and a root
    /// that links into another reaches its projects twice (#175). A project whose
    /// identity can't be read is kept, as before.
    nonisolated static func firstOfEachProject(_ roots: [(URL, [ProjectType])]) -> [(URL, [ProjectType])] {
        var seenPaths = Set<String>()
        var seenFolders = Set<FileIdentity>()
        return roots.filter { root in
            guard seenPaths.insert(root.0.path).inserted else { return false }
            guard let identity = FileIdentity(path: root.0.path) else { return true }
            return seenFolders.insert(identity).inserted
        }
    }

    /// Walks `roots` (the usual search roots under `home` when nil) for projects,
    /// then sizes their artifacts. Tests pass a temporary tree, and `onDirectory`
    /// is called with each folder as the walk enters it, so a test can cancel at
    /// a known point of the walk.
    func discoverProjects(
        access: ScanAccess,
        maxDepth: Int = 4,
        roots: [URL]? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        continuation: AsyncStream<DeveloperScanEvent>.Continuation? = nil,
        onDirectory: (@Sendable (URL) -> Void)? = nil
    ) async -> [ProjectGroup] {
        let walkStart = Date()
        let (discoveredRoots, directoriesWalked) = Self.findProjectRoots(
            in: roots ?? Self.projectSearchRoots(home: home),
            home: home,
            access: access,
            maxDepth: maxDepth,
            onDirectory: onDirectory
        )
        // A cancelled walk stopped part way. Its list is incomplete, so nothing is sized.
        guard !Task.isCancelled else { return [] }

        ScanPhaseTiming.finish(
            "discoverProjects walk",
            since: walkStart,
            detail: "walked \(directoriesWalked) directories, found \(discoveredRoots.count) project roots"
        )

        /// Build artifact list per root (expensive sizing runs concurrently).
        let sizingStart = Date()
        let filter = ProjectListingFilter(
            staleDays: DevToolsStalenessOption.currentThresholdDays(),
            now: Date(),
            live: .current()
        )
        let (groups, artifactsSized) = await buildProjectGroups(
            for: discoveredRoots,
            access: access,
            filter: filter,
            continuation: continuation
        )
        ScanPhaseTiming.finish(
            "project artifact sizing",
            since: sizingStart,
            detail: "\(artifactsSized) artifacts sized, \(groups.count) project groups"
        )
        return groups
    }

    /// The folders project discovery starts from. Home itself is walked one level
    /// deep; the rest to `maxDepth`.
    nonisolated static func projectSearchRoots(home: URL) -> [URL] {
        [
            home,
            home.appendingPathComponent("Developer", isDirectory: true),
            home.appendingPathComponent("developer", isDirectory: true),
            home.appendingPathComponent("Development", isDirectory: true),
            home.appendingPathComponent("development", isDirectory: true),
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
    }

    /// Walks `roots` for project markers and returns each project root once,
    /// shallowest first, with how many directories the walk visited.
    /// `onDirectory` is called with each folder as the walk enters it.
    nonisolated static func findProjectRoots(
        in roots: [URL],
        home: URL,
        access: ScanAccess,
        maxDepth: Int = 4,
        onDirectory: (@Sendable (URL) -> Void)? = nil
    ) -> (roots: [(URL, [ProjectType])], directoriesWalked: Int) {
        let fm = FileManager.default
        var discoveredRoots: [(URL, [ProjectType])] = []
        var directoriesWalked = 0

        func shouldSkipDescending(into name: String) -> Bool {
            // Never walk *into* a folder that is itself a removable artifact, or into
            // heavy vendor/VCS folders. Derived from the catalog so a new ecosystem
            // cannot accidentally leave the walker descending into its own build output.
            if ProjectArtifactCatalog.artifactFolderNames.contains(name) { return true }
            switch name {
            case ".git", "DerivedData":
                return true
            case "android", "ios":
                return true
            default:
                return false
            }
        }

        let protectedRoots = ProtectedLocations.resolvedRootPaths(home: home)

        /// `realPath` is `directory` with its root's symlinks resolved, in a limited
        /// scan only; nil with full access, where nothing needs checking.
        func walk(directory: URL, realPath: String?, depth: Int, maxDepth: Int) {
            // A newer scan replaced this one: stop rather than walk the rest of home.
            guard depth <= maxDepth, !Task.isCancelled else { return }
            directoriesWalked += 1
            onDirectory?(directory)

            // One listing serves the project markers and the walk below (#190).
            let listing = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .nameKey],
                options: [.skipsPackageDescendants]
            )

            let types = Self.projectTypes(at: directory, listing: listing)
            if !types.isEmpty {
                discoveredRoots.append((directory, types))
            }

            guard depth < maxDepth, let entries = listing else { return }

            guard entries.count <= Self.maxDirectoryEntriesBeforeSkip else { return }

            for entry in entries {
                let name = entry.lastPathComponent
                /// Skip invisible dot folders (noise and huge caches handled elsewhere).
                if name.hasPrefix(".") { continue }

                if shouldSkipDescending(into: name) { continue }
                // Decided on the path alone, before anything reads the entry. The
                // home root walks one level down, which would open Desktop,
                // Documents and Downloads. `realPath` is the folder's resolved path,
                // so a root that links back into home is judged by where it lands.
                let entryRealPath = realPath.map { $0 + "/" + name }
                if let entryRealPath, ProtectedLocations.isPath(entryRealPath, inAnyOf: protectedRoots) { continue }

                // Never through a link: `~/Projects/client` pointing into Documents
                // would be walked, and its artifacts cleaned, as if it were readable.
                // Both keys describe the entry itself, not its target, so listing
                // with them prefetched stats nothing through a link. That is also
                // why a linked folder was never walked, with or without access:
                // `isDirectory` is false for it.
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink != true, values?.isDirectory == true else { continue }

                walk(directory: entry, realPath: entryRealPath, depth: depth + 1, maxDepth: maxDepth)
            }
        }

        var walkedDepths: [FileIdentity: Int] = [:]
        for root in roots where !Task.isCancelled {
            // A limited scan resolves the root with `readlink` alone first, so a
            // root that is a link into a protected folder is never opened.
            let realRoot: String?
            if access == .limited {
                guard let resolved = ProtectedLocations.readablePath(of: root, home: home) else { continue }
                realRoot = resolved
            } else {
                realRoot = nil
            }
            guard fm.fileExists(atPath: root.path) else { continue }
            // When the root is the home directory itself, limit to depth 1
            // to avoid scanning deep into personal folders like Documents recursively
            // since those are already covered by their own dedicated root entries above
            let effectiveMaxDepth = (root.path == home.path) ? 1 : maxDepth
            // After the checks above, since `stat` follows a link.
            guard Self.shouldWalk(root, toDepth: effectiveMaxDepth, walkedDepths: &walkedDepths) else { continue }
            walk(directory: root, realPath: realRoot, depth: 0, maxDepth: effectiveMaxDepth)
        }

        discoveredRoots = Self.firstOfEachProject(discoveredRoots)
        discoveredRoots.sort { $0.0.path.count < $1.0.path.count }
        return (discoveredRoots, directoriesWalked)
    }

    /// The project types a folder's markers name. `listing` is the folder's
    /// entries, read once by the walk, or nil when it could not be listed.
    ///
    /// A marker is only checked on disk when the listing has an entry of that name,
    /// compared without case as the volume compares it. `fileExists` then confirms
    /// it, following a link, as it did when every marker was checked. A folder that
    /// could not be listed is checked marker by marker, as before.
    nonisolated static func projectTypes(at directory: URL, listing: [URL]?) -> [ProjectType] {
        let fm = FileManager.default
        let names = listing.map { Set($0.map { $0.lastPathComponent.lowercased() }) }

        func exists(_ relative: String) -> Bool {
            if let names {
                let first = relative.prefix { $0 != "/" }.lowercased()
                guard names.contains(first) else { return false }
            }
            return fm.fileExists(atPath: directory.appendingPathComponent(relative).path)
        }

        func anyExists(_ relatives: [String]) -> Bool {
            relatives.contains(where: exists)
        }

        var result: Set<ProjectType> = []

        // Markers that identify a project type by plain file existence.
        let simpleMarkers: [(ProjectType, [String])] = [
            (.node, ["package.json"]),
            (.rust, ["Cargo.toml"]),
            (.flutter, ["pubspec.yaml"]),
            (.python, ["requirements.txt", "pyproject.toml", "tox.ini"]),
            (.elixir, ["mix.exs"]),
            (.swiftPackage, ["Package.swift"]),
            (.maven, ["pom.xml"]),
            (.sbt, ["build.sbt"]),
            (.composer, ["composer.json"]),
            (.bundler, ["Gemfile"]),
            (.haskellStack, ["stack.yaml"]),
            (.zig, ["build.zig"]),
            (.ocamlDune, ["dune-project"]),
            (.cmake, ["CMakeLists.txt"]),
            (.godot, ["project.godot"]),
            (.unity, ["ProjectSettings/ProjectVersion.txt"]),
        ]
        for (type, markers) in simpleMarkers where anyExists(markers) {
            result.insert(type)
        }

        // React Native and Flutter keep their CocoaPods setup in `ios/`, which the
        // walk never enters, so `ios/Podfile` is what unlocks the `ios/Pods` rule.
        if anyExists(["ios/Podfile"]) {
            result.insert(.xcode)
        }

        let hasGradleMarker = anyExists([
            "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
            "android/build.gradle", "android/build.gradle.kts",
        ])
        if hasGradleMarker {
            // Every Gradle project has a `.gradle` folder, which this type owns.
            result.insert(.androidGradle)
            // `.gradleJVM` additionally offers the root `build/` folder and suggests
            // `./gradlew build`. Android projects are excluded: their build output is
            // per-module rather than at the root, and the row would duplicate the
            // Gradle entry above under a label and command that do not fit.
            let isAndroid = anyExists([
                "android/build.gradle", "android/build.gradle.kts", "app/src/main/AndroidManifest.xml",
            ])
            if !isAndroid, anyExists(["build.gradle", "build.gradle.kts"]) {
                result.insert(.gradleJVM)
            }
        }

        // Xcode bundles and the types named by a file extension. These read names
        // from the listing, leaving out hidden entries as the listings they
        // replaced did.
        if let listing {
            for child in listing where (try? child.resourceValues(forKeys: [.isHiddenKey]).isHidden) != true {
                let name = child.lastPathComponent
                if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                    result.insert(.xcode)
                }
                switch child.pathExtension.lowercased() {
                case "csproj", "fsproj", "vbproj", "sln":
                    result.insert(.dotnet)
                case "cabal":
                    result.insert(.haskellCabal)
                case "tf":
                    result.insert(.terraform)
                case "uproject":
                    result.insert(.unreal)
                default:
                    continue
                }
            }
        }

        return Array(result).sorted { String(describing: $0) < String(describing: $1) }
    }

    private func buildProjectGroups(
        for discovered: [(URL, [ProjectType])],
        access: ScanAccess,
        filter: ProjectListingFilter,
        continuation: AsyncStream<DeveloperScanEvent>.Continuation? = nil
    ) async -> (groups: [ProjectGroup], artifactsSized: Int) {
        guard !discovered.isEmpty else { return ([], 0) }

        // Bounded rather than one task per discovered root. `sizeProjectGroup` blocks its
        // thread inside `FolderSizing.directorySizes` (a `DispatchGroup.wait`), so an
        // unbounded group parks one cooperative-pool thread per project — and the pool is
        // core-count sized and already shared with the cache scan's fan-out. The `du`
        // subprocess count is capped separately and process-wide by `FolderSizing`.
        return await withTaskGroup(of: (ProjectGroup?, Int).self) { group in
            var pending = discovered.makeIterator()
            var inFlight = 0

            while inFlight < Self.maxConcurrentProjectSizings, let next = pending.next() {
                group.addTask { [next] in
                    DevScanner.sizeProjectGroup(rootURL: next.0, types: next.1, access: access, filter: filter)
                }
                inFlight += 1
            }

            var groups: [ProjectGroup] = []
            var artifactsSized = 0
            while let result = await group.next() {
                artifactsSized += result.1
                if let g = result.0 {
                    groups.append(g)
                    continuation?.yield(.projectGroupFound(g))
                }
                if Task.isCancelled { continue }
                if let next = pending.next() {
                    group.addTask { [next] in
                        DevScanner.sizeProjectGroup(rootURL: next.0, types: next.1, access: access, filter: filter)
                    }
                }
            }
            return (groups, artifactsSized)
        }
    }

    /// How many project roots may be sized at once. See `buildProjectGroups`.
    private static let maxConcurrentProjectSizings = 4

    /// What decides whether a discovered project is listed. Read once per scan.
    struct ProjectListingFilter: Sendable {
        /// `DevToolsStalenessOption` days, or `showAll`'s 0.
        let staleDays: Int
        let now: Date
        let live: ProjectActivityPolicy.LiveContext
        var activityEntryLimit = ProjectActivityPolicy.walkEntryLimit
    }

    nonisolated static func sizeProjectGroup(
        rootURL: URL,
        types: [ProjectType],
        access: ScanAccess,
        filter: ProjectListingFilter
    ) -> (ProjectGroup?, Int) {
        let rows = DevScanner.collectArtifacts(projectRoot: rootURL, types: types, access: access)
        guard !rows.isEmpty else { return (nil, 0) }

        // Decided per project and before sizing: a project someone is using keeps
        // all of its folders, and there is no point running `du` on them.
        if ProjectActivityPolicy.isInUse(projectRoot: rootURL, live: filter.live, access: access) {
            return (nil, 0)
        }
        // Show all still lists a project worked on lately, but measured against the
        // default window it is not stale, so its folders become Check First below.
        // A project too big to check is listed the same way in every mode.
        let showAll = filter.staleDays == DevToolsStalenessOption.showAll.rawValue
        let windowDays = showAll ? DevToolsStalenessOption.defaultOption.rawValue : filter.staleDays
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: filter.now)
            ?? filter.now
        let checkFirstReason: ProjectCheckFirstReason?
        switch ProjectActivityPolicy.activity(
            since: cutoff,
            projectRoot: rootURL,
            artifactPaths: rows.map(\.path),
            access: access,
            entryLimit: filter.activityEntryLimit
        ) {
        case .recent:
            guard showAll else { return (nil, 0) }
            checkFirstReason = .usedRecently
        case .tooBigToCheck:
            checkFirstReason = .tooBigToCheck
        case .none:
            checkFirstReason = nil
        }

        let artifactPaths = rows.map(\.path)
        let sizesByPath = FolderSizing.directorySizes(at: artifactPaths, split: .spread)

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
                    safetyInfo: checkFirstReason == nil
                        ? row.safetyInfo
                        : row.safetyInfo.heldAtCheckFirst(path: row.path),
                    reinstallSafety: row.reinstallSafety,
                    gitStatus: .unknown,
                    checkFirstReason: checkFirstReason
                )
            )
        }
        sized.sort { $0.sizeBytes > $1.sizeBytes }

        return (
            ProjectGroup(
                displayName: rootURL.lastPathComponent,
                rootPath: rootURL,
                inferredTypes: types,
                artifacts: sized
            ),
            rows.count
        )
    }

    struct SizedArtifactIntermediate {
        let kind: DeletableArtifactKind
        let path: URL
        let projectRoot: URL
        let safetyInfo: SafetyInfo
        let reinstallSafety: ReinstallSafetyStatus
    }

    nonisolated static func collectArtifacts(
        projectRoot root: URL,
        types: [ProjectType],
        access: ScanAccess = .full
    ) -> [SizedArtifactIntermediate] {
        let fm = FileManager.default
        var artifacts: [SizedArtifactIntermediate] = []
        let detected = Set(types)

        func addIfDir(rule: ProjectArtifactRule, url: URL) {
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

            let reinstall = Self.reinstallCommand(rule: rule, root: root)
            let safety = SafetyInfo.forStaleProjectArtifact(
                kind: rule.kind,
                path: url,
                reinstallCommand: reinstall,
                level: rule.level
            )
            let reinstallStatus = ReinstallSafetyEvaluator.evaluate(artifactKind: rule.kind, artifactURL: url)
            artifacts.append(
                SizedArtifactIntermediate(
                    kind: rule.kind,
                    path: url,
                    projectRoot: root,
                    safetyInfo: safety,
                    reinstallSafety: reinstallStatus
                )
            )
        }

        for rule in ProjectArtifactCatalog.rules where detected.contains(rule.projectType) {
            // The rule's own anchor is re-checked even though `listTypes` already matched
            // the project type, because one type can cover several markers: a Python
            // project with `requirements.txt` but no `tox.ini` must not offer `.tox`.
            guard rule.matchesRoot(root) else { continue }
            let artifact = root.appendingPathComponent(rule.folder, isDirectory: true)
            // Before anything reads the artifact: a `node_modules` linked into
            // Documents would be followed by `fileExists` and prompt.
            guard ProtectedLocations.isReadable(artifact, access: access) else { continue }
            guard !rule.refusesArtifact(at: artifact) else { continue }
            addIfDir(rule: rule, url: artifact)
        }

        var unique: [String: SizedArtifactIntermediate] = [:]
        for a in artifacts {
            unique[a.path.path] = a
        }
        // One rule's folder can sit inside another's (`node_modules/.vite` in
        // `node_modules`, `vendor/bundle` in `vendor`). Both rows would size the
        // inner folder, so it would be counted twice. The outer folder covers it.
        let paths = Array(unique.keys)
        return unique.values.filter { artifact in
            !paths.contains { PathContainment.isInside(artifact.path.path, $0) }
        }
    }

    private nonisolated static func reinstallCommand(rule: ProjectArtifactRule, root: URL) -> String? {
        switch rule.reinstall {
        case .command(let template):
            return template.replacingOccurrences(of: "{root}", with: root.path)
        case .guidance(let text):
            // Fixed English sentences from the catalog; looked up for display only.
            return Bundle.main.localizedString(forKey: text, value: text, table: nil)
        case .nodePackageManager:
            let pm = NodePackageManager.detect(in: root)
            return "cd \"\(root.path)\" && \(pm.installCommand)"
        case .cocoaPods:
            let ios = root.appendingPathComponent("ios", isDirectory: true)
            if FileManager.default.fileExists(atPath: ios.appendingPathComponent("Podfile").path) {
                return "cd \"\(ios.path)\" && pod install"
            }
            return "cd \"\(root.path)\" && pod install"
        case .none:
            return nil
        }
    }
}

import Foundation

/// Result of filesystem discovery for Dev Tools.
struct DeveloperScanOutcome {
    let tools: [DevTool]
    let projects: [ProjectGroup]
}

final class DevScanner {
    /// Maps scanner labels to keys in `explanations.json`.
    private static let toolExplanationKeys: [String: String] = [
        "Xcode Derived Data": "DerivedData",
        "Xcode iOS DeviceSupport": "iOS DeviceSupport",
        "Xcode Caches": "xcode",
        "Homebrew Cache": "homebrew",
        "Gradle Cache": "gradle",
        "Docker Desktop": "docker",
        "npm Cache": "npm",
        "pnpm Store": "pnpm",
        "Yarn Cache": "yarn",
        "CocoaPods": "cocoapods"
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
        let projects = await discoverProjects()
        return DeveloperScanOutcome(
            tools: tools.sorted { $0.sizeBytes > $1.sizeBytes },
            projects: projects.sorted { $0.totalBytes > $1.totalBytes }
        )
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
            ("Docker Desktop", "shippingbox.fill", [home.appendingPathComponent("Library/Containers/com.docker.docker", isDirectory: true)])
        ]

        return mapped.map { entry -> DevTool in
            let existing = entry.2.filter { FileManager.default.fileExists(atPath: $0.path) }
            let size = existing.reduce(Int64(0)) { $0 + FolderSizing.directoryByteSize(at: $1) }
            return DevTool(
                toolName: entry.0,
                iconName: entry.1,
                paths: entry.2,
                sizeBytes: size,
                isSelected: false,
                isDetected: !existing.isEmpty,
                safetyInfo: safetyInfo(forToolLabel: entry.0, primaryPath: entry.2.first)
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

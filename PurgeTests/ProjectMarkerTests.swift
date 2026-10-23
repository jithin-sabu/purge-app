import Foundation
import Testing
@testable import Purge

/// Project discovery reads each folder's markers from one listing instead of three
/// listings and a `fileExists` per marker name (#190). It must find the same types.
@Suite("Project markers from one listing")
struct ProjectMarkerTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-project-markers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func touch(_ relative: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
    }

    private func listing(_ folder: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .nameKey],
            options: [.skipsPackageDescendants]
        )
    }

    /// Both ways in: from the walk's listing, and marker by marker for a folder
    /// that could not be listed.
    private func types(_ folder: URL) -> (listed: [ProjectType], unlisted: [ProjectType]) {
        (
            DevScanner.projectTypes(at: folder, listing: listing(folder)),
            DevScanner.projectTypes(at: folder, listing: nil)
        )
    }

    @Test(arguments: [
        ("package.json", ProjectType.node),
        ("Cargo.toml", .rust),
        ("pubspec.yaml", .flutter),
        ("requirements.txt", .python),
        ("pyproject.toml", .python),
        ("tox.ini", .python),
        ("mix.exs", .elixir),
        ("Package.swift", .swiftPackage),
        ("pom.xml", .maven),
        ("build.sbt", .sbt),
        ("composer.json", .composer),
        ("Gemfile", .bundler),
        ("stack.yaml", .haskellStack),
        ("build.zig", .zig),
        ("dune-project", .ocamlDune),
        ("CMakeLists.txt", .cmake),
        ("project.godot", .godot),
        ("ProjectSettings/ProjectVersion.txt", .unity),
        ("App.csproj", .dotnet),
        ("Lib.fsproj", .dotnet),
        ("Old.vbproj", .dotnet),
        ("All.sln", .dotnet),
        ("pkg.cabal", .haskellCabal),
        ("main.tf", .terraform),
        ("Game.uproject", .unreal),
    ])
    func eachMarkerNamesItsType(marker: String, type: ProjectType) throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try touch(marker, in: folder)
        try touch("README.md", in: folder)

        let found = types(folder)
        #expect(found.listed == [type])
        // Types named by an extension need a listing, with or without this change.
        let needsListing: Set<ProjectType> = [.dotnet, .haskellCabal, .terraform, .unreal]
        #expect(found.unlisted == (needsListing.contains(type) ? [] : [type]))
    }

    @Test func plainFolderHasNoType() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try touch("notes.txt", in: folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        #expect(types(folder).listed.isEmpty)
    }

    @Test func xcodeBundlesAreFoundAndHiddenOnesAreNot() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        #expect(types(folder).listed == [.xcode])

        let other = try makeFolder()
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".Hidden.xcworkspace"), withIntermediateDirectories: true)
        try touch(".secret.tf", in: other)
        #expect(types(other).listed.isEmpty)
    }

    @Test func gradleJVMAndAndroidAreTold() throws {
        let jvm = try makeFolder()
        defer { try? FileManager.default.removeItem(at: jvm) }
        try touch("build.gradle.kts", in: jvm)
        #expect(types(jvm).listed == [.androidGradle, .gradleJVM].sorted { String(describing: $0) < String(describing: $1) })

        let settingsOnly = try makeFolder()
        defer { try? FileManager.default.removeItem(at: settingsOnly) }
        try touch("settings.gradle", in: settingsOnly)
        #expect(types(settingsOnly).listed == [.androidGradle])

        let reactNative = try makeFolder()
        defer { try? FileManager.default.removeItem(at: reactNative) }
        try touch("package.json", in: reactNative)
        try touch("android/build.gradle", in: reactNative)
        #expect(types(reactNative).listed == [.androidGradle, .node].sorted { String(describing: $0) < String(describing: $1) })

        let androidApp = try makeFolder()
        defer { try? FileManager.default.removeItem(at: androidApp) }
        try touch("build.gradle", in: androidApp)
        try touch("app/src/main/AndroidManifest.xml", in: androidApp)
        #expect(types(androidApp).listed == [.androidGradle])
        #expect(types(androidApp).unlisted == [.androidGradle])
    }

    /// The volume compares names without case, and `fileExists` always did too.
    @Test func markerCaseFollowsTheVolume() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try touch("PACKAGE.JSON", in: folder)
        let found = types(folder)
        #expect(found.listed == found.unlisted)
    }

    /// `fileExists` follows a link, so a linked marker counts and a broken one does not.
    @Test func linkedMarkersFollowTheLink() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("elsewhere/package.json")
        try touch("elsewhere/package.json", in: folder)
        let project = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("package.json"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("Cargo.toml"),
            withDestinationURL: folder.appendingPathComponent("missing/Cargo.toml")
        )
        #expect(types(project).listed == [.node])
        #expect(types(project).unlisted == [.node])
    }

    @Test func walkFindsProjectsInATree() throws {
        let root = try makeFolder()
        let home = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: home)
        }
        try touch("org/web/package.json", in: root)
        try touch("org/web/src/index.js", in: root)
        try touch("org/tool/Cargo.toml", in: root)
        try touch("deep/a/b/c/d/package.json", in: root)
        try touch("org/web/node_modules/dep/package.json", in: root)

        let result = DevScanner.findProjectRoots(in: [root], home: home, access: .full)
        let found = Set(result.roots.map { $0.0.lastPathComponent })
        #expect(found == ["web", "tool"])
    }

    /// A superseded scan stops walking instead of finishing the whole tree.
    @Test func cancelledWalkStopsEarly() async throws {
        let root = try makeFolder()
        let home = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: home)
        }
        for a in 0..<6 {
            for b in 0..<6 {
                for c in 0..<6 {
                    try FileManager.default.createDirectory(
                        at: root.appendingPathComponent("a\(a)/b\(b)/c\(c)/d"),
                        withIntermediateDirectories: true
                    )
                }
            }
        }
        let full = DevScanner.findProjectRoots(in: [root], home: home, access: .full)

        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return DevScanner.findProjectRoots(in: [root], home: home, access: .full)
        }
        let cancelled = await task.value

        #expect(full.directoriesWalked > 200)
        #expect(cancelled.directoriesWalked == 0)
    }

    /// A walk cancelled part way has an incomplete list, so discovery sizes none of
    /// it and sends no project groups. Without this, the projects found before the
    /// cancel would reach the Dev Tools list as if they were the whole result.
    @Test func cancelledDiscoverySendsNoGroups() async throws {
        let root = try makeFolder()
        let home = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: home)
        }
        // One project the walk finds at once, then a tree that keeps it busy for
        // hundreds of milliseconds, so the cancel below lands while it is walking.
        let project = root.appendingPathComponent("app", isDirectory: true)
        try touch("app/package.json", in: root)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("node_modules/dep"), withIntermediateDirectories: true)
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        for a in 0..<8 {
            for b in 0..<8 {
                for c in 0..<8 {
                    try FileManager.default.createDirectory(
                        at: tree.appendingPathComponent("a\(a)/b\(b)/c\(c)/d"),
                        withIntermediateDirectories: true
                    )
                }
            }
        }
        let roots = [project, tree]

        let fullStart = Date()
        let full = DevScanner.findProjectRoots(in: roots, home: home, access: .full)
        let fullWalk = Date().timeIntervalSince(fullStart)
        #expect(full.roots.map { $0.0.lastPathComponent } == ["app"])

        let scanner = DevScanner()
        let (stream, continuation) = AsyncStream<DeveloperScanEvent>.makeStream()
        let discovery = Task.detached(priority: .background) {
            let groups = await scanner.discoverProjects(access: .full, roots: roots, home: home, continuation: continuation)
            continuation.finish()
            return groups
        }
        try await Task.sleep(for: .milliseconds(15))
        let cancelledAt = Date()
        discovery.cancel()
        let groups = await discovery.value
        let stopped = Date().timeIntervalSince(cancelledAt)

        var events: [DeveloperScanEvent] = []
        for await event in stream { events.append(event) }
        let groupEvents = events.filter {
            if case .projectGroupFound = $0 { return true }
            return false
        }

        #expect(groups.isEmpty)
        #expect(groupEvents.isEmpty)
        // It stopped at the cancel rather than finishing the tree.
        #expect(stopped < fullWalk)
    }
}

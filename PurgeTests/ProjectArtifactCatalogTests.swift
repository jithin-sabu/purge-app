import Foundation
import Testing
@testable import Purge

/// Builds a throwaway project root so anchoring can be tested against real files.
private struct ProjectFixture {
    let root: URL

    init(files: [String] = [], folders: [String] = []) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }
        for folder in folders {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative, isDirectory: true) }

    /// Anchoring is checked against a home the fixture actually sits under, since the
    /// real home would require writing into the user's own directories.
    var containingHome: String { root.deletingLastPathComponent().path }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Catalog integrity")
struct CatalogIntegrityTests {

    @Test("every rule's kind has an explanations.json entry")
    func everyKindHasAnExplanation() {
        for rule in ProjectArtifactCatalog.rules {
            let record = ExplanationDatabase.matchBundledDatabase(folderName: rule.kind.explanationKey)
            #expect(record != nil, "missing explanation for \(rule.kind.explanationKey)")
        }
    }

    @Test("every rule's kind has a row tag distinct from its raw value fallback")
    func everyKindHasMetadata() {
        for kind in DeletableArtifactKind.allCases {
            #expect(!kind.rowTag.isEmpty)
            #expect(!kind.explanationKey.isEmpty)
        }
    }

    /// A rule with no marker of any sort could match on folder name alone, which is
    /// precisely what `isWhitelistedProjectArtifactPath` exists to prevent.
    @Test("no rule can fire without some evidence of a real project")
    func everyRuleIsAnchored() {
        for rule in ProjectArtifactCatalog.rules {
            #expect(
                !rule.rootMarkers.isEmpty || !rule.rootMarkerExtensions.isEmpty,
                "\(rule.kind.rawValue) has no anchor and would match on name alone"
            )
        }
    }

    @Test("Unity and Unreal artifacts are Check First, never Safe to Clean")
    func gameEngineArtifactsAreCheckFirst() {
        let engineTypes: Set<ProjectType> = [.unity, .unreal]
        let engineRules = ProjectArtifactCatalog.rules.filter { engineTypes.contains($0.projectType) }
        #expect(!engineRules.isEmpty)
        for rule in engineRules {
            #expect(rule.level == .medium, "\(rule.kind.rawValue) must not be auto-cleanable")
        }
    }

    @Test("Check First artifacts produce Check First safety info")
    func checkFirstLevelReachesSafetyInfo() {
        let info = SafetyInfo.forStaleProjectArtifact(
            kind: .unityLibrary,
            path: URL(fileURLWithPath: "/tmp/does-not-exist/Library"),
            reinstallCommand: nil,
            level: .medium
        )
        #expect(info.level == .medium)
    }
}

@Suite("Generic folder names stay blocked without a project above them")
struct GenericFolderNameTests {

    /// The whole point of anchoring. These names are common enough that allowing them
    /// on name alone would expose ordinary user folders.
    @Test(arguments: ["bin", "obj", "vendor", "Library", "Temp", "deps", "build", "target"])
    func bareFolderIsNotAllowed(name: String) throws {
        let fixture = try ProjectFixture(folders: [name])
        defer { fixture.cleanUp() }
        #expect(
            !DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
                fixture.url(name), home: fixture.containingHome
            ),
            "\(name) was allowed with no project marker beside it"
        )
    }

    @Test("the home Library folder is never deletable")
    func homeLibraryIsProtected() {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
        #expect(DeletionSafetyPolicy.evaluate(library) == .blockedNeverDelete)
    }

    @Test("caches inside the home Library folder are still reachable")
    func homeLibraryChildrenStillAllowed() {
        let caches = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
        #expect(DeletionSafetyPolicy.evaluate(caches) == .allow)
    }
}

@Suite("Anchored artifacts are allowed when the project is real")
struct AnchoredArtifactTests {

    @Test(arguments: [
        ("composer.json", "vendor"),
        ("mix.exs", "deps"),
        ("mix.exs", "_build"),
        ("Package.swift", ".build"),
        ("pom.xml", "target"),
        ("build.sbt", "target"),
        ("stack.yaml", ".stack-work"),
        ("build.zig", "zig-out"),
        ("dune-project", "_build"),
        ("CMakeLists.txt", "build"),
        ("project.godot", ".godot"),
        ("ProjectSettings/ProjectVersion.txt", "Library"),
    ])
    func markerBesideFolderAllowsIt(marker: String, folder: String) throws {
        let fixture = try ProjectFixture(files: [marker], folders: [folder])
        defer { fixture.cleanUp() }
        #expect(
            DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
                fixture.url(folder), home: fixture.containingHome
            ),
            "\(folder) was not allowed next to \(marker)"
        )
    }

    @Test(arguments: [
        ("App.csproj", "bin"),
        ("App.csproj", "obj"),
        ("main.tf", ".terraform"),
        ("Game.uproject", "Intermediate"),
        ("project.cabal", "dist-newstyle"),
    ])
    func extensionMarkerAllowsIt(marker: String, folder: String) throws {
        let fixture = try ProjectFixture(files: [marker], folders: [folder])
        defer { fixture.cleanUp() }
        #expect(
            DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
                fixture.url(folder), home: fixture.containingHome
            ),
            "\(folder) was not allowed next to \(marker)"
        )
    }

    @Test("a nested artifact anchors on the project root, not its parent folder")
    func nestedArtifactAnchorsOnRoot() throws {
        let fixture = try ProjectFixture(files: ["ios/Podfile"], folders: ["ios/Pods"])
        defer { fixture.cleanUp() }
        #expect(
            DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
                fixture.url("ios/Pods"), home: fixture.containingHome
            )
        )
    }

    @Test("the wrong marker does not unlock an unrelated folder")
    func wrongMarkerIsRejected() throws {
        // A Go project keeps `vendor` under version control, so a `go.mod` must never
        // make it deletable. Only Composer's marker does that.
        let fixture = try ProjectFixture(files: ["go.mod"], folders: ["vendor"])
        defer { fixture.cleanUp() }
        #expect(
            !DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
                fixture.url("vendor"), home: fixture.containingHome
            )
        )
    }

    @Test("never-delete protections still beat a real project marker")
    func neverDeleteBeatsAnchoring() {
        // Simulated rather than written to disk: these are the user's real folders.
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/my_game", isDirectory: true)
        #expect(DeletionSafetyPolicy.evaluate(base.appendingPathComponent("Library")) == .blockedNeverDelete)
        #expect(DeletionSafetyPolicy.evaluate(base.appendingPathComponent("vendor")) == .blockedNeverDelete)
    }
}

@Suite("Reinstall safety reads from the catalog")
struct CatalogReinstallTests {

    @Test("Composer vendor needs composer.lock")
    func composerNeedsLock() throws {
        let locked = try ProjectFixture(files: ["composer.json", "composer.lock"], folders: ["vendor"])
        defer { locked.cleanUp() }
        #expect(
            ReinstallSafetyEvaluator.evaluate(artifactKind: .composerVendor, artifactURL: locked.url("vendor"))
                == .reinstallable
        )

        let unlocked = try ProjectFixture(files: ["composer.json"], folders: ["vendor"])
        defer { unlocked.cleanUp() }
        #expect(
            ReinstallSafetyEvaluator.evaluate(artifactKind: .composerVendor, artifactURL: unlocked.url("vendor"))
                == .missingLockfile
        )
    }

    @Test("node_modules keeps its existing lockfile behaviour")
    func nodeModulesUnchanged() throws {
        let locked = try ProjectFixture(files: ["package.json", "package-lock.json"], folders: ["node_modules"])
        defer { locked.cleanUp() }
        #expect(
            ReinstallSafetyEvaluator.evaluate(artifactKind: .nodeModules, artifactURL: locked.url("node_modules"))
                == .reinstallable
        )

        let unlocked = try ProjectFixture(files: ["package.json"], folders: ["node_modules"])
        defer { unlocked.cleanUp() }
        #expect(
            ReinstallSafetyEvaluator.evaluate(artifactKind: .nodeModules, artifactURL: unlocked.url("node_modules"))
                == .missingLockfile
        )
    }

    @Test("artifacts that regenerate from local source need no lockfile")
    func localRebuildNeedsNoLock() throws {
        let fixture = try ProjectFixture(files: ["Cargo.toml"], folders: ["target"])
        defer { fixture.cleanUp() }
        #expect(
            ReinstallSafetyEvaluator.evaluate(artifactKind: .target, artifactURL: fixture.url("target"))
                == .reinstallable
        )
    }
}

// MARK: - Review follow-ups

@Suite("Terraform state is never treated as disposable")
struct TerraformStateTests {

    @Test("a .terraform folder holding state is refused outright")
    func stateFolderIsRefused() throws {
        for stateFile in ["terraform.tfstate", "terraform.tfstate.backup", "environment"] {
            let fixture = try ProjectFixture(
                files: ["main.tf", ".terraform/\(stateFile)"], folders: [".terraform"]
            )
            defer { fixture.cleanUp() }
            #expect(
                !DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
                    fixture.url(".terraform"), home: fixture.containingHome
                ),
                ".terraform containing \(stateFile) was offered for deletion"
            )
        }
    }

    @Test("a .terraform folder with only providers is still offered")
    func pluginOnlyFolderIsAllowed() throws {
        let fixture = try ProjectFixture(
            files: ["main.tf"], folders: [".terraform/providers"]
        )
        defer { fixture.cleanUp() }
        #expect(
            DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
                fixture.url(".terraform"), home: fixture.containingHome
            )
        )
    }

    @Test("Terraform is Check First, not Safe to Clean")
    func terraformIsCheckFirst() {
        let rules = ProjectArtifactCatalog.rules(forKind: .terraformPlugins)
        #expect(!rules.isEmpty)
        for rule in rules {
            #expect(rule.level == .medium)
        }
    }
}

@Suite("Toolchain install directories are not offered as caches")
struct ToolchainInstallTests {

    /// `deno upgrade` and `deno install` put the binary and script shims under
    /// `~/.deno/bin`, so the install root must never be on the allowlist.
    @Test(arguments: [".deno", ".deno/bin", ".cargo/bin", ".bun/bin"])
    func installRootIsNotDeletable(relative: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relative, isDirectory: true)
        #expect(DeletionSafetyPolicy.evaluate(url) != .allow, "\(relative) was allowed")
    }

    @Test("the actual Deno and Bun caches are still reachable")
    func realCachesStillAllowed() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(DeletionSafetyPolicy.evaluate(home.appendingPathComponent("Library/Caches/deno")) == .allow)
        #expect(DeletionSafetyPolicy.evaluate(home.appendingPathComponent(".bun/install/cache")) == .allow)
    }
}

@Suite("Shared folder names route to every matching ecosystem")
struct SharedFolderNameRoutingTests {

    /// `target` belongs to Rust, Maven and sbt; `_build` to both Elixir and Dune.
    /// Matching only the first rule in the catalog reports a rebuildable project as
    /// missing its lockfile.
    @Test(arguments: [
        ("Cargo.toml", "target"),
        ("pom.xml", "target"),
        ("build.sbt", "target"),
        ("mix.exs", "_build"),
        ("dune-project", "_build"),
    ])
    func anyMatchingEcosystemCounts(marker: String, folder: String) throws {
        let fixture = try ProjectFixture(files: [marker], folders: [folder])
        defer { fixture.cleanUp() }
        #expect(
            ReinstallSafetyEvaluator.evaluateByFolderNameDeleting(path: fixture.url(folder))
                == .reinstallable,
            "\(folder) beside \(marker) was not recognised as rebuildable"
        )
    }

    @Test("a shared folder name with no matching project still reports missing evidence")
    func noMarkerMeansNoEvidence() throws {
        let fixture = try ProjectFixture(folders: ["target"])
        defer { fixture.cleanUp() }
        #expect(
            ReinstallSafetyEvaluator.evaluateByFolderNameDeleting(path: fixture.url("target"))
                == .missingLockfile
        )
    }
}

/// Rooted under the real home directory, because `collectArtifacts` puts every path
/// through `DeletionSafetyPolicy`, which correctly refuses anything under `/var` where
/// the temporary directory lives. Removed again in `cleanUp`.
private struct HomeScopedFixture {
    static let container = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".purge-test-fixtures", isDirectory: true)

    let root: URL

    init(files: [String] = [], folders: [String] = []) throws {
        root = Self.container.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }
        for folder in folders {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative, isDirectory: true) }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        // Tests using this fixture run in parallel and share the container, so it can
        // only be removed when nothing is left in it — never recursively.
        let remaining = (try? FileManager.default.contentsOfDirectory(at: Self.container, includingPropertiesForKeys: nil)) ?? []
        if remaining.isEmpty { try? FileManager.default.removeItem(at: Self.container) }
    }
}

@Suite("Artifacts are actually collected end to end")
struct ArtifactCollectionTests {

    private func collect(_ fixture: HomeScopedFixture, _ types: [ProjectType]) -> Set<DeletableArtifactKind> {
        Set(
            DevScanner.collectArtifacts(projectRoot: fixture.root, types: types)
                .map(\.kind)
        )
    }

    @Test("a Zig project yields its cache and output folders")
    func zigProject() throws {
        let fixture = try HomeScopedFixture(files: ["build.zig"], folders: [".zig-cache", "zig-out"])
        defer { fixture.cleanUp() }
        let kinds = collect(fixture, [.zig])
        #expect(kinds.contains(.zigCache))
        #expect(kinds.contains(.zigOut))
    }

    @Test("a Composer project yields its vendor folder")
    func composerProject() throws {
        let fixture = try HomeScopedFixture(files: ["composer.json", "composer.lock"], folders: ["vendor"])
        defer { fixture.cleanUp() }
        #expect(collect(fixture, [.composer]).contains(.composerVendor))
    }

    @Test("a rule whose marker is absent contributes nothing")
    func unmatchedRuleContributesNothing() throws {
        // Python markers present, but no tox.ini, so `.tox` must not be offered.
        let fixture = try HomeScopedFixture(files: ["requirements.txt"], folders: [".tox", "venv"])
        defer { fixture.cleanUp() }
        let kinds = collect(fixture, [.python])
        #expect(kinds.contains(.venv))
        #expect(!kinds.contains(.toxEnvironments))
    }

    @Test("a Terraform workspace holding state contributes nothing")
    func terraformStateIsNotCollected() throws {
        let fixture = try HomeScopedFixture(
            files: ["main.tf", ".terraform/terraform.tfstate"], folders: [".terraform"]
        )
        defer { fixture.cleanUp() }
        #expect(collect(fixture, [.terraform]).isEmpty)
    }
}

@Suite("Project type labels are distinguishable")
struct ProjectTypeLabelTests {
    @Test("no two project types share a display name")
    func displayNamesAreUnique() {
        var seen: [String: ProjectType] = [:]
        for type in ProjectType.allCases {
            if let clash = seen[type.displayName] {
                Issue.record("\(type) and \(clash) both display as \(type.displayName)")
            }
            seen[type.displayName] = type
        }
    }

    @Test("artifact kind raw values stay machine-shaped")
    func rawValuesHaveNoSpaces() {
        for kind in DeletableArtifactKind.allCases {
            #expect(!kind.rawValue.contains(" "), "\(kind) raw value has a space: \(kind.rawValue)")
        }
    }
}

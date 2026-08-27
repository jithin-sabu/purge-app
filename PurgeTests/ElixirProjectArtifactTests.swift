import Foundation
import Testing
@testable import Purge

/// Elixir/Erlang projects expose two removable folders: `_build` (compiler output)
/// and `deps` (fetched dependency sources). `_build` is allowed by name like every
/// other build folder; `deps` is a plain English word, so it is only ever allowed
/// when a `mix.exs` sits directly beside it.
private struct MixFixture {
    let root: URL

    init(withMixExs: Bool, withMixLock: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-elixir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if withMixExs {
            try Data().write(to: root.appendingPathComponent("mix.exs"))
        }
        if withMixLock {
            try Data().write(to: root.appendingPathComponent("mix.lock"))
        }
    }

    var buildDir: URL { root.appendingPathComponent("_build", isDirectory: true) }
    var depsDir: URL { root.appendingPathComponent("deps", isDirectory: true) }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Elixir artifact safety")
struct ElixirArtifactSafetyTests {

    @Test("_build is allowed when a mix.exs sits beside it")
    func buildFolderAllowed() throws {
        let fixture = try MixFixture(withMixExs: true)
        defer { fixture.cleanUp() }
        #expect(
            DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
                fixture.buildDir,
                home: fixture.root.deletingLastPathComponent().path
            )
        )
    }

    @Test("_build with no mix.exs beside it is not allowed")
    func buildFolderWithoutMarkerRejected() throws {
        let fixture = try MixFixture(withMixExs: false)
        defer { fixture.cleanUp() }
        #expect(
            !DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
                fixture.buildDir,
                home: fixture.root.deletingLastPathComponent().path
            )
        )
    }

    @Test("deps beside a mix.exs is allowed")
    func depsWithMixExsAllowed() throws {
        let fixture = try MixFixture(withMixExs: true)
        defer { fixture.cleanUp() }
        #expect(
            DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
                fixture.depsDir,
                home: fixture.root.deletingLastPathComponent().path
            )
        )
    }

    @Test("deps without a mix.exs is not allowed")
    func depsWithoutMixExsRejected() throws {
        let fixture = try MixFixture(withMixExs: false)
        defer { fixture.cleanUp() }
        #expect(
            !DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
                fixture.depsDir,
                home: fixture.root.deletingLastPathComponent().path
            )
        )
        // Not `== .blockedNotWhitelisted`: the temp fixture lives under /var, which is
        // already a never-delete prefix. What matters here is only that it is not allowed.
        #expect(DeletionSafetyPolicy.evaluate(fixture.depsDir) != .allow)
    }

    @Test("deps outside the home directory is not allowed")
    func depsOutsideHomeRejected() throws {
        let fixture = try MixFixture(withMixExs: true)
        defer { fixture.cleanUp() }
        #expect(
            !DeletionSafetyPolicy.isWhitelistedProjectArtifactPath(
                fixture.depsDir,
                home: "/some/other/home"
            )
        )
    }

    /// Both folder-name rules must lose to the never-delete protections, otherwise a
    /// project checked out inside Pictures or Music would expose that folder.
    @Test(arguments: ["Pictures", "Music", "Movies", "Library/Mail"])
    func neverDeletePrefixesBeatFolderNameRules(protectedComponent: String) {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(protectedComponent, isDirectory: true)
            .appendingPathComponent("my_app", isDirectory: true)
        #expect(DeletionSafetyPolicy.evaluate(base.appendingPathComponent("_build")) == .blockedNeverDelete)
        #expect(DeletionSafetyPolicy.evaluate(base.appendingPathComponent("deps")) == .blockedNeverDelete)
    }
}

@Suite("Elixir reinstall safety")
struct ElixirReinstallSafetyTests {

    @Test("_build only needs mix.exs, since it rebuilds from local source")
    func buildNeedsOnlyMixExs() throws {
        let fixture = try MixFixture(withMixExs: true)
        defer { fixture.cleanUp() }
        #expect(
            ReinstallSafetyEvaluator.evaluate(artifactKind: .elixirBuild, artifactURL: fixture.buildDir)
                == .reinstallable
        )
    }

    @Test("_build without mix.exs is not treated as reinstallable")
    func buildWithoutMixExs() throws {
        let fixture = try MixFixture(withMixExs: false)
        defer { fixture.cleanUp() }
        #expect(
            ReinstallSafetyEvaluator.evaluate(artifactKind: .elixirBuild, artifactURL: fixture.buildDir)
                == .missingLockfile
        )
    }

    @Test("deps needs mix.lock so the same versions come back")
    func depsNeedsLockfile() throws {
        let locked = try MixFixture(withMixExs: true, withMixLock: true)
        defer { locked.cleanUp() }
        #expect(
            ReinstallSafetyEvaluator.evaluate(artifactKind: .elixirDeps, artifactURL: locked.depsDir)
                == .reinstallable
        )

        let unlocked = try MixFixture(withMixExs: true, withMixLock: false)
        defer { unlocked.cleanUp() }
        #expect(
            ReinstallSafetyEvaluator.evaluate(artifactKind: .elixirDeps, artifactURL: unlocked.depsDir)
                == .missingLockfile
        )
    }

    @Test("folder-name fallback routes _build and deps to the Elixir rules")
    func folderNameFallback() throws {
        let fixture = try MixFixture(withMixExs: true, withMixLock: true)
        defer { fixture.cleanUp() }
        #expect(ReinstallSafetyEvaluator.evaluateByFolderNameDeleting(path: fixture.buildDir) == .reinstallable)
        #expect(ReinstallSafetyEvaluator.evaluateByFolderNameDeleting(path: fixture.depsDir) == .reinstallable)
    }
}

@Suite("Elixir explanations")
struct ElixirExplanationTests {
    @Test(arguments: [DeletableArtifactKind.elixirBuild, .elixirDeps])
    func explanationKeyResolves(kind: DeletableArtifactKind) {
        let record = ExplanationDatabase.matchBundledDatabase(folderName: kind.explanationKey)
        #expect(record != nil, "no explanations.json entry for \(kind.explanationKey)")
    }
}

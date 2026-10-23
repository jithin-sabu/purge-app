import Foundation
import Testing
@testable import Purge

/// Which apps Homebrew installed as casks (#254), read from a Caskroom built in
/// a temporary prefix. Only a link from a cask's version folder to the app's
/// bundle counts; the command the match produces is `brew uninstall --cask`.
@Suite("Homebrew cask catalog")
struct HomebrewCaskCatalogTests {
    private let fm = FileManager.default

    private struct Fixture {
        let root: URL
        let prefix: URL
        let apps: URL
    }

    private func makeFixture(brew: Bool = true) throws -> Fixture {
        let root = fm.temporaryDirectory
            .appendingPathComponent("HomebrewCaskCatalogTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let prefix = root.appendingPathComponent("homebrew", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("Caskroom", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        if brew {
            let bin = prefix.appendingPathComponent("bin/brew")
            try fm.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: bin)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        }
        return Fixture(root: root, prefix: prefix, apps: apps)
    }

    private func makeBundle(_ name: String, in fixture: Fixture) throws -> URL {
        let bundle = fixture.apps.appendingPathComponent("\(name).app", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true)
        return bundle
    }

    /// Writes what `brew install --cask` leaves behind: the version folder and,
    /// inside it (or inside `nested`), a link named after the app.
    @discardableResult
    private func link(
        token: String, version: String = "1.0", nested: String? = nil,
        to bundle: URL, in fixture: Fixture
    ) throws -> URL {
        var folder = fixture.prefix.appendingPathComponent("Caskroom/\(token)/\(version)", isDirectory: true)
        if let nested { folder.appendPathComponent(nested, isDirectory: true) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent(bundle.lastPathComponent)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: bundle.path)
        return link
    }

    @Test
    func aLinkedAppBelongsToItsCask() throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let orb = try makeBundle("OrbStack", in: fixture)
        let other = try makeBundle("Other", in: fixture)
        try link(token: "orbstack", version: "2.2.4,21120", to: orb, in: fixture)

        let casks = HomebrewCaskCatalog.installedCasks(prefixes: [fixture.prefix])
        #expect(casks.keys.sorted() == [orb.path])
        let cask = try #require(HomebrewCaskCatalog.cask(owning: orb, prefixes: [fixture.prefix]))
        #expect(cask.token == "orbstack")
        #expect(cask.prefix == fixture.prefix)
        #expect(cask.brewExecutable.path == fixture.prefix.appendingPathComponent("bin/brew").path)
        #expect(HomebrewCaskCatalog.cask(owning: other, prefixes: [fixture.prefix]) == nil)
        // `HomebrewCask.command` is spelled out because the watch agent compiles
        // it without `PackageManager`; the two must say the same thing.
        #expect(cask.command == (PackageManager.homebrewCask.commandPrefix + ["orbstack"]).joined(separator: " "))
        #expect(cask.command == "brew uninstall --cask orbstack")
    }

    /// Some casks keep the app one folder down, as Media Converter does with a
    /// `.localized` folder.
    @Test
    func aLinkOneFolderDownIsFound() throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let bundle = try makeBundle("Media Converter", in: fixture)
        try link(token: "media-converter", version: "3.0.2", nested: "Media Converter.localized", to: bundle, in: fixture)

        #expect(HomebrewCaskCatalog.cask(owning: bundle, prefixes: [fixture.prefix])?.token == "media-converter")
    }

    /// A cask with no app link owns nothing: a command-line binary, a dangling
    /// link, a link to a plain folder, or a link buried deeper than casks go.
    @Test
    func casksWithoutAnAppLinkMatchNothing() throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let binary = fixture.prefix.appendingPathComponent("Caskroom/ngrok/3.22.1", isDirectory: true)
        try fm.createDirectory(at: binary, withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: binary.appendingPathComponent("ngrok"))

        let gone = try makeBundle("Gone", in: fixture)
        try link(token: "gone", to: gone, in: fixture)
        try fm.removeItem(at: gone)

        let folder = fixture.apps.appendingPathComponent("NotAnApp", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let fakeLink = fixture.prefix.appendingPathComponent("Caskroom/folderish/1.0", isDirectory: true)
        try fm.createDirectory(at: fakeLink, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: fakeLink.appendingPathComponent("NotAnApp.app").path, withDestinationPath: folder.path)

        let deep = try makeBundle("Deep", in: fixture)
        try link(token: "deep", nested: "a/b", to: deep, in: fixture)

        #expect(HomebrewCaskCatalog.installedCasks(prefixes: [fixture.prefix]).isEmpty)
    }

    /// A Caskroom folder name reaches `brew`'s argv, so one that could read as
    /// an option or has a space is never a token.
    @Test
    func aFolderNameThatIsNotATokenIsSkipped() throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        for token in ["-rf", "Foo Bar", "UPPER", "a;b"] {
            let bundle = try makeBundle(token.replacingOccurrences(of: "/", with: "-"), in: fixture)
            try link(token: token, to: bundle, in: fixture)
        }
        #expect(HomebrewCaskCatalog.installedCasks(prefixes: [fixture.prefix]).isEmpty)
    }

    @Test
    func aPrefixWithoutBrewIsIgnored() throws {
        let fixture = try makeFixture(brew: false)
        defer { try? fm.removeItem(at: fixture.root) }
        let bundle = try makeBundle("OrbStack", in: fixture)
        try link(token: "orbstack", to: bundle, in: fixture)

        #expect(HomebrewCaskCatalog.installedCasks(prefixes: [fixture.prefix]).isEmpty)
    }

    /// The exact run: Homebrew's own program, `uninstall --cask <token>`, the
    /// fixed environment, and the bundle as the thing that must disappear.
    @Test
    func theUninstallToolRunsBrewUninstallCask() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let bundle = try makeBundle("OrbStack", in: fixture)
        try link(token: "orbstack", to: bundle, in: fixture)
        let cask = try #require(HomebrewCaskCatalog.cask(owning: bundle, prefixes: [fixture.prefix]))
        let home = fixture.root.appendingPathComponent("home", isDirectory: true)

        let tool = HomebrewCaskCatalog.uninstallTool(for: cask, bundleURL: bundle, home: home)
        #expect(tool.manager == .homebrewCask)
        #expect(tool.name == "orbstack")
        #expect(tool.executable?.path == fixture.prefix.appendingPathComponent("bin/brew").path)
        #expect(tool.arguments == ["uninstall", "--cask", "orbstack"])
        #expect(tool.locations.map(\.path) == [bundle.path])
        #expect(tool.command == "brew uninstall --cask orbstack")
        #expect(tool.environment["HOME"] == home.path)
        #expect(tool.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(tool.environment["NONINTERACTIVE"] == "1")
        #expect(tool.environment["PATH"]?.hasPrefix(fixture.prefix.appendingPathComponent("bin").path + ":") == true)
        #expect(!tool.arguments.contains("--force"))
        #expect(!tool.arguments.contains("--zap"))

        // Success means the bundle is gone afterwards; Homebrew's refusal comes
        // back in its own words, with the bundle untouched.
        let refused = await PackageManagerUninstaller.uninstall(tool) { _, _, _ in
            ProcessRunner.Output(status: 1, stdout: Data(), stderr: Data("Error: Cask 'orbstack' is not installed.\n".utf8), timedOut: false)
        }
        #expect(refused == .failed("Error: Cask 'orbstack' is not installed."))
        #expect(fm.fileExists(atPath: bundle.path))
        let removed = await PackageManagerUninstaller.uninstall(tool) { _, _, _ in
            try? FileManager.default.removeItem(at: bundle)
            return ProcessRunner.Output(status: 0, stdout: Data("==> Uninstalling Cask orbstack\n".utf8), stderr: Data(), timedOut: false)
        }
        #expect(removed == .removed)
    }

    /// After a removal, `brew cleanup <token>` and nothing wider: the same
    /// program and environment, scoped to the one cask, and never run when
    /// there is no brew to run.
    @Test
    func cleanupIsScopedToTheCask() async throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let cask = HomebrewCask(token: "keka", prefix: fixture.prefix)
        let seen = CleanupRecorder()
        let ran = await HomebrewCaskCatalog.cleanup(cask, home: fixture.root) { path, arguments, environment in
            seen.record(path, arguments, environment)
            return ProcessRunner.Output(status: 0, stdout: Data("Removing: ...Keka-1.6.8.dmg... (32.8MB)\n".utf8), stderr: Data(), timedOut: false)
        }
        #expect(ran)
        #expect(seen.path == fixture.prefix.appendingPathComponent("bin/brew").path)
        #expect(seen.arguments == ["cleanup", "--scrub", "keka"])
        #expect(seen.environment?["HOMEBREW_NO_AUTO_UPDATE"] == "1")

        let failed = await HomebrewCaskCatalog.cleanup(cask, home: fixture.root) { _, _, _ in
            ProcessRunner.Output(status: 1, stdout: Data(), stderr: Data("Error: No available cask with the name \"keka\".\n".utf8), timedOut: false)
        }
        #expect(!failed)

        let noBrew = try makeFixture(brew: false)
        defer { try? fm.removeItem(at: noBrew.root) }
        let skipped = await HomebrewCaskCatalog.cleanup(HomebrewCask(token: "keka", prefix: noBrew.prefix), home: noBrew.root) { _, _, _ in
            Issue.record("cleanup must not run without brew")
            return nil
        }
        #expect(!skipped)
    }

    /// Casks belong to Installed Apps, behind the review sheet and its toggle.
    /// The Command-line tools scan reads the same prefix and must never list
    /// one, or a cask app could be removed from a section that never shows it.
    @Test
    func theCommandLineToolsScanNeverListsACask() throws {
        let fixture = try makeFixture()
        defer { try? fm.removeItem(at: fixture.root) }
        let bundle = try makeBundle("OrbStack", in: fixture)
        try link(token: "orbstack", to: bundle, in: fixture)
        let home = fixture.root.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let tools = PackageManagerToolScanner.tools(
            roots: PackageManagerToolScanner.Roots(home: home, homebrewPrefixes: [fixture.prefix])
        )
        #expect(tools.isEmpty)
        #expect(!tools.contains { $0.manager == .homebrewCask })
    }

    /// A prefix with no brew gives a tool with no program, which the uninstaller
    /// refuses to run.
    @Test
    func aCaskWithoutBrewCannotRun() async throws {
        let fixture = try makeFixture(brew: false)
        defer { try? fm.removeItem(at: fixture.root) }
        let bundle = try makeBundle("OrbStack", in: fixture)
        let tool = HomebrewCaskCatalog.uninstallTool(for: HomebrewCask(token: "orbstack", prefix: fixture.prefix), bundleURL: bundle)
        #expect(!tool.canRun)
        #expect(await PackageManagerUninstaller.uninstall(tool) { _, _, _ in nil } == .managerMissing)
    }
}

/// The review sheet's plan for a cask app (#254): the toggle, what counts as
/// deleted permanently, and the words that follow from it.
@MainActor
@Suite("Homebrew cask apps in the uninstall plan")
struct HomebrewCaskUninstallPlanTests {
    private let info = SafetyInfo(level: .medium, headline: "", explanation: "", recoverySteps: "", reinstallCommand: nil)
    private let cask = HomebrewCask(token: "orbstack", prefix: URL(fileURLWithPath: "/opt/homebrew", isDirectory: true))

    private func app(_ name: String, cask: HomebrewCask?) -> InstalledApp {
        InstalledApp(
            name: name,
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true),
            bundleID: "com.example.\(name)",
            bundleSizeBytes: 1_000,
            isRunning: false,
            homebrewCask: cask
        )
    }

    private func items(for app: InstalledApp, bundleSelected: Bool = true) -> [UninstallItem] {
        [
            UninstallItem(path: app.bundleURL, sizeBytes: 1_000, category: .bundle, safetyInfo: info,
                          matchReason: .appBundle, isSelected: bundleSelected),
            UninstallItem(path: URL(fileURLWithPath: "/Users/me/Library/Caches/\(app.bundleID!)", isDirectory: true),
                          sizeBytes: 200, category: .caches, safetyInfo: info, matchReason: .bundleID, isSelected: true)
        ]
    }

    @Test
    func aCaskAppStartsOnHomebrewAndAnOrdinaryAppNever() {
        let orb = app("OrbStack", cask: cask)
        let plain = app("Plain", cask: nil)
        let orbPlan = UninstallAppPlan(app: orb, items: items(for: orb))
        let plainPlan = UninstallAppPlan(app: plain, items: items(for: plain))

        #expect(orbPlan.removesThroughHomebrew)
        #expect(orbPlan.homebrewCask == cask)
        #expect(orbPlan.permanentlyDeletedItem?.path == orb.bundleURL)
        #expect(!plainPlan.removesThroughHomebrew)
        #expect(plainPlan.homebrewCask == nil)
        #expect(plainPlan.permanentlyDeletedItem == nil)
        // Only the bundle is Homebrew's; the cache still goes to the Trash.
        let plan = UninstallPlan(id: "p", apps: [orbPlan, plainPlan])
        #expect(plan.permanentlyDeletedItems.map(\.path) == [orb.bundleURL])
        #expect(plan.totalSelectedItems == 4)
        #expect(plan.trashedItemCount == 3)
    }

    @Test
    func theToggleOffOrAnUntickedBundleMeansNothingIsPermanent() {
        let orb = app("OrbStack", cask: cask)
        var off = UninstallAppPlan(app: orb, items: items(for: orb))
        off.removesThroughHomebrew = false
        #expect(off.homebrewCask == nil)
        #expect(off.permanentlyDeletedItem == nil)

        let leftoversOnly = UninstallAppPlan(app: orb, items: items(for: orb, bundleSelected: false))
        #expect(leftoversOnly.removesThroughHomebrew)
        #expect(leftoversOnly.homebrewCask == nil)
        #expect(leftoversOnly.permanentlyDeletedItem == nil)
    }

    @Test
    func theSheetOffersTheChoiceAsTwoButtons() {
        let orb = app("OrbStack", cask: cask)
        let keka = app("Keka", cask: HomebrewCask(token: "keka", prefix: cask.prefix))
        let plain = app("Plain", cask: nil)
        let one = UninstallPlan(id: "o", apps: [UninstallAppPlan(app: orb, items: items(for: orb))])
        let two = UninstallPlan(id: "t", apps: [UninstallAppPlan(app: orb, items: items(for: orb)), UninstallAppPlan(app: keka, items: items(for: keka))])
        let trashOnly = UninstallPlan(id: "p", apps: [UninstallAppPlan(app: plain, items: items(for: plain))])
        let leftoversOnly = UninstallPlan(id: "l", apps: [UninstallAppPlan(app: orb, items: items(for: orb, bundleSelected: false))])

        // No cask app, or a cask app whose bundle is unticked: one button, as before.
        #expect(UninstallReviewSheet.introText(for: trashOnly).contains("Nothing is deleted permanently"))
        #expect(UninstallReviewSheet.primaryButtonTitle(for: trashOnly) == "Move 2 to Trash")
        #expect(UninstallReviewSheet.secondaryButtonTitle(for: trashOnly) == nil)
        #expect(UninstallReviewSheet.primaryButtonTitle(for: leftoversOnly) == "Move 1 to Trash")
        #expect(UninstallReviewSheet.secondaryButtonTitle(for: leftoversOnly) == nil)

        // A cask app with its bundle ticked: the intro names it and says what
        // each button does, and the footer offers both.
        #expect(UninstallReviewSheet.introText(for: one).hasPrefix("Homebrew installed OrbStack."))
        #expect(UninstallReviewSheet.introText(for: one).contains("deletes the app permanently"))
        #expect(UninstallReviewSheet.introText(for: two).hasPrefix("Homebrew installed OrbStack and Keka."))
        #expect(UninstallReviewSheet.introText(for: two).contains("deletes those apps permanently"))
        #expect(UninstallReviewSheet.primaryButtonTitle(for: one) == "Remove with Homebrew")
        #expect(UninstallReviewSheet.secondaryButtonTitle(for: one) == "Move All to Trash")

        // Each button hands back the plan with every app set the way it says.
        let toTrash = UninstallReviewSheet.plan(two, removingThroughHomebrew: false)
        #expect(toTrash.apps.allSatisfy { !$0.removesThroughHomebrew })
        #expect(toTrash.permanentlyDeletedItems.isEmpty)
        let viaHomebrew = UninstallReviewSheet.plan(two, removingThroughHomebrew: true)
        #expect(viaHomebrew.permanentlyDeletedItems.map(\.path) == [orb.bundleURL, keka.bundleURL])
        #expect(cask.command == "brew uninstall --cask orbstack")
    }
}

private final class CleanupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: (String, [String], [String: String])?

    func record(_ path: String, _ arguments: [String], _ environment: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        values = (path, arguments, environment)
    }

    var path: String? { lock.lock(); defer { lock.unlock() }; return values?.0 }
    var arguments: [String]? { lock.lock(); defer { lock.unlock() }; return values?.1 }
    var environment: [String: String]? { lock.lock(); defer { lock.unlock() }; return values?.2 }
}

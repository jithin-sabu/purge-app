import Foundation
import Testing
@testable import Purge

/// On a Mac without Xcode or the Command Line Tools, running a `/usr/bin` shim
/// such as `xcrun` or `git` shows macOS's "install the command line developer
/// tools" dialog instead of failing, and the launch scan did that on every start
/// (#298). These check that nothing in the scan reaches a shim unless
/// `xcode-select -p` names a developer directory whose tools exist. Every
/// `xcode-select` and `xcrun` launch here is a fake. The one git test runs the
/// real `/usr/bin/git`, which the test target needs anyway.
@Suite("Developer tools install prompt")
struct DeveloperToolsPromptTests {
    private static let xcodeDirectory = "/Applications/Xcode.app/Contents/Developer"
    private static let xcodeTools = xcodeDirectory + "/usr/bin/xcrun"

    private static func output(_ status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) -> ProcessRunner.Output {
        ProcessRunner.Output(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), timedOut: timedOut)
    }

    /// Records each launch and answers every one the same way.
    private final class FakeLaunches: @unchecked Sendable {
        var launched: [(path: String, arguments: [String])] = []
        var checked: [String] = []
        let output: ProcessRunner.Output?

        init(_ output: ProcessRunner.Output?) {
            self.output = output
        }

        func launch(_ path: String, _ arguments: [String], _ timeout: TimeInterval) -> ProcessRunner.Output? {
            launched.append((path, arguments))
            return output
        }
    }

    private func resolve(_ fake: FakeLaunches, toolsExist: Bool = true) -> DeveloperDirectory.Lookup {
        DeveloperDirectory.resolve(
            launch: { fake.launch($0, $1, $2) },
            isExecutable: { fake.checked.append($0); return toolsExist }
        )
    }

    // MARK: - xcode-select

    @Test func developerDirectoryComesFromXcodeSelect() {
        let fake = FakeLaunches(Self.output(0, stdout: Self.xcodeDirectory + "\n"))
        #expect(resolve(fake) == .found(Self.xcodeDirectory))
        #expect(fake.launched.map(\.path) == [DeveloperDirectory.xcodeSelectPath])
        #expect(fake.launched.first?.arguments == ["-p"])
        #expect(fake.checked == [Self.xcodeTools])
    }

    /// `xcode-select -p` exits 2 with this text on a Mac with no developer tools.
    @Test func noDeveloperDirectoryWhenXcodeSelectHasNone() {
        let fake = FakeLaunches(Self.output(
            2,
            stderr: "xcode-select: error: unable to get active developer directory, use `sudo xcode-select --switch path/to/Xcode.app` to specify the Xcode that you wish to use for command line developer tools"
        ))
        #expect(resolve(fake) == .missing)
        let empty = FakeLaunches(Self.output(0, stdout: "\n"))
        #expect(resolve(empty) == .missing)
    }

    /// An Xcode that was trashed leaves its path selected, and a Command Line
    /// Tools folder a macOS upgrade emptied is still a folder. The shims ask to
    /// install the tools for both just as they do for no path, so both count as
    /// none.
    @Test func selectedDirectoryWithoutToolsCountsAsNone() {
        let fake = FakeLaunches(Self.output(0, stdout: Self.xcodeDirectory + "\n"))
        #expect(resolve(fake, toolsExist: false) == .missing)
    }

    /// A launch that failed or timed out says nothing about the Mac.
    @Test func unansweredXcodeSelectIsNeitherFoundNorNone() {
        let timedOut = FakeLaunches(Self.output(0, stdout: "/Library/Developer/CommandLineTools", timedOut: true))
        #expect(resolve(timedOut) == .unanswered)
        let unlaunchable = FakeLaunches(nil)
        #expect(resolve(unlaunchable) == .unanswered)
    }

    // MARK: - Cache

    private func active(_ cache: DeveloperDirectory.Cache, _ fake: FakeLaunches, toolsExist: Bool = true) -> String? {
        cache.active(
            launch: { fake.launch($0, $1, $2) },
            isExecutable: { fake.checked.append($0); return toolsExist }
        )
    }

    @Test func definiteAnswersAreAskedOnce() {
        let cache = DeveloperDirectory.Cache()
        let found = FakeLaunches(Self.output(0, stdout: Self.xcodeDirectory))
        #expect(active(cache, found) == Self.xcodeDirectory)
        #expect(active(cache, found) == Self.xcodeDirectory)
        #expect(found.launched.count == 1)

        let none = DeveloperDirectory.Cache()
        let missing = FakeLaunches(Self.output(2))
        #expect(active(none, missing) == nil)
        #expect(active(none, missing) == nil)
        #expect(missing.launched.count == 1)
    }

    /// The reviewed bug: a timed-out `xcode-select` on a busy cold start was
    /// remembered as "no developer tools" until Purge quit, which made every git
    /// status "unknown" and skipped the uncommitted-changes confirmation.
    @Test func unansweredLookupIsAskedAgain() {
        let cache = DeveloperDirectory.Cache()
        let timedOut = FakeLaunches(Self.output(0, stdout: Self.xcodeDirectory, timedOut: true))
        #expect(active(cache, timedOut) == nil)
        #expect(active(cache, timedOut) == nil)
        #expect(timedOut.launched.count == 2)

        let answered = FakeLaunches(Self.output(0, stdout: Self.xcodeDirectory))
        #expect(active(cache, answered) == Self.xcodeDirectory)
        #expect(answered.launched.count == 1)
        #expect(active(cache, answered) == Self.xcodeDirectory)
        #expect(answered.launched.count == 1)
    }

    /// Purge's own uninstaller can trash Xcode while Purge runs.
    @Test func foundDirectoryIsCheckedOnDiskAtEveryCall() {
        let cache = DeveloperDirectory.Cache()
        let fake = FakeLaunches(Self.output(0, stdout: Self.xcodeDirectory))
        #expect(active(cache, fake) == Self.xcodeDirectory)
        #expect(active(cache, fake, toolsExist: false) == nil)
        #expect(active(cache, fake) == Self.xcodeDirectory)
        #expect(fake.launched.count == 1)
    }

    // MARK: - simctl launcher

    private func resolveLauncher(
        _ fake: FakeLaunches,
        developerDirectoryExists: Bool,
        frameworkExists: Bool
    ) -> Simctl.Launcher? {
        Simctl.resolveLauncher(
            developerDirectoryExists: { developerDirectoryExists },
            launch: { fake.launch($0, $1, $2) },
            isExecutable: { $0 == Simctl.frameworkPath && frameworkExists }
        )
    }

    /// The bug: `xcrun --find simctl` ran on every Mac, because `/usr/bin/xcrun`
    /// exists on every Mac.
    @Test func xcrunIsNeverRunWithoutADeveloperDirectory() {
        let fake = FakeLaunches(Self.output(0, stdout: Self.xcodeDirectory + "/usr/bin/simctl"))
        #expect(resolveLauncher(fake, developerDirectoryExists: false, frameworkExists: false) == nil)
        #expect(resolveLauncher(fake, developerDirectoryExists: false, frameworkExists: true) == .framework)
        #expect(fake.launched.isEmpty)
    }

    @Test func xcrunIsUsedWhenItFindsSimctl() {
        let fake = FakeLaunches(Self.output(0, stdout: Self.xcodeDirectory + "/usr/bin/simctl"))
        #expect(resolveLauncher(fake, developerDirectoryExists: true, frameworkExists: true) == .xcrun)
        #expect(fake.launched.map(\.path) == [Simctl.xcrunPath])
        #expect(fake.launched.first?.arguments == ["--find", "simctl"])
    }

    /// The Command Line Tools alone give a developer directory with no simctl in it.
    @Test func frameworkCopyStandsInWhenXcrunCannotFindSimctl() {
        let fake = FakeLaunches(Self.output(72, stderr: SimulatorDeviceRemovalTests.missingToolText))
        #expect(resolveLauncher(fake, developerDirectoryExists: true, frameworkExists: true) == .framework)
        #expect(resolveLauncher(fake, developerDirectoryExists: true, frameworkExists: false) == nil)
    }

    /// A cached `.xcrun` after Xcode is trashed would show the install prompt.
    @Test func cachedXcrunGivesWayWhenTheDeveloperDirectoryGoes() {
        func usable(_ cached: Simctl.Launcher?, developerDirectory: Bool, framework: Bool) -> Simctl.Launcher? {
            Simctl.stillUsable(
                cached,
                developerDirectoryExists: { developerDirectory },
                isExecutable: { $0 == Simctl.frameworkPath && framework }
            )
        }
        #expect(usable(.xcrun, developerDirectory: false, framework: true) == .framework)
        #expect(usable(.xcrun, developerDirectory: false, framework: false) == nil)
        #expect(usable(.xcrun, developerDirectory: true, framework: false) == .xcrun)
        #expect(usable(.framework, developerDirectory: false, framework: true) == .framework)
        #expect(usable(nil, developerDirectory: true, framework: true) == nil)
    }

    // MARK: - Runtime discovery

    @Test func coreSimulatorIsPresentOnlyWhenOneOfItsFoldersExists() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(Simctl.coreSimulatorPresent(home: home, systemFolders: []) == false)
        let missingStore = home.appendingPathComponent("missing", isDirectory: true).path
        #expect(Simctl.coreSimulatorPresent(home: home, systemFolders: [missingStore]) == false)

        let store = home.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        #expect(Simctl.coreSimulatorPresent(home: home, systemFolders: [store.path]))

        let userFolder = home.appendingPathComponent(Simctl.userFolderRelativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        #expect(Simctl.coreSimulatorPresent(home: home, systemFolders: []))
    }

    @Test func runtimeDiscoveryLaunchesNothingWithoutCoreSimulator() async {
        let runtimes = await DevScanner().discoverSimulatorRuntimes(coreSimulatorPresent: false)
        #expect(runtimes.isEmpty)
    }

    // MARK: - git

    /// A clean repository, so git would answer `.clean` if it were run. The
    /// fixture runs the real git, as `GitStatusUntrustedConfigTests` does: the
    /// test target cannot run on a Mac without developer tools, so the setup
    /// cannot bring the prompt.
    @Test func gitIsNotRunWithoutADeveloperDirectory() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-git-\(UUID().uuidString)", isDirectory: true)
        let folder = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Self.git(in: folder, "init", "-q")
        try Data("hello".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Self.git(in: folder, "add", "a.txt")
        try Self.git(in: folder, "commit", "-qm", "init")

        let withTools = await Task.detached {
            GitStatusChecker.invokeGit(repository: folder, developerDirectoryExists: { true })
        }.value
        #expect(withTools == .clean)
        let withoutTools = await Task.detached {
            GitStatusChecker.invokeGit(repository: folder, developerDirectoryExists: { false })
        }.value
        #expect(withoutTools == .unknown)
    }

    /// The user's own git config is kept out: a signing key that is missing or a
    /// global hook that says no would leave `a.txt` staged and the repository
    /// dirty, and the failure would point nowhere near the cause.
    private static func git(in folder: URL, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", folder.path,
            "-c", "user.name=Purge Tests",
            "-c", "user.email=tests@purge.invalid",
            "-c", "commit.gpgsign=false",
            "-c", "core.hooksPath=/dev/null",
            "-c", "init.defaultBranch=main",
        ] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }
}

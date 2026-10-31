import Foundation
import Testing
@testable import Purge

/// On a Mac without Xcode or the Command Line Tools, running a `/usr/bin` shim
/// such as `xcrun` or `git` shows macOS's "install the command line developer
/// tools" dialog instead of failing, and the launch scan did that on every start
/// (#298). These check that nothing in the scan reaches a shim unless
/// `xcode-select -p` names a developer directory that exists. Every launch here
/// is a fake; no tool is run.
@Suite("Developer tools install prompt")
struct DeveloperToolsPromptTests {
    private static func output(_ status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) -> ProcessRunner.Output {
        ProcessRunner.Output(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), timedOut: timedOut)
    }

    /// Records each launch and answers every one the same way.
    private final class FakeLaunches: @unchecked Sendable {
        var launched: [(path: String, arguments: [String])] = []
        let output: ProcessRunner.Output?

        init(_ output: ProcessRunner.Output?) {
            self.output = output
        }

        func launch(_ path: String, _ arguments: [String], _ timeout: TimeInterval) -> ProcessRunner.Output? {
            launched.append((path, arguments))
            return output
        }
    }

    // MARK: - xcode-select

    @Test func developerDirectoryComesFromXcodeSelect() {
        let fake = FakeLaunches(Self.output(0, stdout: "/Applications/Xcode.app/Contents/Developer\n"))
        let path = DeveloperDirectory.resolve(launch: { fake.launch($0, $1, $2) }, isDirectory: { _ in true })
        #expect(path == "/Applications/Xcode.app/Contents/Developer")
        #expect(fake.launched.map(\.path) == [DeveloperDirectory.xcodeSelectPath])
        #expect(fake.launched.first?.arguments == ["-p"])
    }

    /// `xcode-select -p` exits 2 with this text on a Mac with no developer tools.
    @Test func noDeveloperDirectoryWhenXcodeSelectHasNone() {
        let fake = FakeLaunches(Self.output(
            2,
            stderr: "xcode-select: error: unable to get active developer directory, use `sudo xcode-select --switch path/to/Xcode.app` to specify the Xcode that you wish to use for command line developer tools"
        ))
        #expect(DeveloperDirectory.resolve(launch: { fake.launch($0, $1, $2) }, isDirectory: { _ in true }) == nil)
    }

    /// An Xcode that was trashed leaves its path selected. The shims ask to install
    /// the tools for it just as they do for no path, so it counts as none.
    @Test func selectedDirectoryThatIsGoneCountsAsNone() {
        let fake = FakeLaunches(Self.output(0, stdout: "/Applications/Xcode.app/Contents/Developer\n"))
        #expect(DeveloperDirectory.resolve(launch: { fake.launch($0, $1, $2) }, isDirectory: { _ in false }) == nil)
    }

    @Test func unansweredXcodeSelectCountsAsNone() {
        let timedOut = FakeLaunches(Self.output(0, stdout: "/Library/Developer/CommandLineTools", timedOut: true))
        #expect(DeveloperDirectory.resolve(launch: { timedOut.launch($0, $1, $2) }, isDirectory: { _ in true }) == nil)
        let unlaunchable = FakeLaunches(nil)
        #expect(DeveloperDirectory.resolve(launch: { unlaunchable.launch($0, $1, $2) }, isDirectory: { _ in true }) == nil)
        let empty = FakeLaunches(Self.output(0, stdout: "\n"))
        #expect(DeveloperDirectory.resolve(launch: { empty.launch($0, $1, $2) }, isDirectory: { _ in true }) == nil)
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
        let fake = FakeLaunches(Self.output(0, stdout: "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl"))
        #expect(resolveLauncher(fake, developerDirectoryExists: false, frameworkExists: false) == nil)
        #expect(resolveLauncher(fake, developerDirectoryExists: false, frameworkExists: true) == .framework)
        #expect(fake.launched.isEmpty)
    }

    @Test func xcrunIsUsedWhenItFindsSimctl() {
        let fake = FakeLaunches(Self.output(0, stdout: "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl"))
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

    /// A clean repository, so git would answer `.clean` if it were run.
    @Test func gitIsNotRunWithoutADeveloperDirectory() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-git-\(UUID().uuidString)", isDirectory: true)
        let folder = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Self.git(in: folder, "init", "-q")
        try Data("hello".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Self.git(in: folder, "add", "a.txt")
        try Self.git(in: folder, "-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-qm", "init")

        let withTools = await Task.detached {
            GitStatusChecker.invokeGit(repository: folder, developerDirectoryExists: { true })
        }.value
        #expect(withTools == .clean)
        let withoutTools = await Task.detached {
            GitStatusChecker.invokeGit(repository: folder, developerDirectoryExists: { false })
        }.value
        #expect(withoutTools == .unknown)
    }

    private static func git(in folder: URL, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }
}

import Foundation
import Testing
@testable import Purge

/// Ollama's store path read from launchd (#318). No test runs `launchctl` or
/// touches the shared values: each passes its own runner or launchd values.
@Suite("OLLAMA_MODELS from launchd (#318)")
struct LaunchdEnvironmentTests {
    private func runner(status: Int32 = 0, stdout: String) -> LaunchdEnvironment.Runner {
        { _, _ in ProcessRunner.Output(status: status, stdout: Data(stdout.utf8), stderr: Data(), timedOut: false) }
    }

    @Test("launchctl getenv's answer is read, and an unset name reads as nil")
    func readsValue() {
        #expect(LaunchdEnvironment.value(of: "OLLAMA_MODELS", runner: runner(stdout: "/Volumes/T7/models\n"))
            == "/Volumes/T7/models")
        #expect(LaunchdEnvironment.value(of: "OLLAMA_MODELS", runner: runner(stdout: "\n")) == nil)
        #expect(LaunchdEnvironment.value(of: "OLLAMA_MODELS", runner: runner(status: 1, stdout: "x")) == nil)
        #expect(LaunchdEnvironment.value(of: "OLLAMA_MODELS", runner: { _, _ in nil }) == nil)
    }

    @Test("A read that failed is told apart from an unset name (#406)")
    func aFailedReadIsNotUnset() {
        let name = "RUSTUP_TOOLCHAIN"
        #expect(LaunchdEnvironment.read(name, runner: runner(stdout: "1.84.0\n")) == .value("1.84.0"))
        #expect(LaunchdEnvironment.read(name, runner: runner(stdout: "\n")) == .unset)
        #expect(LaunchdEnvironment.read(name, runner: runner(status: 1, stdout: "")) == .failed)
        #expect(LaunchdEnvironment.read(name, runner: { _, _ in nil }) == .failed)
        let timedOut: LaunchdEnvironment.Runner = { _, _ in
            ProcessRunner.Output(status: 0, stdout: Data("1.84.0".utf8), stderr: Data(), timedOut: true)
        }
        #expect(LaunchdEnvironment.read(name, runner: timedOut) == .failed)
        #expect(LaunchdEnvironment.readNow(name, runner: timedOut) == .failed)
        #expect(LaunchdEnvironment.readNow(name, runner: runner(stdout: "nightly\n")) == .value("nightly"))
        #expect(LaunchdEnvironment.names.contains(name))
    }

    @Test("launchd fills a name Purge started without, and never replaces one it has")
    func merging() {
        let launchd = ["OLLAMA_MODELS": "/Volumes/T7/models"]
        #expect(LaunchdEnvironment.merged(into: [:], launchd: launchd)["OLLAMA_MODELS"] == "/Volumes/T7/models")
        #expect(LaunchdEnvironment.merged(into: ["OLLAMA_MODELS": ""], launchd: launchd)["OLLAMA_MODELS"]
            == "/Volumes/T7/models")
        #expect(LaunchdEnvironment.merged(into: ["OLLAMA_MODELS": "/Users/me/models"], launchd: launchd)["OLLAMA_MODELS"]
            == "/Users/me/models")
    }

    @Test("A store found through launchd's path is one the gate takes")
    func scannerAndGateAgree() throws {
        let fm = FileManager.default
        let drive = fm.temporaryDirectory.appendingPathComponent("purge-ollama-\(UUID().uuidString)", isDirectory: true)
        let home = fm.temporaryDirectory.appendingPathComponent("purge-ollama-home-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: drive)
            try? fm.removeItem(at: home)
        }
        let store = drive.appendingPathComponent("models", isDirectory: true)
        let manifest = store.appendingPathComponent("manifests/registry.ollama.ai/library/gemma4/latest")
        try fm.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: store.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let body: [String: Any] = [
            "schemaVersion": 2,
            "layers": [["mediaType": "application/vnd.ollama.image.model", "digest": "sha256:aaa"]]
        ]
        try JSONSerialization.data(withJSONObject: body).write(to: manifest)
        try Data(repeating: 0, count: 4096).write(to: store.appendingPathComponent("blobs/sha256-aaa"))

        let environment = LaunchdEnvironment.merged(into: [:], launchd: ["OLLAMA_MODELS": store.path])
        let model = try #require(AIModelScanner.ollamaModels(home: home, environment: environment).first)
        #expect(!model.componentPaths.isEmpty)
        for component in model.componentPaths {
            #expect(AIModelScanPolicy.isEligibleForDeletion(component, home: home, environment: environment))
            // Without launchd's value the default store is elsewhere.
            #expect(!AIModelScanPolicy.isEligibleForDeletion(component, home: home, environment: [:]))
        }
    }

    @Test("An OLLAMA_MODELS value that names / or the home folder or above is ignored")
    func broadOllamaRootsAreIgnored() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let fallback = "/Users/someone/.ollama/models"
        for broad in ["/", "/Users", "/Users/someone", "/Users/someone/"] {
            #expect(AIModelScanPolicy.ollamaRoot(home: home, environment: ["OLLAMA_MODELS": broad]).path == fallback, "\(broad)")
        }
        // `~` expands to the real home folder.
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        #expect(AIModelScanPolicy.ollamaRoot(home: realHome, environment: ["OLLAMA_MODELS": "~"]).path
            == realHome.appendingPathComponent(".ollama/models").standardizedFileURL.path)
        #expect(AIModelScanPolicy.ollamaRoot(home: home, environment: ["OLLAMA_MODELS": "/Volumes/T7/models"]).path
            == "/Volumes/T7/models")
    }

    @Test("Under an Ollama store the gate takes only manifests and sha256 blobs")
    func ollamaGateIsNarrow() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("purge-ollama-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let store = home.appendingPathComponent("Documents", isDirectory: true)
        let files = ["notes.txt", "blobs/readme.txt", "blobs/sha256-abc", "manifests/registry.ollama.ai/library/m/latest"]
        for file in files {
            let url = store.appendingPathComponent(file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let environment = ["OLLAMA_MODELS": store.path]
        func passes(_ file: String) -> Bool {
            AIModelScanPolicy.isEligibleForDeletion(store.appendingPathComponent(file), home: home, environment: environment)
        }
        #expect(!passes("notes.txt"))
        #expect(!passes("blobs/readme.txt"))
        #expect(passes("blobs/sha256-abc"))
        #expect(passes("manifests/registry.ollama.ai/library/m/latest"))
    }

    @Test("Under a broad Ollama root, another store's model still reaches its own gate")
    func otherStoresUnderTheOllamaRoot() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("purge-ollama-overlap-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let whisper = home.appendingPathComponent(".cache/whisper", isDirectory: true)
        try fm.createDirectory(at: whisper, withIntermediateDirectories: true)
        let model = whisper.appendingPathComponent("base.pt")
        try Data(repeating: 1, count: 4096).write(to: model)
        let notes = home.appendingPathComponent(".cache/notes.txt")
        try Data("x".utf8).write(to: notes)

        let environment = ["OLLAMA_MODELS": home.appendingPathComponent(".cache").path]
        #expect(AIModelScanPolicy.isEligibleForDeletion(model, home: home, environment: environment)
            == AIModelScanPolicy.isEligibleForDeletion(model, home: home, environment: [:]))
        #expect(AIModelScanPolicy.isEligibleForDeletion(model, home: home, environment: [:]))
        #expect(!AIModelScanPolicy.isEligibleForDeletion(notes, home: home, environment: environment))
    }
}

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
}

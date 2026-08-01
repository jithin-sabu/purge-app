import Foundation
import Testing
@testable import Purge

@Suite("Local AI models are found as models, not as blobs")
struct AIModelScanTests {
    /// Builds a throwaway home directory holding an Ollama store, so the tests
    /// exercise real manifest parsing and blob reference counting rather than
    /// whatever happens to be installed on the machine running them.
    private func makeOllamaHome(
        models: [String: [String]],
        blobBytes: Int = 4096
    ) throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = home.appendingPathComponent(".ollama/models", isDirectory: true)
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)

        var written: Set<String> = []
        for (name, digests) in models {
            let manifest = root
                .appendingPathComponent("manifests/registry.ollama.ai/library", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("latest", isDirectory: false)
            try fm.createDirectory(
                at: manifest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let layers = digests.map { ["mediaType": "application/vnd.ollama.image.model", "digest": "sha256:\($0)"] }
            let body: [String: Any] = ["schemaVersion": 2, "layers": layers]
            try JSONSerialization.data(withJSONObject: body).write(to: manifest)

            for digest in digests where !written.contains(digest) {
                written.insert(digest)
                try Data(repeating: 0, count: blobBytes)
                    .write(to: blobs.appendingPathComponent("sha256-\(digest)"))
            }
        }
        return home
    }

    @Test("An Ollama model is named the way the user pulled it")
    func ollamaModelUsesRegistryName() throws {
        let home = try makeOllamaHome(models: ["gemma4": ["aaa"]])
        defer { try? FileManager.default.removeItem(at: home) }

        let models = AIModelScanner.ollamaModels(home: home, environment: [:])
        #expect(models.count == 1)
        #expect(models.first?.displayName == "gemma4:latest")
        #expect(models.first?.locationLabel == "Ollama")
        #expect(models.first?.category == .aiModel)
    }

    @Test("Deleting a model takes its manifest and its own blobs")
    func ollamaModelComponentsIncludeManifestFirst() throws {
        let home = try makeOllamaHome(models: ["gemma4": ["aaa", "bbb"]])
        defer { try? FileManager.default.removeItem(at: home) }

        let model = try #require(AIModelScanner.ollamaModels(home: home, environment: [:]).first)
        #expect(model.componentPaths.count == 3)
        // Manifest first: an interrupted delete must not leave Ollama listing a
        // model whose weights are already gone.
        #expect(model.componentPaths.first?.lastPathComponent == "latest")
        #expect(model.componentPaths.dropFirst().allSatisfy { $0.lastPathComponent.hasPrefix("sha256-") })
    }

    @Test("A blob shared with another model is neither counted nor deleted")
    func sharedBlobsAreExcluded() throws {
        let home = try makeOllamaHome(models: [
            "gemma4": ["shared", "onlyA"],
            "llama3": ["shared", "onlyB"]
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let models = AIModelScanner.ollamaModels(home: home, environment: [:])
        #expect(models.count == 2)

        for model in models {
            // Only the exclusively-owned blob is reclaimable, so the row must
            // promise one blob's worth of space, not two.
            #expect(model.sizeBytes == 4096)
            #expect(!model.componentPaths.contains { $0.lastPathComponent == "sha256-shared" })
        }
    }

    @Test("OLLAMA_MODELS moves the store")
    func honoursOllamaModelsOverride() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let relocated = AIModelScanPolicy.ollamaRoot(
            home: home,
            environment: ["OLLAMA_MODELS": "/Volumes/External/models"]
        )
        #expect(relocated.path == "/Volumes/External/models")
        #expect(AIModelScanPolicy.ollamaRoot(home: home, environment: [:]).path
            == "/Users/someone/.ollama/models")
    }

    @Test("Only paths inside a model root may be deleted")
    func deletionGateIsNarrow() throws {
        let home = try makeOllamaHome(models: ["gemma4": ["aaa"]])
        defer { try? FileManager.default.removeItem(at: home) }

        let model = try #require(AIModelScanner.ollamaModels(home: home, environment: [:]).first)
        for component in model.componentPaths {
            #expect(AIModelScanPolicy.isEligibleForDeletion(component, home: home, environment: [:]))
        }

        // The store itself is not a row, and must never be deletable as one.
        let root = home.appendingPathComponent(".ollama/models", isDirectory: true)
        #expect(!AIModelScanPolicy.isEligibleForDeletion(root, home: home, environment: [:]))
        #expect(!AIModelScanPolicy.isEligibleForDeletion(
            home.appendingPathComponent("Documents/notes.txt"), home: home, environment: [:]
        ))
    }

    @Test("Ordinary large files still stand for exactly one path")
    func plainFilesHaveSingleComponent() {
        let file = LargeFile(
            path: URL(fileURLWithPath: "/Users/someone/Movies/clip.mov"),
            sizeBytes: 1024,
            lastUsed: Date(),
            category: .video
        )
        #expect(file.componentPaths == [URL(fileURLWithPath: "/Users/someone/Movies/clip.mov")])
        #expect(file.displayName == "clip.mov")
    }
}

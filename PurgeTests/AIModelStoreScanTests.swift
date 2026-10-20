import Foundation
import Testing
@testable import Purge

/// The model stores beyond Ollama and LM Studio (#157): the Hugging Face Hub
/// cache, an app's own Hugging Face folder, the folder stores, and the sweep
/// for weights in stores Purge does not know. Every home here is a throwaway
/// folder, never the real one.
@Suite("Downloaded AI models from every store are found as models")
struct AIModelStoreScanTests {
    /// Small enough that a test never writes a real 100 MB file. Sizes are
    /// allocated bytes, which APFS rounds up to 4 KB blocks, so a "big" file
    /// here is two blocks and a "small" one is a single block.
    private static let floor: Int64 = 8192

    private final class Home {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("purge-ai-stores-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 4096) throws -> URL {
            let target = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x5A, count: bytes).write(to: target)
            return target
        }

        func folder(_ relative: String) throws -> URL {
            let target = url.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            return target
        }

        func link(_ relative: String, to destination: String) throws {
            let target = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
        }
    }

    private func scan(_ home: Home, access: ScanAccess = .full, environment: [String: String] = [:]) -> [LargeFile] {
        AIModelScanner.allModels(home: home.url, environment: environment, access: access, looseWeightSizeFloor: Self.floor)
    }

    // MARK: - Hugging Face

    @Test("An app's Hugging Face cache names its models from index.json")
    func appCacheNamesModelsFromIndex() throws {
        let home = try Home()
        try home.file("Library/Caches/huggingface/models/whispercpp-large-v3-turbo/ggml-large-v3-turbo.bin", bytes: 8192)
        try home.file("Library/Caches/huggingface/models/unlisted-model/weights.bin", bytes: 4096)
        let index: [String: Any] = [
            "version": 1,
            "installedModels": [[
                "id": "whispercpp-large-v3-turbo",
                "definition": ["name": "Whisper Large V3 Turbo", "modelType": "whisperCpp"],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: index)
            .write(to: home.url.appendingPathComponent("Library/Caches/huggingface/models/index.json"))

        let models = scan(home).filter { $0.kind == .aiModel(.huggingFaceAppCache) }
        #expect(models.count == 2)
        let named = try #require(models.first { $0.displayName == "Whisper Large V3 Turbo" })
        #expect(named.sizeBytes == 8192)
        #expect(named.locationLabel == "Hugging Face")
        #expect(named.path.lastPathComponent == "whispercpp-large-v3-turbo")
        #expect(named.componentPaths == [named.path.standardizedFileURL])
        #expect(named.kind?.explanation.contains("may still show it as installed") == true)
        #expect(models.contains { $0.displayName == "unlisted-model" })
        // The index is the app's file, never a row and never a component.
        #expect(!models.contains { $0.path.lastPathComponent == "index.json" })
    }

    @Test("A Hub model counts each blob once, whatever its snapshots share")
    func hubCountsSharedBlobsOnce() throws {
        let home = try Home()
        let repo = "\u{2e}cache/huggingface/hub/models--mlx-community--gemma-4"
        try home.file("\(repo)/blobs/aaa", bytes: 4096)
        try home.file("\(repo)/blobs/bbb", bytes: 8192)
        try home.link("\(repo)/snapshots/111/model.safetensors", to: "../../blobs/aaa")
        try home.link("\(repo)/snapshots/222/model.safetensors", to: "../../blobs/aaa")
        try home.link("\(repo)/snapshots/222/config.json", to: "../../blobs/bbb")
        try home.file("\(repo)/refs/main", bytes: 3)
        try home.file(".cache/huggingface/hub/datasets--org--set/blobs/ccc", bytes: 4096)

        let models = AIModelScanner.huggingFaceHubModels(home: home.url, environment: [:])
        #expect(models.count == 1)
        let model = try #require(models.first)
        #expect(model.displayName == "mlx-community/gemma-4")
        #expect(model.locationLabel == "Hugging Face")
        // Two snapshots link to `aaa`; the blob is still one blob on disk. Three
        // blocks: `aaa`, two for `bbb`, and one for the 3-byte ref. Counting
        // `aaa` once per link would make it four.
        #expect(model.sizeBytes == 4096 * 4)
        #expect(model.componentPaths == [home.url.appendingPathComponent(repo).standardizedFileURL])
        #expect(model.kind == .aiModel(.huggingFaceHub))
    }

    @Test("HF_HUB_CACHE and HF_HOME move the Hub cache")
    func hubHonoursEnvironment() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(AIModelScanPolicy.huggingFaceHubRoot(home: home, environment: [:]).path
            == "/Users/someone/.cache/huggingface/hub")
        #expect(AIModelScanPolicy.huggingFaceHubRoot(home: home, environment: ["HF_HOME": "/Volumes/External/hf"]).path
            == "/Volumes/External/hf/hub")
        #expect(AIModelScanPolicy.huggingFaceHubRoot(
            home: home, environment: ["HF_HOME": "/Volumes/External/hf", "HF_HUB_CACHE": "/Volumes/Other/hub"]
        ).path == "/Volumes/Other/hub")
    }

    @Test("A swift-transformers model under Documents is one row, and a limited scan leaves it alone")
    func documentsStoreIsOneRowAndNeedsFullAccess() throws {
        let home = try Home()
        try home.file("Documents/huggingface/models/apple/OpenELM/model.safetensors", bytes: 4096)
        try home.file("Documents/huggingface/models/apple/OpenELM/config.json", bytes: 4096)

        let full = scan(home, access: .full).filter { $0.kind == .aiModel(.swiftTransformers) }
        #expect(full.count == 1)
        #expect(full.first?.displayName == "apple/OpenELM")
        #expect(full.first?.sizeBytes == 8192)
        #expect(full.first?.path.lastPathComponent == "OpenELM")

        #expect(scan(home, access: .limited).isEmpty)
    }

    @Test("The Large Files walk leaves the Documents model store to the model scan")
    func largeFileWalkSkipsDocumentsStore() async throws {
        let home = try Home()
        try home.file("Documents/huggingface/models/apple/OpenELM/model.safetensors", bytes: 4096)
        let loose = try home.file("Documents/Downloads from a browser/llama.gguf", bytes: 4096)

        var seen: [LargeFile] = []
        let scanner = LargeFileScanner()
        for await file in scanner.scanStream(
            minBytes: 1, staleDays: 0,
            roots: [home.url.appendingPathComponent("Documents")],
            installedApps: [], isAppRunning: { _ in false },
            home: home.url, exclusions: ScanExclusions(keys: []), isExcluded: { _ in false }
        ) {
            seen.append(file)
        }
        #expect(seen.map(\.id) == [loose.standardizedFileURL.path])
        #expect(seen.first?.category == .aiModel)
    }

    // MARK: - Folder stores

    @Test("GPT4All lists its weight files and nothing else in the folder")
    func gpt4AllListsWeightsOnly() throws {
        let home = try Home()
        let root = "Library/Application Support/nomic.ai/GPT4All"
        try home.file("\(root)/Llama-3.2-1B-Instruct-Q4_0.gguf", bytes: 4096)
        try home.file("\(root)/gpt4all-remote.rmodel", bytes: 200)
        try home.file("\(root)/localdocs_v3.db", bytes: 4096)

        let models = scan(home).filter { $0.kind == .aiModel(.gpt4All) }
        #expect(models.map(\.displayName) == ["Llama-3.2-1B-Instruct-Q4_0.gguf"])
        #expect(models.first?.locationLabel == "GPT4All")
    }

    @Test("Jan models are the folders that hold weights, named without the Hub host")
    func janModelsAreFolders() throws {
        let home = try Home()
        let root = "Library/Application Support/Jan/data/models"
        try home.file("\(root)/huggingface.co/bartowski/gemma-4-GGUF/gemma-4.gguf", bytes: 4096)
        try home.file("\(root)/huggingface.co/bartowski/gemma-4-GGUF/model.json", bytes: 50)
        try home.file("jan/models/tinyllama/model.gguf", bytes: 4096)

        let models = scan(home).filter { $0.kind == .aiModel(.jan) }
        #expect(Set(models.map(\.displayName)) == ["bartowski/gemma-4-GGUF", "tinyllama"])
        for model in models {
            #expect(model.componentPaths == [model.path.standardizedFileURL])
        }
    }

    @Test("Every store root is a folder of models, so each lists through the same walk")
    func everyFolderStoreLists() throws {
        let home = try Home()
        for store in AIModelScanPolicy.Store.folderStores {
            for root in AIModelScanPolicy.roots(for: store, home: home.url, environment: [:]) {
                let relative = root.path.dropFirst(home.url.standardizedFileURL.path.count + 1)
                try home.file("\(relative)/model.safetensors", bytes: 4096)
            }
        }
        let models = scan(home)
        for store in AIModelScanPolicy.Store.folderStores {
            let rows = models.filter { $0.kind == .aiModel(store) }
            #expect(rows.count == AIModelScanPolicy.roots(for: store, home: home.url, environment: [:]).count, "\(store)")
            #expect(rows.allSatisfy { $0.locationLabel == store.displayName }, "\(store)")
        }
        // Nothing in a known store is listed twice by the sweep.
        #expect(models.filter { $0.kind == .aiModel(.looseWeights) }.isEmpty)
    }

    @Test("A limited scan stays out of the stores in app containers")
    func limitedScanSkipsContainers() throws {
        let home = try Home()
        try home.file("Library/Containers/com.liuliu.draw-things/Data/Documents/Models/sd_v1.5_f16.ckpt", bytes: 4096)
        #expect(scan(home, access: .full).count == 1)
        #expect(scan(home, access: .limited).isEmpty)
    }

    // MARK: - Loose weights

    @Test("An unknown weight file over the floor is listed by its folder; a small one is not")
    func looseWeightsRespectTheFloor() throws {
        let home = try Home()
        let big = try home.file("Library/Application Support/VoiceInk/WhisperModels/ggml-large-v3.bin", bytes: 8192)
        try home.file("Library/Application Support/VoiceInk/WhisperModels/ggml-tiny.bin", bytes: 100)
        try home.file("Library/Application Support/SomeApp/data.bin", bytes: 8192)
        try home.file("Library/Application Support/com.apple.Something/model.gguf", bytes: 8192)
        try home.file(".cache/some-tool/checkpoints/vision.onnx", bytes: 8192)
        try home.file("Library/Caches/Some.app/Contents/model.gguf", bytes: 8192)
        try home.file("Library/Caches/tool/a/b/c/d/e/f/deep.gguf", bytes: 8192)

        let models = scan(home).filter { $0.kind == .aiModel(.looseWeights) }
        #expect(Set(models.map(\.displayName)) == ["ggml-large-v3.bin", "vision.onnx"])

        let row = try #require(models.first { $0.id == big.standardizedFileURL.path })
        #expect(row.sourceLabel == nil)
        #expect(row.locationLabel.hasSuffix("VoiceInk/WhisperModels"))
        #expect(row.category == .aiModel)
        #expect(row.kind?.explanation.contains("may still list the model as installed") == true)
    }

    @Test("A Core ML model folder is one row, sized whole")
    func coreMLBundleIsOneRow() throws {
        let home = try Home()
        try home.file("Library/Application Support/Dictation/large.mlmodelc/weights/weight.bin", bytes: 4096)
        try home.file("Library/Application Support/Dictation/large.mlmodelc/model.mil", bytes: 4096)

        let models = scan(home).filter { $0.kind == .aiModel(.looseWeights) }
        #expect(models.count == 1)
        #expect(models.first?.displayName == "large.mlmodelc")
        #expect(models.first?.sizeBytes == 8192)
    }

    @Test("A limited sweep stays out of the media caches")
    func limitedSweepSkipsMediaCaches() throws {
        let home = try Home()
        try home.file("Library/Caches/com.apple.Music/model.gguf", bytes: 8192)
        try home.file("Library/Caches/other-app/model.gguf", bytes: 8192)
        // Apple's folders are skipped with either access; the point is that a
        // limited sweep never opens one, and a full sweep lists the other.
        #expect(scan(home, access: .limited).map(\.displayName) == ["model.gguf"])
        #expect(scan(home, access: .full).count == 1)
    }

    // MARK: - Deletion gate

    @Test("Every listed row passes the gate, and no store root does")
    func gateAdmitsRowsAndRefusesRoots() throws {
        let home = try Home()
        try home.file("Library/Caches/huggingface/models/m/weights.bin", bytes: 4096)
        try home.file(".cache/huggingface/hub/models--o--n/blobs/aaa", bytes: 4096)
        try home.file("Documents/huggingface/models/o/n/model.safetensors", bytes: 4096)
        try home.file(".cache/whisper/base.pt", bytes: 4096)
        try home.file("Library/Application Support/SomeApp/big.gguf", bytes: 8192)

        let models = scan(home)
        #expect(models.count == 5)
        for model in models {
            for component in model.componentPaths {
                #expect(AIModelScanPolicy.isEligibleForDeletion(
                    component, home: home.url, environment: [:], looseWeightSizeFloor: Self.floor
                ), "\(component.path)")
            }
        }

        for root in AIModelScanPolicy.allRoots(home: home.url, environment: [:])
            + AIModelScanPolicy.looseWeightRoots(home: home.url) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            #expect(!AIModelScanPolicy.isEligibleForDeletion(
                root, home: home.url, environment: [:], looseWeightSizeFloor: Self.floor
            ), "\(root.path)")
        }
        // The folder above an app's model store is a cache folder, not a model.
        #expect(!AIModelScanPolicy.isEligibleForDeletion(
            home.url.appendingPathComponent("Library/Caches/huggingface"), home: home.url, environment: [:]
        ))
    }

    @Test("Inside a store, only what a row stands for passes the gate")
    func gateRefusesStoreFilesThatAreNotModels() throws {
        let home = try Home()
        let gpt4AllDB = try home.file("Library/Application Support/nomic.ai/GPT4All/localdocs_v3.db", bytes: 8192)
        let gpt4AllModel = try home.file("Library/Application Support/nomic.ai/GPT4All/llama.gguf", bytes: 8192)
        let hubBlob = try home.file(".cache/huggingface/hub/models--o--n/blobs/aaa", bytes: 8192)
        let hubVersion = try home.file(".cache/huggingface/hub/version.txt", bytes: 8)
        let hubRepo = home.url.appendingPathComponent(".cache/huggingface/hub/models--o--n")
        let janNamespace = try home.folder("Library/Application Support/Jan/data/models/huggingface.co")
        let janModel = try home.file("Library/Application Support/Jan/data/models/huggingface.co/o/r/model.gguf", bytes: 8192)
        let ollamaBlobs = home.url.appendingPathComponent(".ollama/models/blobs")
        try home.file(".ollama/models/blobs/sha256-aaa", bytes: 8192)

        func eligible(_ url: URL) -> Bool {
            AIModelScanPolicy.isEligibleForDeletion(url, home: home.url, environment: [:], looseWeightSizeFloor: Self.floor)
        }
        #expect(eligible(gpt4AllModel))
        #expect(!eligible(gpt4AllDB))
        #expect(eligible(hubRepo))
        #expect(!eligible(hubBlob))
        #expect(!eligible(hubVersion))
        #expect(eligible(janModel.deletingLastPathComponent()))
        #expect(!eligible(janNamespace))
        #expect(!eligible(ollamaBlobs))
        #expect(eligible(ollamaBlobs.appendingPathComponent("sha256-aaa")))
    }

    @Test("Under the sweep roots, only weight files over the floor pass the gate")
    func gateRefusesWhatTheSweepWouldNotList() throws {
        let home = try Home()
        let notes = try home.file("Library/Application Support/SomeApp/notes.txt", bytes: 4096)
        let small = try home.file("Library/Application Support/SomeApp/small.gguf", bytes: 100)
        let apple = try home.file("Library/Application Support/com.apple.Something/model.gguf", bytes: 8192)
        let plainBin = try home.file("Library/Application Support/SomeApp/data.bin", bytes: 8192)
        let deep = try home.file("Library/Caches/tool/a/b/c/d/e/f/deep.gguf", bytes: 8192)
        let big = try home.file("Library/Application Support/SomeApp/big.gguf", bytes: 8192)

        func eligible(_ url: URL) -> Bool {
            AIModelScanPolicy.isEligibleForDeletion(url, home: home.url, environment: [:], looseWeightSizeFloor: Self.floor)
        }
        #expect(eligible(big))
        #expect(!eligible(notes))
        #expect(!eligible(small))
        #expect(!eligible(apple))
        #expect(!eligible(plainBin))
        #expect(!eligible(deep))
    }

    @Test("The real floor is 100 MB, so an app's bundled assets never qualify")
    func realFloorIsOneHundredMegabytes() {
        #expect(AIModelScanPolicy.looseWeightSizeFloorBytes == 100 * 1024 * 1024)
    }

    @Test("The cache route refuses an app's Hugging Face folder, so a model is never in two tabs")
    func huggingFaceCacheIsNotACache() {
        // `evaluate` allows every folder under ~/Library/Caches unless a rule
        // refuses it, and the App Caches scan lists what `evaluate` allows. So
        // this is the fact that keeps the folder out of App Caches and out of
        // Clean Safe Items: the folder and everything in it are never-delete there.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent("Library/Caches/huggingface", isDirectory: true)
        #expect(DeletionSafetyPolicy.evaluate(folder) == .blockedNeverDelete)
        #expect(DeletionSafetyPolicy.evaluate(folder.appendingPathComponent("models")) == .blockedNeverDelete)
        #expect(DeletionSafetyPolicy.evaluate(
            folder.appendingPathComponent("models/whispercpp-large-v3-turbo/ggml-large-v3-turbo.bin")
        ) == .blockedNeverDelete)
        #expect(!DeletionSafetyPolicy.isOfferedForCleanup(folder))
        // A neighbour is unaffected.
        #expect(DeletionSafetyPolicy.evaluate(home.appendingPathComponent("Library/Caches/huggingface-other")) == .allow)
    }

    @Test("Weight files downloaded by hand count as AI models")
    func weightExtensionsAreAIModels() {
        for ext in ["gguf", "safetensors", "onnx", "pt", "pth", "ckpt", "mlmodelc", "mlpackage"] {
            #expect(LargeFileCategory.category(forExtension: ext) == .aiModel, "\(ext)")
        }
        #expect(LargeFileCategory.category(forExtension: "bin") == .other)
    }

    @Test("Ollama and LM Studio rows carry their store, so the confirm sheet can explain them")
    func existingStoresCarryTheirKind() throws {
        let home = try Home()
        try home.file(".lmstudio/models/lmstudio-community/gemma-4-GGUF/gemma-4.gguf", bytes: 4096)
        let models = scan(home)
        #expect(models.count == 1)
        #expect(models.first?.kind == .aiModel(.lmStudio))
        #expect(models.first?.displayName == "lmstudio-community/gemma-4-GGUF")
        #expect(models.first?.locationLabel == "LM Studio")
        #expect(models.first?.kind?.badgeText == "AI model")
    }
}

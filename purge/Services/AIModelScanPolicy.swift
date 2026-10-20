import Foundation

/// Bounds for locally downloaded AI models.
///
/// These live in hidden directories and app folders outside the Large Files
/// scan roots, so they need their own roots and their own deletion gate. Kept
/// separate from `LargeFileScanPolicy` because a model row stands for several
/// files at once — an Ollama model is a manifest plus the blobs it owns, a
/// Hugging Face model is a folder of blobs plus the snapshots that link into
/// them — and the eligibility rule has to admit those by their content-addressed
/// names.
///
/// Every row here is Check First by construction: Large Files rows are picked
/// one by one and never feed Clean Safe Items or a scheduled clean.
nonisolated enum AIModelScanPolicy {
    /// Where a model came from. The app or library that downloaded it, which is
    /// what the row shows as its location, and what decides how its folder is
    /// cut into models.
    nonisolated enum Store: String, CaseIterable, Hashable, Sendable {
        case ollama
        case lmStudio
        /// `huggingface_hub`, transformers, MLX and everything else that uses the
        /// Python Hub cache.
        case huggingFaceHub
        /// swift-transformers' `HubApi`, which downloads under Documents.
        case swiftTransformers
        /// An app's own model folder under `~/Library/Caches/huggingface`, with
        /// an `index.json` naming what it installed (#157).
        case huggingFaceAppCache
        case pyTorchHub
        case whisper
        case gpt4All
        case jan
        case diffusionBee
        case drawThings
        /// Weight files found outside any store above, in the places Large
        /// Files does not walk. Shown by the folder they sit in.
        case looseWeights

        /// Product names, not translated. Empty for loose weights, whose rows
        /// show the folder they sit in instead.
        nonisolated var displayName: String {
            switch self {
            case .ollama: return "Ollama"
            case .lmStudio: return "LM Studio"
            case .huggingFaceHub: return "Hugging Face"
            case .swiftTransformers: return "Hugging Face"
            case .huggingFaceAppCache: return "Hugging Face"
            case .pyTorchHub: return "PyTorch Hub"
            case .whisper: return "Whisper"
            case .gpt4All: return "GPT4All"
            case .jan: return "Jan"
            case .diffusionBee: return "DiffusionBee"
            case .drawThings: return "Draw Things"
            case .looseWeights: return ""
            }
        }

        /// What happens to the app's own list of models when a row is trashed.
        /// Shown on the row and in the confirm sheet, so the user knows when an
        /// app may still claim a model that is gone.
        nonisolated var explanation: String {
            switch self {
            case .ollama:
                return String(localized: "Model downloaded with Ollama. Its manifest goes with its weights, so Ollama stops listing it. Pull it again to get it back.")
            case .lmStudio:
                return String(localized: "Model downloaded with LM Studio. The whole model folder goes, and LM Studio stops listing it. Download it again in LM Studio.")
            case .huggingFaceHub:
                return String(localized: "Model downloaded through the Hugging Face Hub. Every cached version goes with it, and the next use downloads it again.")
            case .swiftTransformers:
                return String(localized: "Model an app downloaded through the Hugging Face Hub. The next use downloads it again.")
            case .huggingFaceAppCache:
                return String(localized: "Model an app downloaded into its Hugging Face cache. Purge can't change the app's own list of installed models, so the app may still show it as installed until it checks.")
            case .pyTorchHub:
                return String(localized: "Model downloaded by PyTorch Hub. The next use downloads it again.")
            case .whisper:
                return String(localized: "Model downloaded by OpenAI Whisper. The next use downloads it again.")
            case .gpt4All:
                return String(localized: "Model downloaded with GPT4All. Download it again in GPT4All.")
            case .jan:
                return String(localized: "Model downloaded with Jan. Jan may still list it until it checks its models folder. Download it again in Jan.")
            case .diffusionBee:
                return String(localized: "Model downloaded with DiffusionBee. Download it again in DiffusionBee.")
            case .drawThings:
                return String(localized: "Model in Draw Things' models folder. It may be one you imported or trained, which can't be downloaded again. Draw Things may still list it until it checks its models folder.")
            case .looseWeights:
                return String(localized: "Model weights outside any model store Purge knows. The folder they sit in names the app that downloaded them, and that app may still list the model as installed.")
            }
        }

        /// Stores whose rows the generic folder walk cuts. Ollama has its own
        /// manifest parser, the Hub its own layout, and the loose sweep its own
        /// rules, so they are left out here.
        nonisolated static var folderStores: [Store] {
            [.lmStudio, .swiftTransformers, .huggingFaceAppCache, .pyTorchHub, .whisper, .gpt4All, .jan, .diffusionBee, .drawThings]
        }
    }

    // MARK: - Roots

    /// Ollama honours `OLLAMA_MODELS` for users who move the store to an
    /// external drive, so the default path is a fallback rather than a given.
    nonisolated static func ollamaRoot(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["OLLAMA_MODELS"], !override.isEmpty {
            return expanded(override)
        }
        return home.appendingPathComponent(".ollama/models", isDirectory: true).standardizedFileURL
    }

    /// Current LM Studio location first, then the pre-0.3 cache location. Both
    /// are checked because an upgrade leaves the old directory behind.
    nonisolated static func lmStudioRoots(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".lmstudio/models", isDirectory: true),
            home.appendingPathComponent(".cache/lm-studio/models", isDirectory: true)
        ].map(\.standardizedFileURL)
    }

    /// The Python Hub cache. `HF_HUB_CACHE` names the hub folder itself,
    /// `HF_HOME` the folder it sits in; `huggingface_hub` reads them in that
    /// order and so does this.
    nonisolated static func huggingFaceHubRoot(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["HF_HUB_CACHE"], !override.isEmpty {
            return expanded(override)
        }
        if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
            return expanded(hfHome).appendingPathComponent("hub", isDirectory: true)
        }
        return home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true).standardizedFileURL
    }

    nonisolated static func roots(
        for store: Store,
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        func under(_ relative: String) -> URL {
            home.appendingPathComponent(relative, isDirectory: true).standardizedFileURL
        }
        switch store {
        case .ollama:
            return [ollamaRoot(home: home, environment: environment)]
        case .lmStudio:
            return lmStudioRoots(home: home)
        case .huggingFaceHub:
            return [huggingFaceHubRoot(home: home, environment: environment)]
        case .swiftTransformers:
            return [under("Documents/huggingface/models")]
        case .huggingFaceAppCache:
            return [under("Library/Caches/huggingface/models")]
        case .pyTorchHub:
            return [under(".cache/torch/hub/checkpoints")]
        case .whisper:
            return [under(".cache/whisper")]
        case .gpt4All:
            return [under("Library/Application Support/nomic.ai/GPT4All")]
        case .jan:
            // Current location first, then the pre-0.5 one an upgrade leaves behind.
            return [under("Library/Application Support/Jan/data/models"), under("jan/models")]
        case .diffusionBee:
            // Only the downloads. `~/.diffusionbee/custom_models` holds the
            // models the user imported, which can't be downloaded again, and
            // `~/.diffusionbee/images` the pictures the user made.
            return [under(".diffusionbee/downloads")]
        case .drawThings:
            return [under("Library/Containers/com.liuliu.draw-things/Data/Documents/Models")]
        case .looseWeights:
            return looseWeightRoots(home: home)
        }
    }

    /// Every store root except the loose sweep's. These are the folders whose
    /// contents are models and nothing else.
    nonisolated static func allRoots(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        Store.allCases
            .filter { $0 != .looseWeights }
            .flatMap { roots(for: $0, home: home, environment: environment) }
    }

    /// Store roots that sit inside a folder the Large Files walk covers. The
    /// walk skips them, so a model there is one row and not a file per weight.
    nonisolated static func rootsInsideLargeFileScan(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let scanRoots = LargeFileScanPolicy.scanRoots(home: home).map { $0.standardizedFileURL.path + "/" }
        return allRoots(home: home, environment: environment).filter { root in
            scanRoots.contains { root.path.hasPrefix($0) }
        }
    }

    /// Whether `path` is `~/Library/Caches/huggingface` or inside it. The
    /// cache route (`DeletionSafetyPolicy.evaluate`) refuses these: the folder
    /// holds downloaded models that Large Files lists, never a cache.
    nonisolated static func isAppModelCachePath(_ path: String, home: String) -> Bool {
        let folder = "\(home)/Library/Caches/huggingface"
        return path == folder || path.hasPrefix(folder + "/")
    }

    // MARK: - Loose weights

    /// Where the sweep for unknown stores looks: the places Large Files never
    /// walks, where apps keep what they download. Documents and the other home
    /// folders are not here because the Large Files walk already covers them.
    nonisolated static func looseWeightRoots(home: URL) -> [URL] {
        [
            home.appendingPathComponent("Library/Caches", isDirectory: true),
            home.appendingPathComponent("Library/Application Support", isDirectory: true),
            home.appendingPathComponent(".cache", isDirectory: true)
        ].map(\.standardizedFileURL)
    }

    /// Below this, a weight file in an app folder is an asset the app ships
    /// with, not a model the user downloaded. Independent of the Large Files
    /// size filter, which can go down to 5 MB.
    nonisolated static let looseWeightSizeFloorBytes: Int64 = 100 * 1024 * 1024

    /// How deep the sweep goes under each root. Model folders sit a few levels
    /// down at most; a browser cache goes much deeper and holds nothing of
    /// interest.
    nonisolated static let looseWeightMaxDepth = 6

    /// Extensions of model weight files. `.bin` is not here on its own, because
    /// every kind of app writes `.bin`; see `isWeightFile`.
    nonisolated static let weightFileExtensions: Set<String> = [
        "gguf", "safetensors", "onnx", "pt", "pth", "ckpt", "tdict"
    ]

    /// Core ML models are folders. Each is one unit, sized and trashed whole.
    nonisolated static let weightBundleExtensions: Set<String> = ["mlmodelc", "mlpackage"]

    /// Whether a file name is model weights. Inside a known store any `.bin`
    /// counts, since the store holds nothing else. In the sweep a `.bin` must
    /// say `ggml` in its name, the way whisper.cpp and llama.cpp name theirs.
    nonisolated static func isWeightFile(named name: String, insideKnownStore: Bool) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if weightFileExtensions.contains(ext) { return true }
        if ext == "bin" {
            return insideKnownStore || name.lowercased().contains("ggml")
        }
        return false
    }

    nonisolated static func isWeightBundle(named name: String) -> Bool {
        weightBundleExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Draw Things keeps most of a model's bytes in `<name>.ckpt-tensordata`
    /// beside `<name>.ckpt`. The pair is one model: listed, sized and trashed
    /// together, so trashing the row never leaves the big half behind.
    nonisolated static let weightCompanionSuffix = "-tensordata"

    nonisolated static func companion(ofWeightFile url: URL) -> URL? {
        guard url.pathExtension.lowercased() == "ckpt" else { return nil }
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + weightCompanionSuffix, isDirectory: false)
    }

    nonisolated static func isWeightCompanion(named name: String) -> Bool {
        name.lowercased().hasSuffix(".ckpt" + weightCompanionSuffix)
    }

    /// Whether a store or sweep root can be read and trusted: it is a folder,
    /// and no part of its path is a link. A root that links elsewhere, such as
    /// `~/jan/models` to `~/Projects`, would make every folder behind it with a
    /// weight file in it look like a model.
    nonisolated static func isUsableRoot(_ root: URL) -> Bool {
        let path = root.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return false }
        return !hasLinkInPath(root)
    }

    /// `resolvingSymlinksInPath` drops a leading `/private` it added, so a
    /// path under `/var` or `/tmp` with no link of its own compares equal.
    nonisolated static func hasLinkInPath(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path != url.standardizedFileURL.path
    }

    /// Folders the sweep never enters. Apple's own folders hold system data,
    /// never a downloaded model, and dependency folders belong to a project.
    nonisolated static func sweepSkipsDirectory(named name: String) -> Bool {
        if name.hasPrefix("com.apple.") { return true }
        if name.hasPrefix(".") { return true }
        if name == "node_modules" { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "app" || ext == "bundle" || ext == "framework"
    }

    // MARK: - Deletion gate

    /// A path may be removed only if it is something a row stands for: an
    /// Ollama manifest or blob, a Hub model folder, a weight file or a folder
    /// of weights inside a store, or a loose weight file the sweep would list.
    /// The roots themselves are never deletable — emptying `~/.ollama/models`
    /// wholesale is not something a row should ever mean — and neither is
    /// anything else that happens to sit in a store, such as GPT4All's
    /// local-documents database beside its models.
    nonisolated static func isEligibleForDeletion(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        looseWeightSizeFloor: Int64 = looseWeightSizeFloorBytes
    ) -> Bool {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }

        // No part of the path may be a link. The rules below match paths as
        // text, so a store root that links to `~/Projects`, or a link in a
        // sweep root that leads to another drive, would otherwise let the
        // real folder behind it pass as a model.
        guard !hasLinkInPath(standardized) else { return false }

        func isInside(_ root: URL) -> Bool { path.hasPrefix(root.path + "/") }

        // Ollama: a manifest, or a blob the manifest names. Both are plain
        // files the scanner picked out of the store.
        if isInside(ollamaRoot(home: home, environment: environment)) {
            return !isDirectory.boolValue
        }

        // The Hub: one `models--<org>--<name>` folder straight under the root.
        let hub = huggingFaceHubRoot(home: home, environment: environment)
        if isInside(hub) {
            return isDirectory.boolValue
                && standardized.deletingLastPathComponent().path == hub.path
                && standardized.lastPathComponent.hasPrefix("models--")
        }

        for store in Store.folderStores {
            for root in roots(for: store, home: home, environment: environment) where isInside(root) {
                return isStoreModel(standardized, isDirectory: isDirectory.boolValue)
            }
        }
        return isEligibleLooseWeight(standardized, home: home, sizeFloor: looseWeightSizeFloor)
    }

    /// What `AIModelScanner.folderModels` lists: a weight file and its
    /// companion, a Core ML bundle, or a folder that holds weight files directly.
    nonisolated static func isStoreModel(_ url: URL, isDirectory: Bool) -> Bool {
        let name = url.lastPathComponent
        guard isDirectory else {
            return isWeightFile(named: name, insideKnownStore: true) || isWeightCompanion(named: name)
        }
        if isWeightBundle(named: name) { return true }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        return children.contains { child in
            (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                && isWeightFile(named: child.lastPathComponent, insideKnownStore: true)
        }
    }

    /// The sweep's gate, applied again at delete time: strictly inside a sweep
    /// root, never in a folder the sweep skips, a weight file or Core ML
    /// bundle, and over the size floor. A row that passed the scan passes this;
    /// a path that never could be a row does not.
    nonisolated static func isEligibleLooseWeight(
        _ url: URL,
        home: URL,
        sizeFloor: Int64 = looseWeightSizeFloorBytes
    ) -> Bool {
        let path = url.path
        guard let root = looseWeightRoots(home: home).first(where: { path.hasPrefix($0.path + "/") })
        else { return false }

        let relative = path.dropFirst(root.path.count + 1).split(separator: "/")
        guard relative.count <= looseWeightMaxDepth else { return false }
        if relative.dropLast().contains(where: { sweepSkipsDirectory(named: String($0)) }) { return false }

        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }

        let bytes: Int64
        if isDirectory.boolValue {
            guard isWeightBundle(named: name) else { return false }
            bytes = FolderSizing.walkedSize(at: url, skipsPackages: false).bytes
        } else {
            guard isWeightFile(named: name, insideKnownStore: false) else { return false }
            bytes = FolderSizing.singleFileSize(at: url)
        }
        return bytes >= sizeFloor
    }

    private nonisolated static func expanded(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }
}

import Foundation

/// Discovers locally downloaded AI models and reports them as whole models
/// rather than as files on disk.
///
/// Ollama stores content-addressed blobs (`blobs/sha256-4c27e0…`), so listing
/// the raw files would show the user a meaningless hex name and let them break
/// a model without Ollama noticing — the manifest would still claim the model
/// is installed. Blobs are also shared between models, so the reclaimable size
/// of a model is only the blobs no other manifest references.
///
/// The other stores (#157) are folders an app or library fills with models:
/// the Hugging Face Hub cache, swift-transformers' Documents folder, an app's
/// own `~/Library/Caches/huggingface/models`, and the folders of GPT4All, Jan,
/// DiffusionBee, Draw Things, PyTorch Hub and Whisper. Each model there is the
/// first folder that holds weight files directly, or a loose weight file. A
/// last sweep over `~/Library/Caches`, `~/Library/Application Support` and
/// `~/.cache` finds weights in stores Purge does not know, shown by the folder
/// they sit in.
///
/// `nonisolated` for the same reason as `LargeFileScanner` — see the note there.
/// Without it the `Task.detached` in `scanStream` hops back to the main actor and
/// this runs its manifest walk on the UI thread.
nonisolated final class AIModelScanner {
    /// Which part of the scan a stream runs. The known stores read a few
    /// manifests and folders and finish almost at once. The loose sweep walks
    /// three large Library trees, so it runs beside the Large Files walk
    /// rather than ahead of it.
    enum Pass: Sendable {
        case knownStores
        case looseWeights
    }

    /// `access` decides whether roots under protected folders (Documents, app
    /// containers) and the media caches are read. A limited scan stays out of
    /// them, the same as every other scan.
    ///
    /// The scan starts when the stream is made, not when it is first read, and
    /// stops when the stream is dropped.
    func scanStream(minBytes: Int64, staleDays: Int, access: ScanAccess = .full, pass: Pass) -> AsyncStream<LargeFile> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await Self.run(minBytes: minBytes, staleDays: staleDays, access: access, pass: pass, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        minBytes: Int64,
        staleDays: Int,
        access: ScanAccess,
        pass: Pass,
        continuation: AsyncStream<LargeFile>.Continuation
    ) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let now = Date()
        let discovered: [LargeFile]
        switch pass {
        case .knownStores:
            discovered = knownStoreModels(home: home, access: access)
        case .looseWeights:
            discovered = looseWeights(home: home, access: access)
        }

        for model in discovered {
            if Task.isCancelled { break }
            guard model.sizeBytes >= minBytes else { continue }
            if staleDays > 0 {
                let days = Calendar.current.dateComponents([.day], from: model.lastUsed, to: now).day ?? 0
                guard days >= staleDays else { continue }
            }
            continuation.yield(model)
        }

        continuation.finish()
    }

    /// Every model in every store, known stores first so the sweep can leave
    /// their roots alone.
    static func allModels(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        access: ScanAccess,
        looseWeightSizeFloor: Int64 = AIModelScanPolicy.looseWeightSizeFloorBytes
    ) -> [LargeFile] {
        knownStoreModels(home: home, environment: environment, access: access)
            + looseWeights(home: home, environment: environment, access: access, sizeFloor: looseWeightSizeFloor)
    }

    /// Every model in the stores Purge knows: Ollama, the Hub and the folder
    /// stores. The loose sweep is left out; it is the slow part.
    static func knownStoreModels(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        access: ScanAccess
    ) -> [LargeFile] {
        var models = ollamaModels(home: home, environment: environment, access: access)
        models += huggingFaceHubModels(home: home, environment: environment, access: access)
        for store in AIModelScanPolicy.Store.folderStores {
            if Task.isCancelled { return models }
            models += folderModels(store: store, home: home, environment: environment, access: access)
        }
        return models
    }

    /// Whether a store root may be read with this access. A root under
    /// Documents or inside an app container prompts without Full Disk Access.
    private static func canRead(_ root: URL, home: URL, access: ScanAccess) -> Bool {
        guard ProtectedLocations.isReadable(root, access: access, home: home) else { return false }
        return FileManager.default.fileExists(atPath: root.path)
    }

    // MARK: - Ollama

    private struct OllamaManifest: Decodable {
        struct Layer: Decodable {
            let digest: String
        }
        let config: Layer?
        let layers: [Layer]

        /// Every blob the model needs, config included — the config blob is as
        /// much a part of the model as the weights are.
        var digests: [String] {
            layers.map(\.digest) + (config.map { [$0.digest] } ?? [])
        }
    }

    static func ollamaModels(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        access: ScanAccess = .full
    ) -> [LargeFile] {
        let fm = FileManager.default
        let root = AIModelScanPolicy.ollamaRoot(home: home, environment: environment)
        let manifestRoot = root.appendingPathComponent("manifests", isDirectory: true)
        let blobRoot = root.appendingPathComponent("blobs", isDirectory: true)
        guard canRead(root, home: home, access: access), fm.fileExists(atPath: manifestRoot.path) else { return [] }

        // Parse every manifest first: a blob is only reclaimable if exactly one
        // model references it, and that is not knowable one model at a time.
        var parsed: [(url: URL, digests: [String])] = []
        var referenceCounts: [String: Int] = [:]

        guard let enumerator = fm.enumerator(
            at: manifestRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        while let next = enumerator.nextObject() {
            if Task.isCancelled { return [] }
            guard let url = next as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  url.lastPathComponent != ".DS_Store",
                  let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(OllamaManifest.self, from: data)
            else { continue }

            let digests = Array(Set(manifest.digests))
            parsed.append((url, digests))
            for digest in digests {
                referenceCounts[digest, default: 0] += 1
            }
        }

        return parsed.compactMap { manifest in
            var reclaimableBytes: Int64 = 0
            var lastUsed = Date.distantPast
            // The manifest itself is tiny but must go, or Ollama keeps listing a
            // model whose weights are gone.
            var components: [URL] = [manifest.url]

            for digest in manifest.digests {
                let blob = blobRoot.appendingPathComponent(digest.replacingOccurrences(of: ":", with: "-"))
                guard let values = try? blob.resourceValues(forKeys: [
                    .totalFileAllocatedSizeKey, .fileSizeKey,
                    .contentAccessDateKey, .contentModificationDateKey
                ]) else { continue }

                let touched = max(
                    values.contentAccessDate ?? .distantPast,
                    values.contentModificationDate ?? .distantPast
                )
                lastUsed = max(lastUsed, touched)

                guard referenceCounts[digest] == 1 else { continue }
                reclaimableBytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                components.append(blob)
            }

            guard reclaimableBytes > 0 else { return nil }
            return LargeFile(
                path: manifest.url,
                sizeBytes: reclaimableBytes,
                lastUsed: lastUsed == .distantPast ? Date.distantPast : lastUsed,
                category: .aiModel,
                displayNameOverride: ollamaModelName(manifestURL: manifest.url, manifestRoot: manifestRoot),
                sourceLabel: AIModelScanPolicy.Store.ollama.displayName,
                componentPaths: components,
                kind: .aiModel(.ollama)
            )
        }
    }

    /// `manifests/registry.ollama.ai/library/gemma4/latest` reads back as
    /// `gemma4:latest` — the name the user typed to pull it.
    private static func ollamaModelName(manifestURL: URL, manifestRoot: URL) -> String {
        let parts = manifestURL.standardizedFileURL.pathComponents
            .dropFirst(manifestRoot.standardizedFileURL.pathComponents.count)
        guard parts.count >= 2 else { return manifestURL.lastPathComponent }

        let tag = parts.last!
        // Drop the registry host, and the default `library` namespace, so only
        // the parts a user would actually type survive.
        var name = Array(parts.dropLast().dropFirst())
        if name.first == "library" { name.removeFirst() }
        guard !name.isEmpty else { return "\(parts[parts.startIndex + 1]):\(tag)" }
        return "\(name.joined(separator: "/")):\(tag)"
    }

    // MARK: - Hugging Face Hub

    /// The Hub cache lays a model out as `models--<org>--<name>/` holding
    /// `blobs/` (the files, named by hash), `snapshots/<commit>/` (symlinks into
    /// `blobs/`) and `refs/`. Two snapshots of one model share the blobs that
    /// did not change between them, so the model folder is the unit: sizing it
    /// counts each blob once, because the snapshot links are not regular files,
    /// and trashing it never takes a blob another snapshot of the same model
    /// still needs. Datasets and spaces in the same cache are not models and
    /// are left alone.
    static func huggingFaceHubModels(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        access: ScanAccess = .full
    ) -> [LargeFile] {
        let root = AIModelScanPolicy.huggingFaceHubRoot(home: home, environment: environment)
        guard canRead(root, home: home, access: access) else { return [] }

        return directories(in: root).compactMap { repo in
            if Task.isCancelled { return nil }
            let folder = repo.lastPathComponent
            guard folder.hasPrefix("models--") else { return nil }
            let measured = FolderSizing.walkedSize(at: repo, skipsPackages: false)
            guard measured.bytes > 0 else { return nil }

            let name = folder.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            return LargeFile(
                path: repo,
                sizeBytes: measured.bytes,
                lastUsed: measured.lastUsed,
                category: .aiModel,
                displayNameOverride: name,
                sourceLabel: AIModelScanPolicy.Store.huggingFaceHub.displayName,
                componentPaths: [repo],
                kind: .aiModel(.huggingFaceHub)
            )
        }
    }

    // MARK: - Folder stores

    /// Models in a store that is a plain folder of them. A model is the first
    /// folder on the way down that holds weight files directly — LM Studio's
    /// `<publisher>/<repo>/`, Jan's `<name>/`, swift-transformers'
    /// `<org>/<name>/` — or a loose weight file, as GPT4All and Whisper keep
    /// them. A folder that holds only other folders is a namespace, not a
    /// model, and the walk goes on into it.
    ///
    /// An app's Hugging Face cache names its models in `index.json`; the row
    /// takes that name over the folder's id when it has one.
    static func folderModels(
        store: AIModelScanPolicy.Store,
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        access: ScanAccess = .full
    ) -> [LargeFile] {
        var models: [LargeFile] = []
        for root in AIModelScanPolicy.roots(for: store, home: home, environment: environment) {
            guard canRead(root, home: home, access: access) else { continue }
            let names = store == .huggingFaceAppCache ? installedModelNames(indexIn: root) : [:]
            collectModels(under: root, relativeName: [], store: store, names: names, into: &models)
        }
        return models
    }

    /// How many folder levels a store nests models under. Jan's
    /// `huggingface.co/<org>/<repo>/` is the deepest known, at three.
    private static let folderStoreMaxDepth = 4

    /// `relativeName` is the folder's path below the store root, kept as
    /// components rather than cut from the path: the listing can spell a root
    /// `/private/var/…` where the policy said `/var/…`, and a cut would then
    /// leave a stray `models/` on every name.
    private static func collectModels(
        under folder: URL,
        relativeName: [String],
        store: AIModelScanPolicy.Store,
        names: [String: String],
        into models: inout [LargeFile]
    ) {
        if Task.isCancelled { return }
        let entries = children(of: folder)

        // A loose weight file at the root is its own model, as GPT4All and
        // Whisper keep them. Below the root, the folder is the model.
        if relativeName.isEmpty {
            for entry in entries where entry.isRegularFile {
                guard AIModelScanPolicy.isWeightFile(named: entry.url.lastPathComponent, insideKnownStore: true),
                      let values = try? entry.url.resourceValues(forKeys: [
                          .totalFileAllocatedSizeKey, .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey
                      ])
                else { continue }
                let bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                guard bytes > 0 else { continue }
                models.append(LargeFile(
                    path: entry.url,
                    sizeBytes: bytes,
                    lastUsed: max(values.contentAccessDate ?? .distantPast, values.contentModificationDate ?? .distantPast),
                    category: .aiModel,
                    sourceLabel: store.displayName,
                    componentPaths: [entry.url],
                    kind: .aiModel(store)
                ))
            }
        }

        for entry in entries where entry.isDirectory {
            if Task.isCancelled { return }
            let name = entry.url.lastPathComponent
            let holdsWeights = AIModelScanPolicy.isWeightBundle(named: name)
                || children(of: entry.url).contains { child in
                    child.isRegularFile && AIModelScanPolicy.isWeightFile(named: child.url.lastPathComponent, insideKnownStore: true)
                }
            if holdsWeights {
                let measured = FolderSizing.walkedSize(at: entry.url, skipsPackages: false)
                guard measured.bytes > 0 else { continue }
                // Jan files Hub downloads under `huggingface.co/<org>/<repo>`;
                // the host says nothing the user would call the model by.
                var relative = relativeName + [name]
                if relative.count > 1, relative.first == "huggingface.co" { relative.removeFirst() }
                models.append(LargeFile(
                    path: entry.url,
                    sizeBytes: measured.bytes,
                    lastUsed: measured.lastUsed,
                    category: .aiModel,
                    displayNameOverride: names[name] ?? relative.joined(separator: "/"),
                    sourceLabel: store.displayName,
                    componentPaths: [entry.url],
                    kind: .aiModel(store)
                ))
            } else if relativeName.count + 1 < folderStoreMaxDepth {
                collectModels(under: entry.url, relativeName: relativeName + [name], store: store, names: names, into: &models)
            }
        }
    }

    /// The `index.json` an app keeps beside its models under
    /// `~/Library/Caches/huggingface/models`: `installedModels[].id` is the
    /// folder, `installedModels[].definition.name` what the app calls it. Read
    /// only, never written: it is the app's file, and the row says so.
    static func installedModelNames(indexIn root: URL) -> [String: String] {
        let indexURL = root.appendingPathComponent("index.json", isDirectory: false)
        guard let data = try? Data(contentsOf: indexURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = json["installedModels"] as? [[String: Any]]
        else { return [:] }

        var names: [String: String] = [:]
        for model in installed {
            guard let id = model["id"] as? String,
                  let definition = model["definition"] as? [String: Any],
                  let name = definition["name"] as? String, !name.isEmpty
            else { continue }
            names[id] = name
        }
        return names
    }

    // MARK: - Loose weights

    /// Weight files in the places Large Files does not walk and no known store
    /// claims. One row per file, or per Core ML bundle, shown by the folder it
    /// sits in so the user can tell which app downloaded it. Only files over
    /// `looseWeightSizeFloorBytes` count: below that, a weight file in an app's
    /// folder is an asset the app ships with.
    static func looseWeights(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        access: ScanAccess = .full,
        sizeFloor: Int64 = AIModelScanPolicy.looseWeightSizeFloorBytes
    ) -> [LargeFile] {
        let fm = FileManager.default
        let knownRoots = Set(AIModelScanPolicy.allRoots(home: home, environment: environment)
            .map { $0.resolvingSymlinksInPath().path })
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey,
            .contentAccessDateKey, .contentModificationDateKey
        ]
        var models: [LargeFile] = []

        for root in AIModelScanPolicy.looseWeightRoots(home: home) {
            guard canRead(root, home: home, access: access) else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let next = enumerator.nextObject() {
                if Task.isCancelled { return models }
                guard let url = next as? URL, let values = try? url.resourceValues(forKeys: keys) else { continue }
                let name = url.lastPathComponent

                if values.isDirectory == true {
                    if AIModelScanPolicy.sweepSkipsDirectory(named: name)
                        || enumerator.level >= AIModelScanPolicy.looseWeightMaxDepth
                        || knownRoots.contains(url.resolvingSymlinksInPath().path)
                        || !ProtectedLocations.isReadable(url, access: access, home: home) {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard AIModelScanPolicy.isWeightBundle(named: name) else { continue }
                    enumerator.skipDescendants()
                    let measured = FolderSizing.walkedSize(at: url, skipsPackages: false)
                    guard measured.bytes >= sizeFloor else { continue }
                    models.append(looseWeightRow(url, bytes: measured.bytes, lastUsed: measured.lastUsed))
                    continue
                }

                guard values.isRegularFile == true,
                      AIModelScanPolicy.isWeightFile(named: name, insideKnownStore: false)
                else { continue }
                let bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                guard bytes >= sizeFloor else { continue }
                models.append(looseWeightRow(
                    url,
                    bytes: bytes,
                    lastUsed: max(values.contentAccessDate ?? .distantPast, values.contentModificationDate ?? .distantPast)
                ))
            }
        }
        return models
    }

    /// No `sourceLabel`: the row shows its folder, the way an ordinary Large
    /// Files row does, because the folder is what names the owning app.
    private static func looseWeightRow(_ url: URL, bytes: Int64, lastUsed: Date) -> LargeFile {
        LargeFile(
            path: url.standardizedFileURL,
            sizeBytes: bytes,
            lastUsed: lastUsed,
            category: .aiModel,
            componentPaths: [url],
            kind: .aiModel(.looseWeights)
        )
    }

    // MARK: - Listing

    private struct Entry {
        let url: URL
        let isRegularFile: Bool
        let isDirectory: Bool
    }

    /// One folder's visible entries, with symlinks left as neither file nor
    /// folder: a link is not a model, and following one could leave the store.
    private static func children(of folder: URL) -> [Entry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return nil }
            return Entry(url: url, isRegularFile: values.isRegularFile == true, isDirectory: values.isDirectory == true)
        }
    }

    private static func directories(in folder: URL) -> [URL] {
        children(of: folder).filter(\.isDirectory).map(\.url)
    }
}

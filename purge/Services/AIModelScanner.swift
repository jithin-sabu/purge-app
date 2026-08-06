import Foundation

/// Discovers locally downloaded AI models and reports them as whole models
/// rather than as files on disk.
///
/// Ollama stores content-addressed blobs (`blobs/sha256-4c27e0…`), so listing
/// the raw files would show the user a meaningless hex name and let them break
/// a model without Ollama noticing — the manifest would still claim the model
/// is installed. Blobs are also shared between models, so the reclaimable size
/// of a model is only the blobs no other manifest references.
/// `nonisolated` for the same reason as `LargeFileScanner` — see the note there.
/// Without it the `Task.detached` in `scanStream` hops back to the main actor and
/// this runs its manifest walk on the UI thread.
nonisolated final class AIModelScanner {
    func scanStream(minBytes: Int64, staleDays: Int) -> AsyncStream<LargeFile> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await Self.run(minBytes: minBytes, staleDays: staleDays, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        minBytes: Int64,
        staleDays: Int,
        continuation: AsyncStream<LargeFile>.Continuation
    ) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let now = Date()
        let discovered = ollamaModels(home: home) + lmStudioModels(home: home)

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

    static func ollamaModels(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> [LargeFile] {
        let fm = FileManager.default
        let root = AIModelScanPolicy.ollamaRoot(home: home, environment: environment)
        let manifestRoot = root.appendingPathComponent("manifests", isDirectory: true)
        let blobRoot = root.appendingPathComponent("blobs", isDirectory: true)
        guard fm.fileExists(atPath: manifestRoot.path) else { return [] }

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
                sourceLabel: AIModelScanPolicy.Runtime.ollama.displayName,
                componentPaths: components
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

    // MARK: - LM Studio

    /// LM Studio lays models out as `<publisher>/<repo>/<weights>.gguf`, so the
    /// repo directory is the unit — it holds the weights plus any config and
    /// split parts that belong with them.
    static func lmStudioModels(home: URL) -> [LargeFile] {
        let fm = FileManager.default
        var models: [LargeFile] = []

        for root in AIModelScanPolicy.lmStudioRoots(home: home) {
            guard fm.fileExists(atPath: root.path) else { continue }
            let publishers = (try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for publisher in publishers {
                if Task.isCancelled { return models }
                guard (try? publisher.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }

                let repos = (try? fm.contentsOfDirectory(
                    at: publisher,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []

                for repo in repos {
                    guard (try? repo.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    else { continue }
                    let measured = directorySize(at: repo)
                    guard measured.bytes > 0 else { continue }

                    models.append(LargeFile(
                        path: repo,
                        sizeBytes: measured.bytes,
                        lastUsed: measured.lastUsed,
                        category: .aiModel,
                        displayNameOverride: "\(publisher.lastPathComponent)/\(repo.lastPathComponent)",
                        sourceLabel: AIModelScanPolicy.Runtime.lmStudio.displayName,
                        componentPaths: [repo]
                    ))
                }
            }
        }

        return models
    }

    private static func directorySize(at url: URL) -> (bytes: Int64, lastUsed: Date) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey,
            .contentAccessDateKey, .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return (0, .distantPast) }

        var bytes: Int64 = 0
        var lastUsed = Date.distantPast
        while let next = enumerator.nextObject() {
            if Task.isCancelled { break }
            guard let fileURL = next as? URL,
                  let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { continue }
            bytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            lastUsed = max(lastUsed, max(
                values.contentAccessDate ?? .distantPast,
                values.contentModificationDate ?? .distantPast
            ))
        }
        return (bytes, lastUsed)
    }
}

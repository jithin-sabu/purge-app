import CryptoKit
import Foundation

/// Finds byte-identical files among the rows a Large Files scan already produced.
///
/// Deliberately scoped to the scan results rather than the whole disk: walking
/// directories Purge has no other reason to touch would turn a focused tool into
/// a general duplicate finder, and the hashing cost would stop being incidental.
///
/// Three stages, cheapest first, so almost nothing gets read:
///
/// 1. Bucket by **logical** size. Sizes that appear once can't have a twin, and
///    those files are never opened.
/// 2. Digest a 64 KB head + 64 KB tail sample. Two same-size files that aren't
///    copies almost always differ inside the first block (container headers,
///    timestamps), so this costs two seeks and kills them.
/// 3. Full streaming digest, only for files still colliding after stage 2 — which
///    in practice means only real duplicates pay for a full read.
///
/// Nothing is reported as a duplicate without a matching full-content digest. A
/// wrong "duplicate" badge invites someone to delete the only copy of a file, and
/// Trash is a thin backstop for that.
///
/// **Hard links** are collapsed before bucketing: two names for one inode are not
/// two copies, and deleting one frees nothing. **APFS clones** are not detectable
/// this way — they have distinct inodes but share storage, so a clone pair is
/// reported as a duplicate whose reclaimable bytes overstate what deleting
/// actually frees. There is no cheap public API for block sharing.
///
/// `nonisolated` is load-bearing, not tidiness — same reason as `LargeFileScanner`.
/// The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without
/// it this type is implicitly main-actor isolated and the whole hashing pass runs
/// on the UI thread.
nonisolated final class DuplicateFileDetector {
    /// Bytes taken from each end of a file for the stage-2 sample.
    private static let sampleWindowBytes = 64 * 1024

    /// Read granularity for the full digest. Streaming in chunks rather than
    /// `Data(contentsOf:)`, which would map a multi-gigabyte video into memory.
    private static let streamChunkBytes = 1 << 20

    /// How many files are hashed at once. This is disk-bound, so a wider fan-out
    /// buys nothing and only risks crowding the cooperative pool.
    private static let maxConcurrentDigests = 3

    /// Runs the pass and returns the finished index. Cancellation propagates into
    /// the detached work, so a superseding scan abandons in-flight reads instead
    /// of hashing gigabytes nobody is waiting for.
    func findDuplicates(in files: [LargeFile]) async -> DuplicateIndex {
        let task = Task.detached(priority: .utility) {
            await Self.run(files: files)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Stages

    private static func run(files: [LargeFile]) async -> DuplicateIndex {
        let candidates = bucketBySize(files)
        guard !candidates.isEmpty else { return .empty }
        if Task.isCancelled { return .empty }

        var groups: [DuplicateGroup] = []
        for (size, paths) in candidates {
            if Task.isCancelled { return .empty }
            let confirmed = await confirmedGroups(paths: paths, size: size)
            groups.append(contentsOf: confirmed)
        }
        if Task.isCancelled { return .empty }
        return DuplicateIndex(groups: groups)
    }

    /// A single candidate file: the row identity to report against, and the URL
    /// to read.
    private struct Candidate: Sendable {
        let fileID: String
        let url: URL
    }

    /// Stage 1. Groups scan rows by logical size, dropping sizes that occur once.
    ///
    /// Buckets on `.fileSizeKey` rather than `LargeFile.sizeBytes`: the scanner
    /// stores `totalFileAllocatedSize`, which differs between identical files
    /// across volumes or under different APFS compression. Bucketing on allocated
    /// size would silently miss real duplicates.
    ///
    /// Multi-component rows are skipped outright. An AI model is a manifest plus
    /// blobs it shares with other models — there is no single file to digest, and
    /// two models legitimately sharing blobs are not duplicates of each other.
    private static func bucketBySize(_ files: [LargeFile]) -> [(Int64, [Candidate])] {
        var bySize: [Int64: [Candidate]] = [:]

        for file in files {
            if Task.isCancelled { return [] }
            guard file.componentPaths.count == 1 else { continue }

            let url = file.path.standardizedFileURL
            guard let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey
            ]) else { continue }
            guard values.isRegularFile == true else { continue }
            guard let size = values.fileSize.map(Int64.init), size > 0 else { continue }

            // Skip anything with more than one name on disk. Trashing such a path
            // frees nothing — the inode survives under its other links — so it
            // cannot contribute the reclaimable space a duplicate group promises.
            //
            // The link count catches this whether or not the other name is
            // somewhere the scan looked, which deduplicating by inode within this
            // list could not: a copy hard-linked to a path outside the scan roots
            // would still have been offered as free space.
            //
            // The cost is a genuine miss — an ordinary file and a hard-linked one
            // with identical contents are a real duplicate, and this drops the
            // pair rather than show a group where deleting the wrong member frees
            // nothing. Silence is the right side to err on: hard links are rare in
            // the folders Large Files scans, and overstating recoverable space is
            // the failure this feature cannot afford.
            guard linkCount(for: url) == 1 else { continue }

            bySize[size, default: []].append(Candidate(fileID: file.id, url: url))
        }

        return bySize
            .filter { $0.value.count > 1 }
            .map { ($0.key, $0.value) }
            // Biggest first: if the pass is cancelled part-way the work already
            // done is the work that mattered.
            .sorted { $0.0 > $1.0 }
    }

    /// Stages 2 and 3 for one size bucket.
    private static func confirmedGroups(paths: [Candidate], size: Int64) async -> [DuplicateGroup] {
        let sampled = await digest(paths) { url in
            sampleDigest(of: url, size: size)
        }
        // Only sample-collisions are worth a full read; everything else is
        // already proven distinct.
        let contested = sampled
            .filter { $0.value.count > 1 }
            .flatMap(\.value)
        guard !contested.isEmpty else { return [] }
        if Task.isCancelled { return [] }

        let full = await digest(contested) { url in
            fullDigest(of: url)
        }

        return full.compactMap { digest, members in
            guard members.count > 1 else { return nil }
            let ids = members
                .map(\.fileID)
                .sorted()
            return DuplicateGroup(id: digest, fileIDs: ids, sizeBytes: size)
        }
    }

    /// Runs `hash` over the candidates and buckets them by the digest it
    /// returned. Files that fail to read are dropped — an unreadable file can't
    /// be proven to be a copy of anything.
    ///
    /// Hashes run `maxConcurrentDigests` at a time, one batch after another. A
    /// sliding window would keep the disk marginally busier, but buckets are
    /// small (a size collision among large files is rare) and a plain batch loop
    /// is far easier to reason about for cancellation.
    private static func digest(
        _ candidates: [Candidate],
        using hash: @Sendable @escaping (URL) -> String?
    ) async -> [String: [Candidate]] {
        var results: [String: [Candidate]] = [:]

        var start = candidates.startIndex
        while start < candidates.endIndex {
            if Task.isCancelled { return [:] }
            let end = min(start + maxConcurrentDigests, candidates.endIndex)
            let batch = Array(candidates[start..<end])
            start = end

            await withTaskGroup(of: (Candidate, String?).self) { group in
                for candidate in batch {
                    group.addTask {
                        (candidate, hash(candidate.url))
                    }
                }
                for await (candidate, digest) in group {
                    guard let digest else { continue }
                    results[digest, default: []].append(candidate)
                }
            }
        }

        return Task.isCancelled ? [:] : results
    }

    /// How many names on disk point at this file. 1 for an ordinary file; more
    /// once it has been hard-linked. Unreadable attributes report 1, the same way
    /// the rest of this pass treats a file it cannot inspect — the content digest
    /// still has to agree before anything is called a duplicate.
    private static func linkCount(for url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let links = attrs[.referenceCount] as? NSNumber else { return 1 }
        return links.intValue
    }

    // MARK: - Digests

    /// Stage 2 digest: size, then the first and last 64 KB. The size goes into
    /// the hash so a sample digest is never comparable across buckets.
    private static func sampleDigest(of url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }

        // `try?` would flatten a read failure and a short read into the same
        // nil, and a failed read that hashed as "empty" could make two unrelated
        // files agree. Errors have to abandon the digest outright.
        let window = Int64(sampleWindowBytes)
        do {
            hasher.update(data: try handle.read(upToCount: sampleWindowBytes) ?? Data())

            // Only seek for a tail when there is one the head didn't cover.
            if size > window {
                try handle.seek(toOffset: UInt64(size - window))
                hasher.update(data: try handle.read(upToCount: sampleWindowBytes) ?? Data())
            }
        } catch {
            return nil
        }

        return hexString(hasher.finalize())
    }

    /// Stage 3 digest: the whole file, streamed. Returns nil on cancellation so a
    /// half-read file can never be mistaken for a match.
    private static func fullDigest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            if Task.isCancelled { return nil }
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: streamChunkBytes)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hexString(hasher.finalize())
    }

    private static func hexString(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

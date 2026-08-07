import Foundation
import Testing
@testable import Purge

/// Covers the duplicate pass that runs over finished Large Files results.
///
/// The stakes are asymmetric: a missed duplicate costs the user nothing they
/// didn't already have, while a *wrong* duplicate badge invites someone to delete
/// the only copy of a file. So most of these tests are about what must NOT be
/// grouped.
@Suite("Large file duplicate detection")
struct DuplicateFileDetectorTests {
    // MARK: - Fixtures

    private func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-dupe-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ bytes: Data, to url: URL) throws -> URL {
        try bytes.write(to: url)
        return url
    }

    /// Deterministic filler of a given length. Not zeros: a run of zeros compresses
    /// and clones in ways that could make two "different" fixtures accidentally
    /// share storage on APFS.
    private func filler(_ length: Int, seed: UInt8 = 7) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        var value = seed
        for _ in 0..<length {
            value = value &* 31 &+ 17
            bytes.append(value)
        }
        return Data(bytes)
    }

    private func largeFile(at url: URL, componentPaths: [URL]? = nil) -> LargeFile {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return LargeFile(
            path: url,
            sizeBytes: Int64(size),
            lastUsed: Date(),
            category: LargeFileCategory.category(forExtension: url.pathExtension),
            componentPaths: componentPaths
        )
    }

    // MARK: - Grouping

    @Test
    func identicalFilesAreReportedAsOneGroup() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = filler(256 * 1024)
        let a = try write(payload, to: root.appendingPathComponent("holiday.mov"))
        let b = try write(payload, to: root.appendingPathComponent("holiday-copy.mov"))

        let index = await DuplicateFileDetector().findDuplicates(in: [largeFile(at: a), largeFile(at: b)])

        #expect(index.groups.count == 1)
        let group = try #require(index.groups.first)
        #expect(group.copyCount == 2)
        #expect(Set(group.fileIDs) == [a.standardizedFileURL.path, b.standardizedFileURL.path])
        #expect(group.sizeBytes == Int64(payload.count))
        // One copy is worth keeping, so only the redundant copy counts as space.
        #expect(group.reclaimableBytes == Int64(payload.count))
        #expect(index.copyCount(forFileID: a.standardizedFileURL.path) == 2)
    }

    @Test
    func threeCopiesReportOneGroupOfThree() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = filler(128 * 1024)
        let urls = try (0..<3).map {
            try write(payload, to: root.appendingPathComponent("clip-\($0).mp4"))
        }

        let index = await DuplicateFileDetector().findDuplicates(in: urls.map { largeFile(at: $0) })

        #expect(index.groups.count == 1)
        let group = try #require(index.groups.first)
        #expect(group.copyCount == 3)
        #expect(group.reclaimableBytes == Int64(payload.count) * 2)
        #expect(index.duplicateFileCount == 3)
    }

    // MARK: - What must not be grouped

    /// The whole reason stage 3 exists. These two files agree on size *and* on
    /// both 64 KB sample windows — only a full read can tell them apart.
    @Test
    func sameSizeAndSameSamplesButDifferentMiddleIsNotGrouped() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        var payload = filler(512 * 1024)
        let a = try write(payload, to: root.appendingPathComponent("render-a.mov"))
        // Flip one byte well inside the file, past the head window and before the
        // tail window.
        payload[256 * 1024] = payload[256 * 1024] &+ 1
        let b = try write(payload, to: root.appendingPathComponent("render-b.mov"))

        let index = await DuplicateFileDetector().findDuplicates(in: [largeFile(at: a), largeFile(at: b)])

        #expect(index.isEmpty)
    }

    @Test
    func filesOfDifferentSizesAreNeverGrouped() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let a = try write(filler(64 * 1024), to: root.appendingPathComponent("a.zip"))
        let b = try write(filler(65 * 1024), to: root.appendingPathComponent("b.zip"))

        let index = await DuplicateFileDetector().findDuplicates(in: [largeFile(at: a), largeFile(at: b)])

        #expect(index.isEmpty)
    }

    /// Two names for one inode are one file. Deleting either frees nothing, so
    /// calling them duplicates would promise space that isn't there.
    @Test
    func hardLinkedPathsAreNotReportedAsDuplicates() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let a = try write(filler(96 * 1024), to: root.appendingPathComponent("original.iso"))
        let b = root.appendingPathComponent("hardlink.iso")
        try FileManager.default.linkItem(at: a, to: b)

        let index = await DuplicateFileDetector().findDuplicates(in: [largeFile(at: a), largeFile(at: b)])

        #expect(index.isEmpty)
    }

    /// AI-model rows stand for a manifest plus blobs they may legitimately share
    /// with other models. There is no single file to digest, and two models
    /// sharing a blob are not copies of each other.
    @Test
    func multiComponentRowsAreExcluded() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = filler(64 * 1024)
        let manifestA = try write(payload, to: root.appendingPathComponent("manifest-a"))
        let manifestB = try write(payload, to: root.appendingPathComponent("manifest-b"))
        let blob = try write(filler(32 * 1024), to: root.appendingPathComponent("blob"))

        let index = await DuplicateFileDetector().findDuplicates(in: [
            largeFile(at: manifestA, componentPaths: [manifestA, blob]),
            largeFile(at: manifestB, componentPaths: [manifestB, blob]),
        ])

        #expect(index.isEmpty)
    }

    @Test
    func missingFilesAreSkippedRatherThanGrouped() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        let real = try write(filler(48 * 1024), to: root.appendingPathComponent("present.pdf"))
        let ghost = root.appendingPathComponent("deleted-since-the-scan.pdf")

        let index = await DuplicateFileDetector().findDuplicates(in: [
            largeFile(at: real),
            LargeFile(path: ghost, sizeBytes: 48 * 1024, lastUsed: Date(), category: .pdf),
        ])

        #expect(index.isEmpty)
    }

    // MARK: - Cancellation

    /// A superseding scan must be able to abandon the pass. Uses many small
    /// buckets rather than a few huge files so there are plenty of cancellation
    /// checkpoints without writing hundreds of megabytes to disk.
    @Test
    func cancellingTheEnclosingTaskAbandonsThePass() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }

        var files: [LargeFile] = []
        for i in 0..<150 {
            let payload = filler(4096 + i, seed: UInt8(i % 251))
            let a = try write(payload, to: root.appendingPathComponent("pair-\(i)-a.bin"))
            let b = try write(payload, to: root.appendingPathComponent("pair-\(i)-b.bin"))
            files.append(largeFile(at: a))
            files.append(largeFile(at: b))
        }

        let detector = DuplicateFileDetector()
        let captured = files
        let task = Task { await detector.findDuplicates(in: captured) }
        task.cancel()

        #expect(await task.value.isEmpty)
    }

    // MARK: - Index bookkeeping

    /// After a delete, a group of two that lost a member is no longer a duplicate.
    /// Leaving the survivor badged "2 copies" would misdescribe the disk.
    @Test
    func pruningAGroupBelowTwoCopiesDropsItEntirely() {
        let pair = DuplicateGroup(id: "digest-pair", fileIDs: ["/a", "/b"], sizeBytes: 100)
        let trio = DuplicateGroup(id: "digest-trio", fileIDs: ["/c", "/d", "/e"], sizeBytes: 100)
        let index = DuplicateIndex(groups: [pair, trio])

        let pruned = index.removing(fileIDs: ["/b", "/c"])

        #expect(pruned.groups.count == 1)
        #expect(pruned.group(forFileID: "/a") == nil)
        #expect(pruned.copyCount(forFileID: "/d") == 2)
        #expect(pruned.copyCount(forFileID: "/c") == nil)
    }

    /// Groups are laid out most-reclaimable first, which is the order the
    /// Duplicates filter lays rows out in.
    @Test
    func groupsAreOrderedByReclaimableSpace() {
        let small = DuplicateGroup(id: "small", fileIDs: ["/s1", "/s2"], sizeBytes: 10)
        let big = DuplicateGroup(id: "big", fileIDs: ["/b1", "/b2"], sizeBytes: 1_000)
        let index = DuplicateIndex(groups: [small, big])

        #expect(index.groups.map(\.id) == ["big", "small"])
        #expect(index.groupRank(forFileID: "/b1") == 0)
        #expect(index.groupRank(forFileID: "/s1") == 1)
        // Non-members sort last, after every group.
        #expect(index.groupRank(forFileID: "/not-a-duplicate") == .max)
    }
}

import Darwin
import Foundation
import Testing
@testable import Purge

/// Large Files rows count an APFS clone set once, as folder scans do (#376).
/// A file duplicated in Finder is a clone, and trashing one copy frees nothing
/// while the other stays. Real clones are made in temporary folders only,
/// never the user's own.
@Suite("Clones in Large Files (#376)")
struct LargeFileCloneTests {
    private let fm = FileManager.default

    private static var countsClones: Bool {
        SharedBlocks.attributes & attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT) != 0
    }

    /// The folder the scan walks, inside a folder of the test's own. Remove
    /// the parent when done.
    private func makeRoot() throws -> URL {
        let root = fm.temporaryDirectory
            .appendingPathComponent("purge-large-clones-\(UUID().uuidString)/files", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ bytes: Int, to url: URL, seed: UInt8 = 31) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0) &* seed }).write(to: url)
    }

    private func clone(_ source: URL, to destination: URL) throws {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(clonefile(source.path, destination.path, 0) == 0, "clonefile: \(errno)")
    }

    private func allocated(_ url: URL) throws -> Int64 {
        Int64(try #require(url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize))
    }

    private func scan(_ root: URL, minBytes: Int64) async -> [LargeFile] {
        let ledger = FileAccessLedger(
            fileURL: root.deletingLastPathComponent().appendingPathComponent("ledger/access-times.json")
        )
        let stream = LargeFileScanner().scanEvents(
            minBytes: minBytes,
            staleDays: 0,
            roots: [root],
            virtualMachineRoots: [],
            iCloudDriveRoots: [],
            installedApps: [],
            isAppRunning: { _ in false },
            home: root,
            exclusions: ScanExclusions(keys: []),
            isExcluded: { _ in false },
            accessLedger: ledger
        )
        var files: [LargeFile] = []
        for await event in stream {
            if case .file(let file) = event { files.append(file) }
        }
        return files
    }

    private func row(_ name: String, in rows: [LargeFile]) throws -> LargeFile {
        try #require(rows.first { $0.path.lastPathComponent == name })
    }

    // MARK: The rule

    /// Keep Only in iCloud is offered only for purgeable files, and its row
    /// shows what eviction gives back, so a purgeable file keeps its size.
    @Test
    func aPurgeableFileKeepsItsSize() {
        let purgeable = SharedBlocks.FileState(flags: UInt64(EF_IS_PURGEABLE), cloneCount: 1)
        #expect(!purgeable.isFullClone)
        #expect(purgeable.countedBytes(allocated: 90_112) == 90_112)
    }

    @Test
    func aFullCloneShowsItsShareAndAnythingElseItsSize() {
        let sharesAll = UInt64(EF_SHARES_ALL_BLOCKS) | UInt64(EF_MAY_SHARE_BLOCKS)
        let full = SharedBlocks.FileState(flags: sharesAll, cloneCount: 2)
        #expect(full.isFullClone)
        #expect(full.countedBytes(allocated: 90_112) == 45_056)
        // A purgeable clone still shows only its share: evicting it frees
        // nothing while another clone stays.
        let purgeableClone = SharedBlocks.FileState(flags: sharesAll | UInt64(EF_IS_PURGEABLE), cloneCount: 3)
        #expect(purgeableClone.isFullClone)
        #expect(purgeableClone.countedBytes(allocated: 90_112) == 30_038)

        for other in [
            SharedBlocks.FileState.unknown,
            SharedBlocks.FileState(flags: 0, cloneCount: 1),
            SharedBlocks.FileState(flags: UInt64(EF_MAY_SHARE_BLOCKS), cloneCount: 2),
            SharedBlocks.FileState(flags: sharesAll, cloneCount: 1),
            SharedBlocks.FileState(flags: sharesAll, cloneCount: nil),
        ] {
            #expect(!other.isFullClone)
            #expect(other.countedBytes(allocated: 90_112) == 90_112)
        }
    }

    // MARK: Reading the volume

    @Test(.enabled(if: countsClones))
    func bothReadsSeeAClone() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        let original = root.appendingPathComponent("original.mov")
        let copy = root.appendingPathComponent("original copy.mov")
        let plain = root.appendingPathComponent("plain.mov")
        try write(300_000, to: original)
        try clone(original, to: copy)
        try write(300_000, to: plain, seed: 7)

        #expect(SharedBlocks.state(ofFileAt: original.path).isFullClone)
        #expect(SharedBlocks.state(ofFileAt: copy.path).isFullClone)
        #expect(!SharedBlocks.state(ofFileAt: plain.path).isFullClone)
        #expect(SharedBlocks.state(ofFileAt: root.appendingPathComponent("missing").path).flags == nil)

        let entries = try #require(DirectoryListing.entries(of: root.path))
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(try #require(byName["original.mov"]).sharedBlocks.isFullClone)
        #expect(try #require(byName["original copy.mov"]).sharedBlocks.isFullClone)
        #expect(try #require(byName["plain.mov"]).sharedBlocks.isFullClone == false)
        // The new fields don't move the ones before them.
        #expect(try #require(byName["plain.mov"]).logicalBytes == 300_000)
        #expect(try #require(byName["plain.mov"]).allocatedBytes == allocated(plain))
    }

    /// A file system that refuses the extended attributes still lists its
    /// files, without clone state, so they show their whole size. A bit no
    /// kernel knows, which fails the listing with `ERANGE`, stands in for
    /// such a file system.
    @Test
    func aListingWithoutTheExtendedAttributesStillListsTheFolder() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        let plain = root.appendingPathComponent("plain.mov")
        try write(300_000, to: plain)

        let entries = try #require(DirectoryListing.entries(of: root.path, extendedAttributes: 0x8000_0000))
        let entry = try #require(entries.first { $0.name == "plain.mov" })
        #expect(entry.sharedBlocks.flags == nil)
        #expect(entry.sharedBlocks.cloneCount == nil)
        #expect(entry.logicalBytes == 300_000)
        #expect(entry.allocatedBytes == (try allocated(plain)))
    }

    // MARK: Rows

    /// The Finder case: a file and its duplicate. One sits in the walked
    /// folder itself and one below it, so both ways the scan reads a file are
    /// covered. Their rows add up to one copy.
    @Test(.enabled(if: countsClones))
    func aDuplicatedFileAddsUpToOneCopy() async throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        let original = root.appendingPathComponent("holiday.mov")
        try write(2_000_000, to: original)
        try clone(original, to: root.appendingPathComponent("Edits/holiday copy.mov"))
        let bytes = try allocated(original)

        let rows = await scan(root, minBytes: 1_000_000)
        let first = try row("holiday.mov", in: rows)
        let second = try row("holiday copy.mov", in: rows)
        #expect(first.sizeBytes == (bytes + 1) / 2)
        #expect(second.sizeBytes == (bytes + 1) / 2)
        #expect(first.sizeBytes + second.sizeBytes <= bytes + 1)
    }

    /// The floor reads the whole allocated size, so a clone of a big file
    /// stays on the list even when its share is under the floor.
    @Test(.enabled(if: countsClones))
    func theSizeFloorReadsTheWholeFile() async throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        let original = root.appendingPathComponent("Folder/disk.img")
        try write(2_000_000, to: original)
        for index in 0..<3 {
            try clone(original, to: root.appendingPathComponent("Folder/disk \(index).img"))
        }
        let bytes = try allocated(original)

        let rows = await scan(root, minBytes: 1_500_000)
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { $0.sizeBytes == (bytes + 3) / 4 })
    }

    /// A clone of a file outside the scan shows its share only: trashing it
    /// alone frees nothing while the other copy stays.
    @Test(.enabled(if: countsClones))
    func aCloneOfAFileOutsideTheScanShowsItsShare() async throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside/archive.zip")
        try write(2_000_000, to: outside)
        try clone(outside, to: root.appendingPathComponent("archive.zip"))
        let bytes = try allocated(outside)

        let rows = await scan(root, minBytes: 1_000_000)
        #expect(try row("archive.zip", in: rows).sizeBytes == (bytes + 1) / 2)
    }

    /// A copy written to after it was cloned has blocks of its own and shows
    /// its whole size, as does a file that was never cloned.
    @Test(.enabled(if: countsClones))
    func aChangedCopyAndAPlainFileShowTheirWholeSize() async throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        let original = root.appendingPathComponent("Sub/project.psd")
        let changed = root.appendingPathComponent("Sub/project edited.psd")
        let plain = root.appendingPathComponent("Sub/other.psd")
        try write(2_000_000, to: original)
        try clone(original, to: changed)
        try write(2_000_000, to: plain, seed: 7)
        let handle = try FileHandle(forWritingTo: changed)
        try handle.write(contentsOf: Data(repeating: 9, count: 4_096))
        try handle.synchronize()
        try handle.close()

        let rows = await scan(root, minBytes: 1_000_000)
        #expect(try row("project edited.psd", in: rows).sizeBytes == allocated(changed))
        #expect(try row("other.psd", in: rows).sizeBytes == allocated(plain))
        // The original kept the block the copy wrote over, so it no longer
        // shares all its blocks either.
        #expect(try row("project.psd", in: rows).sizeBytes == allocated(original))
    }

    // MARK: Duplicates

    /// A clone pair is not grouped as duplicates: trashing either copy frees
    /// nothing while the other stays, the same as a hard link. Two separate
    /// copies of the same bytes still are.
    @Test(.enabled(if: countsClones))
    func clonesAreNotGroupedAsDuplicates() async throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        let original = root.appendingPathComponent("talk.mov")
        let copy = root.appendingPathComponent("talk copy.mov")
        try write(300_000, to: original)
        try clone(original, to: copy)
        let separateA = root.appendingPathComponent("song.wav")
        let separateB = root.appendingPathComponent("song copy.wav")
        try write(300_000, to: separateA, seed: 7)
        try write(300_000, to: separateB, seed: 7)

        let rows = await scan(root, minBytes: 100_000)
        #expect(rows.count == 4)
        let index = await DuplicateFileDetector().findDuplicates(in: rows)
        #expect(index.groups.count == 1)
        let group = try #require(index.groups.first)
        #expect(Set(group.fileIDs) == Set(rows.filter { $0.path.pathExtension == "wav" }.map(\.id)))
    }
}

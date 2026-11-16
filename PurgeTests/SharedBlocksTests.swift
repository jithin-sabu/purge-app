import Darwin
import Foundation
import Testing
@testable import Purge

/// Scan sizes count an APFS clone set once and leave out purgeable files
/// (#131). Real clones are made in temporary folders only, never the user's
/// own (#171).
@Suite("Clones and purgeable files in scan sizes")
struct SharedBlocksTests {
    private let fm = FileManager.default

    // MARK: The rule

    @Test
    func aFileTheVolumeSaysNothingAboutCountsInFull() {
        #expect(SharedBlocks.countedBytes(allocated: 90_112, flags: nil, cloneCount: nil) == 90_112)
        #expect(SharedBlocks.countedBytes(allocated: 90_112, flags: nil, cloneCount: 3) == 90_112)
    }

    @Test
    func aFileThatSharesNothingCountsInFull() {
        #expect(SharedBlocks.countedBytes(allocated: 90_112, flags: 0, cloneCount: 1) == 90_112)
    }

    @Test
    func aPurgeableFileCountsNothing() {
        let purgeable = UInt64(EF_IS_PURGEABLE)
        #expect(SharedBlocks.countedBytes(allocated: 90_112, flags: purgeable, cloneCount: 1) == 0)
        // Even a clone: macOS already counts the space as free.
        let both = purgeable | UInt64(EF_SHARES_ALL_BLOCKS) | UInt64(EF_MAY_SHARE_BLOCKS)
        #expect(SharedBlocks.countedBytes(allocated: 90_112, flags: both, cloneCount: 2) == 0)
    }

    @Test
    func aFullCloneCountsItsShareRoundedUp() {
        let sharesAll = UInt64(EF_SHARES_ALL_BLOCKS) | UInt64(EF_MAY_SHARE_BLOCKS)
        #expect(SharedBlocks.countedBytes(allocated: 90_112, flags: sharesAll, cloneCount: 2) == 45_056)
        #expect(SharedBlocks.countedBytes(allocated: 90_112, flags: sharesAll, cloneCount: 3) == 30_038)
    }

    /// Without a count of who shares the blocks there is no share to take.
    @Test
    func aPartlySharedOrUncountedFileCountsInFull() {
        let maybe = UInt64(EF_MAY_SHARE_BLOCKS)
        let sharesAll = UInt64(EF_SHARES_ALL_BLOCKS) | maybe
        #expect(SharedBlocks.countedBytes(allocated: 90_112, flags: maybe, cloneCount: 1) == 90_112)
        #expect(SharedBlocks.countedBytes(allocated: 90_112, flags: maybe, cloneCount: nil) == 90_112)
        #expect(SharedBlocks.countedBytes(allocated: 90_112, flags: sharesAll, cloneCount: nil) == 90_112)
        #expect(SharedBlocks.countedBytes(allocated: 90_112, flags: sharesAll, cloneCount: 1) == 90_112)
        #expect(SharedBlocks.countedBytes(allocated: 90_112, flags: sharesAll, cloneCount: 0) == 90_112)
    }

    @Test
    func thisMacReportsTheFlags() {
        #expect(SharedBlocks.attributes & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0)
    }

    // MARK: Real clones

    private static var countsClones: Bool {
        SharedBlocks.attributes & attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT) != 0
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("purge-clones-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: url)
    }

    private func clone(_ source: URL, to destination: URL) throws {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(clonefile(source.path, destination.path, 0) == 0, "clonefile: \(errno)")
    }

    private func allocated(_ url: URL) throws -> Int64 {
        Int64(try #require(url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize))
    }

    /// One original and two clones, one of them in another folder: the files
    /// add up to one copy, each folder holding its share.
    @Test(.enabled(if: countsClones))
    func clonesAddUpToOneCopyAcrossFolders() throws {
        let base = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: base) }
        let one = base.appendingPathComponent("one", isDirectory: true)
        let two = base.appendingPathComponent("two", isDirectory: true)
        let original = one.appendingPathComponent("original")
        try write(400_000, to: original)
        try clone(original, to: one.appendingPathComponent("copy"))
        try clone(original, to: two.appendingPathComponent("copy"))
        let bytes = try allocated(original)
        let share = (bytes + 2) / 3

        #expect(FolderSizing.walkedSize(at: one, skipsPackages: false).bytes == 2 * share)
        #expect(FolderSizing.walkedSize(at: two, skipsPackages: false).bytes == share)
        #expect(FolderSizing.walkedSize(at: base, skipsPackages: false).bytes == 3 * share)

        // `du` counts every clone in full; the walker counts each for its share,
        // which is all that deleting them would give back.
        let walked = try #require(FolderWalker.shared.sizes(of: [base.path], staysOnVolume: false)[0])
        let shareBlocks = (share + 511) / 512
        let folderBlocks = try [base, one, two].reduce(Int64(0)) { sum, url in
            var info = stat()
            try #require(lstat(url.path, &info) == 0)
            return sum + Int64(info.st_blocks)
        }
        #expect(walked == FolderWalker.kilobyteRounded(blocks: folderBlocks + 3 * shareBlocks))
    }

    /// The clone of something outside the folder counts its share only, so a
    /// copy of a file the scan doesn't cover doesn't promise its full size.
    @Test(.enabled(if: countsClones))
    func aCloneOfAFileOutsideTheFolderCountsItsShare() throws {
        let base = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: base) }
        let original = base.appendingPathComponent("outside/original")
        let copy = base.appendingPathComponent("scanned/copy")
        try write(300_000, to: original)
        try clone(original, to: copy)
        let bytes = try allocated(original)

        let scanned = base.appendingPathComponent("scanned", isDirectory: true)
        #expect(FolderSizing.walkedSize(at: scanned, skipsPackages: false).bytes == (bytes + 1) / 2)
    }

    /// A clone that is written to stops sharing all its blocks and counts in
    /// full; the clones still alike split what they share.
    @Test(.enabled(if: countsClones))
    func aChangedCloneCountsInFullAndTheRestSplit() throws {
        let base = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: base) }
        let original = base.appendingPathComponent("original")
        let alike = base.appendingPathComponent("alike")
        let changed = base.appendingPathComponent("changed")
        try write(300_000, to: original)
        try clone(original, to: alike)
        try clone(original, to: changed)
        let handle = try FileHandle(forWritingTo: changed)
        try handle.write(contentsOf: Data(repeating: 9, count: 4_096))
        try handle.synchronize()
        try handle.close()

        let bytes = try allocated(original)
        let changedBytes = try allocated(changed)
        #expect(FolderSizing.walkedSize(at: base, skipsPackages: false).bytes == 2 * ((bytes + 1) / 2) + changedBytes)
    }

    /// Scans size their rows through the walker, so a row of clones shows what
    /// a clean would free.
    @Test(.enabled(if: countsClones))
    func scanSizingCountsClonesOnce() throws {
        let base = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: base) }
        let row = base.appendingPathComponent("row", isDirectory: true)
        let original = row.appendingPathComponent("original")
        try write(500_000, to: original)
        for index in 0..<3 {
            try clone(original, to: row.appendingPathComponent("copy-\(index)"))
        }
        let bytes = try allocated(original)

        let size = try #require(FolderSizing.directorySizes(at: [row], split: .spread)[row.standardizedFileURL.path])
        // Four files, one copy's worth, plus the folder's own blocks.
        #expect(size < 2 * bytes)
        #expect(size >= bytes)
    }
}

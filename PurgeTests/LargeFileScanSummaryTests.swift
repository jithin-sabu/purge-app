import Foundation
import Testing
@testable import Purge

/// The scan's summary of what it skipped, which the empty state explains (#230).
/// Every tally here is read-only: nothing in it reaches `FileDeleter`.
@Suite("Large Files scan summary (#230)")
struct LargeFileScanSummaryTests {
    private struct Run {
        var files: [LargeFile] = []
        var summary: LargeFileScanSummary?
    }

    private func scan(roots: [URL], minBytes: Int64 = 1024, staleDays: Int = 0, home: URL? = nil) async -> Run {
        let stream = LargeFileScanner().scanEvents(
            minBytes: minBytes,
            staleDays: staleDays,
            roots: roots,
            home: home,
            exclusions: ScanExclusions(keys: []),
            isExcluded: { _ in false }
        )
        var run = Run()
        for await event in stream {
            switch event {
            case .file(let file): run.files.append(file)
            case .finished(let summary): run.summary = summary
            }
        }
        return run
    }

    private func makeRoot(_ name: String) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("purge-summary-\(name)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A file with a logical size and no blocks on disk, as a cloud placeholder reports.
    private func writePlaceholder(at url: URL, logicalBytes: UInt64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: logicalBytes)
        try handle.close()
    }

    @Test
    func placeholderIsCountedNotListed() async throws {
        let root = try makeRoot("cloud")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("dense.bin"))
        try writePlaceholder(at: root.appendingPathComponent("one.pst"), logicalBytes: 8 * 1024 * 1024)
        try writePlaceholder(at: root.appendingPathComponent("two.pst"), logicalBytes: 2 * 1024 * 1024)
        // Under the threshold even when downloaded: not a large file, so not counted.
        try writePlaceholder(at: root.appendingPathComponent("small.pst"), logicalBytes: 512)

        let run = await scan(roots: [root])
        let summary = try #require(run.summary)

        #expect(run.files.map(\.displayName) == ["dense.bin"])
        #expect(summary.cloudOnlyCount == 2)
        #expect(summary.cloudOnlyBytes == 10 * 1024 * 1024)
        #expect(summary.cloudOnly.map(\.provider) == [.unknown])
        #expect(summary.checkedRoots.map(\.path) == [root.path])
        #expect(summary.unreadableRoots.isEmpty)
        #expect(summary.minBytes == 1024)
    }

    /// The last-used filter applies to the tally as it does to the rows, so the
    /// summary answers the question the filter chips ask.
    @Test
    func placeholderRespectsTheLastUsedFilter() async throws {
        let root = try makeRoot("stale")
        defer { try? FileManager.default.removeItem(at: root) }
        try writePlaceholder(at: root.appendingPathComponent("fresh.pst"), logicalBytes: 8 * 1024 * 1024)

        let run = await scan(roots: [root], staleDays: 365)
        let summary = try #require(run.summary)
        #expect(summary.cloudOnlyCount == 0)
        #expect(summary.hasSkippedSomething == false)
    }

    @Test
    func providerComesFromTheCloudStorageFolder() throws {
        let home = try makeRoot("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        for folder in ["OneDrive-Personal", "Dropbox", "GoogleDrive-me@example.com", "Box-Box", "ProtonDrive-me"] {
            try FileManager.default.createDirectory(at: storage.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        func provider(_ path: String, ubiquitous: Bool = false) -> LargeFileScanSummary.CloudProvider {
            LargeFileScanSummary.CloudProvider.provider(
                for: home.appendingPathComponent(path), isUbiquitous: ubiquitous, home: home
            )
        }

        #expect(provider("Library/CloudStorage/OneDrive-Personal/Documents/a.pst") == .oneDrive)
        #expect(provider("Library/CloudStorage/Dropbox/a.mov") == .dropbox)
        #expect(provider("Library/CloudStorage/GoogleDrive-me@example.com/My Drive/a.zip") == .googleDrive)
        #expect(provider("Library/CloudStorage/Box-Box/a.zip") == .box)
        #expect(provider("Library/CloudStorage/ProtonDrive-me/a.zip") == .other("ProtonDrive"))
        #expect(provider("Documents/a.pst") == .unknown)
        #expect(provider("Documents/a.pst", ubiquitous: true) == .iCloudDrive)
        #expect(LargeFileScanSummary.CloudProvider.other("ProtonDrive").displayName == "ProtonDrive")
    }

    /// OneDrive's Folder Backup leaves ~/Documents as a link into CloudStorage.
    @Test
    func providerFollowsALinkedFolder() throws {
        let home = try makeRoot("linked")
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("Documents"),
            withDestinationURL: target
        )
        let provider = LargeFileScanSummary.CloudProvider.provider(
            for: home.appendingPathComponent("Documents/a.pst"), isUbiquitous: false, home: home
        )
        #expect(provider == .oneDrive)
    }

    @Test
    func mediaLibraryIsMeasuredNotListed() async throws {
        let root = try makeRoot("library")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Photos Library.photoslibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("originals"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: library.appendingPathComponent("originals/IMG_0001.heic"))
        try Data(repeating: 1, count: 4096).write(to: library.appendingPathComponent("originals/IMG_0002.heic"))

        let run = await scan(roots: [root])
        let summary = try #require(run.summary)

        #expect(run.files.isEmpty)
        let skipped = try #require(summary.skippedLibraries.first)
        #expect(skipped.name == "Photos Library")
        #expect(skipped.appName == "Photos")
        #expect(skipped.bytes >= 8192)
        #expect(summary.hasSkippedSomething)
    }

    /// A library under the threshold is nothing to explain.
    @Test
    func smallLibraryIsLeftOut() async throws {
        let root = try makeRoot("smalllibrary")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Clips.imovielibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: library.appendingPathComponent("a.bin"))

        let run = await scan(roots: [root], minBytes: 1024 * 1024)
        let summary = try #require(run.summary)
        #expect(summary.skippedLibraries.isEmpty)
    }

    @Test
    func rootThatCannotBeListedIsReported() async throws {
        let root = try makeRoot("unreadable")
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? fm.removeItem(at: root)
        }

        let run = await scan(roots: [root])
        let summary = try #require(run.summary)

        #expect(summary.checkedRoots.isEmpty)
        #expect(summary.unreadableRoots.map(\.path.path) == [root.path])
        #expect(summary.unreadableRoots.first?.name == root.lastPathComponent)
        #expect(summary.hasSkippedSomething)
    }

    @Test
    func missingRootIsNeitherCheckedNorUnreadable() async throws {
        let root = try makeRoot("present")
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("not-here", isDirectory: true)

        let run = await scan(roots: [root, missing])
        let summary = try #require(run.summary)
        #expect(summary.checkedRoots.map(\.path) == [root.path])
        #expect(summary.unreadableRoots.isEmpty)
    }

    /// The summary is read-only by construction: a cloud group carries counts
    /// and bytes, never a path, and the one path it does hold, a library's, is
    /// refused by the Large Files delete gate even if something handed it over.
    @Test
    func summaryPathsNeverPassTheDeleteGate() async throws {
        let home = try makeRoot("gatehome")
        defer { try? FileManager.default.removeItem(at: home) }
        let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
        let library = pictures.appendingPathComponent("Photos Library.photoslibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: library.appendingPathComponent("db.sqlite"))

        let run = await scan(roots: [pictures], home: home)
        let summary = try #require(run.summary)
        let skipped = try #require(summary.skippedLibraries.first)
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(skipped.path, home: home))
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(library.appendingPathComponent("db.sqlite"), home: home))
    }

    @Test
    func emptyStatePicksTheMostUrgentReason() {
        var summary = LargeFileScanSummary(minBytes: 1024)
        #expect(LargeFileEmptyState.resolve(nil) == .nothingLarge)
        #expect(LargeFileEmptyState.resolve(summary) == .nothingLarge)

        summary.skippedLibraries = [.init(path: URL(fileURLWithPath: "/tmp/Photos Library.photoslibrary"), bytes: 10)]
        #expect(LargeFileEmptyState.resolve(summary) == .library)

        summary.addCloudOnly(.oneDrive, bytes: 10)
        #expect(LargeFileEmptyState.resolve(summary) == .cloudOnly)

        summary.unreadableRoots = [.init(path: URL(fileURLWithPath: "/tmp/Documents"), reason: "denied")]
        #expect(LargeFileEmptyState.resolve(summary) == .incomplete)
    }

    @Test
    func cloudGroupsKeepAFixedProviderOrder() {
        var summary = LargeFileScanSummary(minBytes: 1024)
        summary.addCloudOnly(.unknown, bytes: 1)
        summary.addCloudOnly(.oneDrive, bytes: 2)
        summary.addCloudOnly(.iCloudDrive, bytes: 3)
        summary.addCloudOnly(.oneDrive, bytes: 4)
        #expect(summary.cloudOnly.map(\.provider) == [.iCloudDrive, .oneDrive, .unknown])
        #expect(summary.cloudOnly.map(\.count) == [1, 2, 1])
        #expect(summary.cloudOnly.map(\.bytes) == [3, 6, 1])
    }

    @Test
    func countTextReadsAsTheLegendDoes() {
        #expect(LargeFileScanSummaryCard.countText(count: 0, bytes: 0) == "0 files")
        #expect(LargeFileScanSummaryCard.countText(count: 1, bytes: 0) == "1 file")
        #expect(LargeFileScanSummaryCard.countText(count: 1, bytes: 1024 * 1024) == "1 file · \(formatBytes(1024 * 1024))")
        #expect(LargeFileScanSummaryCard.countText(count: 14, bytes: 1024 * 1024) == "14 files · \(formatBytes(1024 * 1024))")
    }
}

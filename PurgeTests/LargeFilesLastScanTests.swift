import Foundation
import Testing
@testable import Purge

/// Large Files keeps its last scan between launches as totals by kind, never as a
/// list of files (#283), so its tab can draw the page under glass while it scans
/// again without writing a file name anywhere.
@MainActor
@Suite("Large Files keeps its last scan by kind, never by name")
struct LargeFilesLastScanTests {

    @Test
    func aFinishedScanSavesTotalsByKindAndNoFileName() async throws {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        // Distinct sizes, so the duplicate check after the scan has nothing to hash.
        fake.largeFileEvents = [
            .file(file("/Users/someone/Movies/wedding-video.mov", bytes: 4_000_000_001, category: .video)),
            .file(file("/Users/someone/Movies/holiday-clip.mov", bytes: 1_000_000_002, category: .video)),
            .file(file("/Users/someone/Downloads/client-backup.zip", bytes: 2_000_000_003, category: .archive)),
            .file(file("/Users/someone/Documents/tax-return.pdf", bytes: 100_000_004, category: .pdf)),
        ]
        let store = fake.makeStore()

        await store.scanLargeFiles()

        let record = try #require(store.scanRecords[.largeFiles])
        #expect(record.largeFileCategories == [
            .init(category: "video", count: 2, bytes: 5_000_000_003),
            .init(category: "pdf", count: 1, bytes: 100_000_004),
            .init(category: "archive", count: 1, bytes: 2_000_000_003),
        ])
        let saved = try #require(fake.defaults.data(forKey: ScanRecordStore.key(for: .largeFiles)))
        let written = String(decoding: saved, as: UTF8.self)
        for name in ["wedding-video", "holiday-clip", "client-backup", "tax-return", "someone"] {
            #expect(!written.contains(name), "\(name)")
        }
    }

    /// After a finished scan, a trashed row comes off its kind with the total.
    @Test
    func aTrashedRowComesOffItsKind() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        let movie = file("/Users/someone/Movies/a.mov", bytes: 3_000_000_001, category: .video)
        let archive = file("/Users/someone/Downloads/b.zip", bytes: 2_000_000_002, category: .archive)
        fake.largeFileEvents = [.file(movie), .file(archive)]
        let store = fake.makeStore()
        await store.scanLargeFiles()
        #expect(store.isSettled(.largeFiles))

        store.removeClearedLargeFileRows([archive])

        #expect(await eventually {
            store.scanRecords[.largeFiles]?.largeFileCategories == [.init(category: "video", count: 1, bytes: 3_000_000_001)]
        })
        #expect(store.scanRecords[.largeFiles]?.count == 1)
    }

    /// A stopped rescan leaves the area unsettled and the saved record on show; a
    /// row trashed then comes off its kind as it comes off the total.
    @Test
    func aRowTrashedAfterAStoppedRescanComesOffItsKind() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        let clips = (0..<25).map { file("/Users/someone/Movies/clip-\($0).mov", bytes: 100_000_000 + Int64($0), category: .video) }
        fake.largeFileEvents = clips.map { .file($0) }
        let store = fake.makeStore()
        await store.scanLargeFiles()

        fake.holdsLargeFiles = true
        let rescan = Task { await store.scanLargeFiles() }
        #expect(await eventually { fake.largeFileScanCount == 2 && store.largeFiles.count == 25 })
        rescan.cancel()
        await rescan.value
        #expect(!store.isSettled(.largeFiles))

        store.removeClearedLargeFileRows([clips[0]])

        let kinds = store.scanRecords[.largeFiles]?.largeFileCategories
        #expect(kinds?.count == 1)
        #expect(kinds?.first?.count == 24)
        #expect(kinds?.first?.bytes == clips.dropFirst().reduce(Int64(0)) { $0 + $1.sizeBytes })
    }

    /// Before this launch lists a file, the tab draws the last scan by kind; the
    /// first file to land ends it.
    @Test
    func theTabShowsTheLastScanUntilAFileLands() async throws {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        let scannedAt = Date(timeIntervalSinceNow: -3_600)
        ScanRecordStore(defaults: fake.defaults).save(
            ScanRecord(
                completedAt: scannedAt,
                bytes: 6_710_000_000,
                count: 64,
                largeFileCategories: [
                    .init(category: "video", count: 23, bytes: 6_100_000_000),
                    .init(category: "pdf", count: 41, bytes: 610_000_000),
                    .init(category: "a-kind-this-build-lacks", count: 3, bytes: 1),
                ]
            ),
            for: .largeFiles
        )
        let store = fake.makeStore()

        let lastScan = try #require(store.largeFilesLastScan)
        #expect(lastScan.count == 64)
        #expect(lastScan.bytes == 6_710_000_000)
        #expect(lastScan.scannedAt == scannedAt)
        #expect(lastScan.kinds == [.init(category: .video, count: 23), .init(category: .pdf, count: 41)])

        store.largeFiles = [file("/Users/someone/Movies/a.mov", bytes: 1_000_000_000, category: .video)]
        #expect(store.largeFilesLastScan == nil)
    }

    /// A record saved before kinds were has only a total: the tab keeps the plain
    /// waiting state with its last-scan line.
    @Test
    func aRecordWithoutKindsKeepsThePlainWait() {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        ScanRecordStore(defaults: fake.defaults).save(
            ScanRecord(completedAt: Date(), bytes: 12_570_000_000, count: 109),
            for: .largeFiles
        )
        let store = fake.makeStore()

        #expect(store.applicableRecord(for: .largeFiles) != nil)
        #expect(store.largeFilesLastScan == nil)
    }

    // MARK: Helpers

    /// A file at `path`. Nothing exists there, so nothing could ever move.
    private func file(_ path: String, bytes: Int64, category: LargeFileCategory) -> LargeFile {
        LargeFile(path: URL(fileURLWithPath: path), sizeBytes: bytes, lastUsed: Date(), category: category)
    }

    /// Counts only the time this loop ran, as `ScanQueueStoreTests` does.
    private func eventually(timeout: TimeInterval = 30, _ condition: () -> Bool) async -> Bool {
        var waited: TimeInterval = 0
        var last = Date()
        while !condition() {
            guard waited < timeout else { return false }
            try? await Task.sleep(for: .milliseconds(10))
            let now = Date()
            waited += min(now.timeIntervalSince(last), 0.25)
            last = now
        }
        return true
    }
}

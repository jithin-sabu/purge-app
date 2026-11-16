import Darwin
import Foundation
import Testing
@testable import Purge

/// Large Files' "Last used" is the file's access time, and Purge's own reads
/// must not move it (#373). QuickLook maps a file to draw its thumbnail, which
/// moves the access time every time, so after one visit every row read "Today"
/// at the next scan. Everything here runs on throwaway files in a temp folder,
/// with a ledger file of its own.
@Suite("Large Files Last used (#373)")
struct LargeFileLastUsedTests {
    private let day: TimeInterval = 24 * 60 * 60

    /// The folder the scan walks, inside a folder of the test's own. Remove
    /// the parent when done.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-last-used-\(UUID().uuidString)/files", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Next to the scanned folder, not in it: the ledger writes its file a
    /// second after a record, and the scan would list it.
    private func makeLedger(in root: URL, name: String = "ledger", maxEntries: Int = 5_000) -> FileAccessLedger {
        FileAccessLedger(
            fileURL: root.deletingLastPathComponent().appendingPathComponent("\(name)/access-times.json"),
            maxEntries: maxEntries
        )
    }

    private func setTimes(_ url: URL, access: Date, modification: Date) {
        func spec(_ date: Date) -> timespec {
            let seconds = date.timeIntervalSince1970
            return timespec(tv_sec: Int(seconds), tv_nsec: Int((seconds - floor(seconds)) * 1_000_000_000))
        }
        var times = [spec(access), spec(modification)]
        _ = utimensat(AT_FDCWD, url.path, &times, 0)
    }

    /// A 64 KB file, last opened and last written `daysAgo` days back.
    private func writeOldFile(_ name: String, in root: URL, daysAgo: Double, contents: Data? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        try (contents ?? Data(repeating: 7, count: 64 * 1024)).write(to: url)
        let old = Date().addingTimeInterval(-daysAgo * day)
        setTimes(url, access: old, modification: old)
        return url
    }

    /// What QuickLook does to the file while it draws a thumbnail, as the
    /// thumbnail service sees it: the times before, the access time moved to
    /// now, the times after.
    private func drawThumbnail(of url: URL, ledger: FileAccessLedger) throws {
        let before = try #require(FileAccessLedger.Times(url: url))
        setTimes(url, access: Date(), modification: Date(timeIntervalSince1970: before.modification))
        ledger.record(url: url, before: before, after: FileAccessLedger.Times(url: url))
        // Records land on the ledger's own queue. This waits for them.
        _ = ledger.entry(for: url)
    }

    private func scan(_ root: URL, staleDays: Int, ledger: FileAccessLedger) async -> [LargeFile] {
        let stream = LargeFileScanner().scanEvents(
            minBytes: 1024,
            staleDays: staleDays,
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

    private func daysSince(_ date: Date) -> Double {
        Date().timeIntervalSince(date) / day
    }

    @Test("A thumbnail leaves the file's Last used and age filter as they were")
    func thumbnailKeepsLastUsed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = try writeOldFile("holiday.mov", in: root, daysAgo: 40)
        let ledger = makeLedger(in: root)
        defer { ledger.flush() }

        try drawThumbnail(of: file, ledger: ledger)
        let moved = try #require(FileAccessLedger.Times(url: file))
        #expect(daysSince(Date(timeIntervalSince1970: moved.access)) < 1)

        let rows = await scan(root, staleDays: 30, ledger: ledger)
        let row = try #require(rows.first { $0.path.lastPathComponent == "holiday.mov" })
        #expect(abs(daysSince(row.lastUsed) - 40) < 0.01)
    }

    @Test("Without the ledger the same file reads Today and the age filter drops it")
    func withoutLedgerTheFileReadsToday() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = try writeOldFile("holiday.mov", in: root, daysAgo: 40)

        let ledger = makeLedger(in: root)
        defer { ledger.flush() }
        try drawThumbnail(of: file, ledger: ledger)

        let other = makeLedger(in: root, name: "other")
        #expect(await scan(root, staleDays: 30, ledger: other).isEmpty)
        let rows = await scan(root, staleDays: 0, ledger: other)
        #expect(daysSince(try #require(rows.first { $0.path.lastPathComponent == file.lastPathComponent }).lastUsed) < 1)
    }

    @Test("Once the user opens the file, its new Last used shows and the entry goes")
    func userOpenShowsNewDate() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = try writeOldFile("report.pdf", in: root, daysAgo: 40)
        let ledger = makeLedger(in: root)
        defer { ledger.flush() }
        try drawThumbnail(of: file, ledger: ledger)

        // Any access time other than the one Quick Look left.
        let opened = Date().addingTimeInterval(-2 * day)
        let modification = try #require(FileAccessLedger.Times(url: file)).modification
        setTimes(file, access: opened, modification: Date(timeIntervalSince1970: modification))

        let rows = await scan(root, staleDays: 0, ledger: ledger)
        let row = try #require(rows.first { $0.path.lastPathComponent == file.lastPathComponent })
        #expect(abs(row.lastUsed.timeIntervalSince(opened)) < 0.001)
        #expect(ledger.entry(for: file) == nil)
    }

    @Test("A file written after the thumbnail shows its new date")
    func writtenFileShowsNewDate() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = try writeOldFile("draft.key", in: root, daysAgo: 40)
        let ledger = makeLedger(in: root)
        defer { ledger.flush() }
        try drawThumbnail(of: file, ledger: ledger)

        let access = try #require(FileAccessLedger.Times(url: file)).access
        let written = Date().addingTimeInterval(-2 * day)
        setTimes(file, access: Date(timeIntervalSince1970: access), modification: written)

        let rows = await scan(root, staleDays: 0, ledger: ledger)
        #expect(daysSince(try #require(rows.first { $0.path.lastPathComponent == file.lastPathComponent }).lastUsed) < 1)
        #expect(ledger.entry(for: file) == nil)
    }

    @Test("A second thumbnail keeps the user's date from before the first")
    func secondThumbnailKeepsFirstDate() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = try writeOldFile("clip.mp4", in: root, daysAgo: 40)
        let ledger = makeLedger(in: root)
        defer { ledger.flush() }

        try drawThumbnail(of: file, ledger: ledger)
        try await Task.sleep(for: .milliseconds(20))
        try drawThumbnail(of: file, ledger: ledger)

        let rows = await scan(root, staleDays: 30, ledger: ledger)
        #expect(abs(daysSince(try #require(rows.first { $0.path.lastPathComponent == file.lastPathComponent }).lastUsed) - 40) < 0.01)
    }

    @Test("The ledger is read back after a relaunch")
    func ledgerSurvivesRelaunch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = try writeOldFile("archive.zip", in: root, daysAgo: 40)
        let ledger = makeLedger(in: root)
        defer { ledger.flush() }
        try drawThumbnail(of: file, ledger: ledger)
        ledger.flush()

        let relaunched = FileAccessLedger(fileURL: ledger.fileURL)
        let rows = await scan(root, staleDays: 30, ledger: relaunched)
        #expect(abs(daysSince(try #require(rows.first { $0.path.lastPathComponent == file.lastPathComponent }).lastUsed) - 40) < 0.01)
    }

    /// The Quick Look panel reads the file some time after it is told to show
    /// it, so the panel's file is watched for a few seconds.
    @Test("A preview's read is kept when it comes after the panel shows the file")
    func previewKeepsLastUsed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = try writeOldFile("Ardia.dmg", in: root, daysAgo: 40)
        let ledger = makeLedger(in: root)
        defer { ledger.flush() }

        ledger.watch(file, checks: [0.2])
        let modification = try #require(FileAccessLedger.Times(url: file)).modification
        setTimes(file, access: Date(), modification: Date(timeIntervalSince1970: modification))
        #expect(await eventually { ledger.entry(for: file) != nil })

        let rows = await scan(root, staleDays: 30, ledger: ledger)
        #expect(abs(daysSince(try #require(rows.first { $0.path.lastPathComponent == file.lastPathComponent }).lastUsed) - 40) < 0.01)
    }

    @Test("A preview after a thumbnail keeps the user's date from before both")
    func previewAfterThumbnailKeepsFirstDate() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = try writeOldFile("site.pdf", in: root, daysAgo: 40)
        let modification = try #require(FileAccessLedger.Times(url: file)).modification
        let ledger = makeLedger(in: root)
        defer { ledger.flush() }
        try drawThumbnail(of: file, ledger: ledger)
        let userAccess = try #require(ledger.entry(for: file)).userAccess
        let thumbnailAccess = try #require(ledger.entry(for: file)).causedAccess

        ledger.watch(file, checks: [0.1, 0.3])
        setTimes(file, access: Date().addingTimeInterval(5), modification: Date(timeIntervalSince1970: modification))
        #expect(await eventually { ledger.entry(for: file)?.causedAccess != thumbnailAccess })
        try await Task.sleep(for: .milliseconds(500))

        #expect(ledger.entry(for: file)?.userAccess == userAccess)
    }

    /// The walk reads a folder's times before it looks at each file. A Quick
    /// Look read in between must not cost the file its entry.
    @Test("A read after the walk saw the file keeps the entry")
    func readDuringScanKeepsEntry() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = try writeOldFile("board.pdf", in: root, daysAgo: 40)
        let seen = try #require(FileAccessLedger.Times(url: file))
        let ledger = makeLedger(in: root)
        defer { ledger.flush() }
        try drawThumbnail(of: file, ledger: ledger)

        let shown = ledger.userAccess(
            of: file,
            access: Date(timeIntervalSince1970: seen.access),
            modification: Date(timeIntervalSince1970: seen.modification)
        )

        #expect(abs(shown.timeIntervalSince1970 - seen.access) < 0.001)
        #expect(ledger.entry(for: file) != nil)
    }

    /// A file not read since it was written: the user's first plain `read()`
    /// would move the access time, but not after Quick Look's has. Kept, the
    /// entry would show the file older than it is for good.
    @Test("A file not read since it was written keeps Quick Look's time")
    func unreadFileIsNotKept() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = try writeOldFile("export.mov", in: root, daysAgo: 40)
        setTimes(file, access: Date().addingTimeInterval(-40 * day), modification: Date().addingTimeInterval(-10 * day))
        let ledger = makeLedger(in: root)
        defer { ledger.flush() }

        try drawThumbnail(of: file, ledger: ledger)

        #expect(ledger.entry(for: file) == nil)
        let rows = await scan(root, staleDays: 0, ledger: ledger)
        #expect(daysSince(try #require(rows.first { $0.path.lastPathComponent == file.lastPathComponent }).lastUsed) < 1)
    }

    @Test("A preview's checks stop at the first move they keep")
    func previewChecksStopAtFirstMove() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = try writeOldFile("clip.mov", in: root, daysAgo: 40)
        let modification = try #require(FileAccessLedger.Times(url: file)).modification
        let ledger = makeLedger(in: root)
        defer { ledger.flush() }

        ledger.watch(file, checks: [0.1, 0.6])
        setTimes(file, access: Date(), modification: Date(timeIntervalSince1970: modification))
        #expect(await eventually { ledger.entry(for: file) != nil })
        // The user opens the file after the panel has read it.
        let opened = Date().addingTimeInterval(-2 * day)
        setTimes(file, access: opened, modification: Date(timeIntervalSince1970: modification))
        try await Task.sleep(for: .milliseconds(600))

        let rows = await scan(root, staleDays: 0, ledger: ledger)
        let row = try #require(rows.first { $0.path.lastPathComponent == file.lastPathComponent })
        #expect(abs(row.lastUsed.timeIntervalSince(opened)) < 0.001)
    }

    @Test("Showing another file ends the checks on the one before")
    func nextPreviewEndsTheWatch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let first = try writeOldFile("first.mov", in: root, daysAgo: 40)
        let second = try writeOldFile("second.mov", in: root, daysAgo: 40)
        let modification = try #require(FileAccessLedger.Times(url: first)).modification
        let ledger = makeLedger(in: root)
        defer { ledger.flush() }

        ledger.watch(first, checks: [0.3])
        ledger.watch(second, checks: [0.3])
        setTimes(first, access: Date(), modification: Date(timeIntervalSince1970: modification))
        try await Task.sleep(for: .milliseconds(600))

        #expect(ledger.entry(for: first) == nil)
    }

    @Test("A flushed ledger writes nothing later")
    func flushSkipsTheLateWrite() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = try writeOldFile("deck.key", in: root, daysAgo: 40)
        let ledger = makeLedger(in: root)
        try drawThumbnail(of: file, ledger: ledger)
        ledger.flush()
        #expect(FileManager.default.fileExists(atPath: ledger.fileURL.path))

        try FileManager.default.removeItem(at: ledger.fileURL.deletingLastPathComponent())
        try await Task.sleep(for: .milliseconds(1_300))

        #expect(!FileManager.default.fileExists(atPath: ledger.fileURL.deletingLastPathComponent().path))
    }

    @Test("A read that left the access time alone is not kept")
    func unmovedReadIsNotKept() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = try writeOldFile("plain.bin", in: root, daysAgo: 40)
        let ledger = makeLedger(in: root)
        defer { ledger.flush() }

        let times = FileAccessLedger.Times(url: file)
        ledger.record(url: file, before: times, after: times)
        #expect(ledger.entry(for: file) == nil)
    }

    @Test("Past the cap the oldest entries go first")
    func capDropsOldest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let ledger = makeLedger(in: root, maxEntries: 2)
        defer { ledger.flush() }
        let before = FileAccessLedger.Times(access: 100, modification: 100)
        let after = FileAccessLedger.Times(access: 200, modification: 100)
        let urls = (0..<3).map { root.appendingPathComponent("file-\($0).bin") }
        for (index, url) in urls.enumerated() {
            ledger.record(url: url, before: before, after: after, now: Date(timeIntervalSince1970: Double(index)))
        }

        #expect(ledger.entry(for: urls[0]) == nil)
        #expect(ledger.entry(for: urls[1]) != nil)
        #expect(ledger.entry(for: urls[2]) != nil)
    }

    /// The duplicate check reads files that share a size. A file not read
    /// since it was written has its access time older than its modification
    /// time, and on APFS a plain read of that file moves the access time.
    @Test("The duplicate check leaves access times alone")
    func duplicateCheckLeavesAccessTimes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let payload = Data((0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 17) })
        let written = Date().addingTimeInterval(-10 * day)
        let opened = Date().addingTimeInterval(-40 * day)
        let urls = try ["take-1.mov", "take-2.mov"].map { name in
            let url = root.appendingPathComponent(name)
            try payload.write(to: url)
            setTimes(url, access: opened, modification: written)
            return url
        }
        let before = urls.map { FileAccessLedger.Times(url: $0) }

        let files = urls.map {
            LargeFile(path: $0, sizeBytes: Int64(payload.count), lastUsed: written, category: .video)
        }
        let index = await DuplicateFileDetector().findDuplicates(in: files)

        #expect(index.groups.count == 1)
        #expect(urls.map { FileAccessLedger.Times(url: $0) } == before)
    }
}

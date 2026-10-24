import Foundation
import Testing
@testable import Purge

/// Remove Download for iCloud files in Large Files (#106). Nothing here touches
/// iCloud: the states are made up and the eviction is a recorder. The real API
/// was tried on a throwaway file before this was built (see the PR).
@Suite("Remove Download for iCloud files (#106)")
struct ICloudDownloadPolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// A file every check passes: synced, uploaded, downloaded, purgeable, quiet.
    private func ready(modifiedSecondsAgo: TimeInterval = 3600) -> ICloudDownloadState {
        ICloudDownloadState(
            isRegularFile: true,
            isUbiquitous: true,
            isUploaded: true,
            hasConflicts: false,
            isDownloadedAndCurrent: true,
            allocatedBytes: 500_000_000,
            isPurgeable: true,
            modified: now.addingTimeInterval(-modifiedSecondsAgo)
        )
    }

    @Test func aFileEveryCheckPassesIsRemovable() {
        #expect(ICloudDownloadPolicy.decision(for: ready(), now: now) == .removable)
    }

    @Test func eachCheckRefusesOnItsOwn() {
        var state = ready()
        #expect(ICloudDownloadPolicy.decision(for: nil, now: now) == .notAFile)

        state = ready(); state.isRegularFile = false
        #expect(ICloudDownloadPolicy.decision(for: state, now: now) == .notAFile)

        state = ready(); state.isUbiquitous = false
        #expect(ICloudDownloadPolicy.decision(for: state, now: now) == .notInICloud)

        state = ready(); state.hasConflicts = true
        #expect(ICloudDownloadPolicy.decision(for: state, now: now) == .hasConflicts)

        state = ready(); state.isUploaded = false
        #expect(ICloudDownloadPolicy.decision(for: state, now: now) == .notUploaded)

        state = ready(); state.isDownloadedAndCurrent = false
        #expect(ICloudDownloadPolicy.decision(for: state, now: now) == .notDownloaded)

        state = ready(); state.allocatedBytes = 0
        #expect(ICloudDownloadPolicy.decision(for: state, now: now) == .notDownloaded)

        state = ready(); state.isPurgeable = false
        #expect(ICloudDownloadPolicy.decision(for: state, now: now) == .keptOnThisMac)

        state = ready(); state.hasOtherLinks = true
        #expect(ICloudDownloadPolicy.decision(for: state, now: now) == .hasOtherLinks)
    }

    /// The case the #106 test found on a real Mac: a 3.71 GB file fully
    /// downloaded, never uploaded, and not uploading either. Not uploaded wins
    /// over everything that would otherwise pass.
    @Test func aDownloadedFileThatNeverUploadedStays() {
        var state = ready()
        state.isUploaded = false
        state.isPurgeable = true
        #expect(ICloudDownloadPolicy.decision(for: state, now: now) == .notUploaded)
    }

    @Test func aFileChangedInTheQuietPeriodStays() {
        #expect(ICloudDownloadPolicy.decision(for: ready(modifiedSecondsAgo: 60), now: now) == .changedRecently)
        #expect(ICloudDownloadPolicy.decision(for: ready(modifiedSecondsAgo: 299), now: now) == .changedRecently)
        #expect(ICloudDownloadPolicy.decision(for: ready(modifiedSecondsAgo: 300), now: now) == .removable)
        // A date in the future, or none, is not quiet.
        #expect(ICloudDownloadPolicy.decision(for: ready(modifiedSecondsAgo: -600), now: now) == .changedRecently)
        var undated = ready()
        undated.modified = nil
        #expect(ICloudDownloadPolicy.decision(for: undated, now: now) == .changedRecently)
    }

    @Test func scopeIsTheFoldersLargeFilesWalks() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        func inScope(_ path: String) -> Bool {
            ICloudDownloadPolicy.isInScope(URL(fileURLWithPath: path), home: home)
        }
        #expect(inScope("/Users/someone/Documents/film.mov"))
        #expect(inScope("/Users/someone/Desktop/a/b/disk.dmg"))
        #expect(inScope("/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Projects/clip.mov"))

        #expect(!inScope("/Users/someone/Library/Caches/thing.bin"))
        #expect(!inScope("/Users/someone/Library/Mobile Documents/iCloud~com~example~App/Documents/db.sqlite"))
        #expect(!inScope("/Users/someone/Library/Mobile Documents/.Trash/old.mov"))
        #expect(!inScope("/Users/someone/Documents2/film.mov"))
        #expect(!inScope("/Users/someone/Documents"))
        #expect(!inScope("/Users/other/Documents/film.mov"))
        #expect(!inScope("/Users/someone/Documents/.hidden/film.mov"))
        #expect(!inScope("/Users/someone/Documents/Photos Library.photoslibrary/originals/a.heic"))
    }

    @Test func outOfScopeIsNeverRead() {
        var reads = 0
        let result = ICloudDownloadPolicy.evaluate(
            URL(fileURLWithPath: "/Users/someone/Library/Caches/thing.bin"),
            home: URL(fileURLWithPath: "/Users/someone"),
            now: now,
            readState: { _ in reads += 1; return ready() }
        )
        #expect(result.decision == .outsideLargeFiles)
        #expect(reads == 0)
    }

    /// The real reader on a plain temporary file: not in iCloud, and the flags
    /// macOS sets on synced copies are absent.
    @Test func theReaderSeesALocalFileAsNotInICloud() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("purge-106-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent("local.bin")
        try Data(repeating: 7, count: 64 * 1024).write(to: file)
        let link = folder.appendingPathComponent("link.bin")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)

        let state = try #require(ICloudDownloadState.read(file))
        #expect(state.isRegularFile)
        #expect(!state.isUbiquitous)
        #expect(!state.isPurgeable)
        #expect(state.allocatedBytes > 0)
        #expect(ICloudDownloadPolicy.decision(for: state, now: Date()) == .notInICloud)

        // A link is never taken for the file it points at.
        let linkState = try #require(ICloudDownloadState.read(link))
        #expect(!linkState.isRegularFile)
        #expect(ICloudDownloadState.read(folder.appendingPathComponent("missing.bin")) == nil)
        #expect(!state.hasOtherLinks)

        // A second name for the same file: evicting one would empty both.
        let hardLink = folder.appendingPathComponent("second-name.bin")
        try fm.linkItem(at: file, to: hardLink)
        #expect(ICloudDownloadState.read(file)?.hasOtherLinks == true)
        #expect(ICloudDownloadState.read(hardLink)?.hasOtherLinks == true)
    }

    @Test func everyRefusalHasAReason() {
        let refusals: [ICloudDownloadDecision] = [
            .outsideLargeFiles, .notAFile, .notInICloud, .hasConflicts,
            .notUploaded, .notDownloaded, .keptOnThisMac, .changedRecently, .hasOtherLinks
        ]
        for decision in refusals {
            #expect(!decision.skipReasonKey.isEmpty)
        }
        #expect(ICloudDownloadDecision.removable.skipReasonKey.isEmpty)
    }
}

/// Made-up iCloud states keyed by path, and the evictions asked for. Eviction
/// drops a file's allocated bytes to zero, as iCloud does.
private final class FakeICloud: @unchecked Sendable {
    let lock = NSLock()
    private var states: [String: ICloudDownloadState] = [:]
    private var evictedPaths: [String] = []
    var failingPaths: Set<String> = []
    /// Paths whose allocated bytes stay put after eviction, as a slow one would.
    var slowPaths: Set<String> = []

    subscript(path: String) -> ICloudDownloadState? {
        get { lock.withLock { states[path] } }
        set { lock.withLock { states[path] = newValue } }
    }

    var evicted: [String] { lock.withLock { evictedPaths } }

    func evict(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        try lock.withLock {
            if failingPaths.contains(path) { throw CocoaError(.fileWriteUnknown) }
            evictedPaths.append(path)
            if !slowPaths.contains(path) {
                states[path]?.allocatedBytes = 0
                states[path]?.isDownloadedAndCurrent = false
            }
        }
    }

    /// `lsof -F pcn` output: nothing open unless a test says otherwise. Nil
    /// stands for a listing that couldn't be read.
    var openFilesListing: String? = ""

    func remover(home: URL, now: Date) -> ICloudDownloadRemover {
        ICloudDownloadRemover(
            home: home,
            readState: { self[$0.standardizedFileURL.path] },
            evict: { try self.evict($0) },
            listOpenFiles: { self.lock.withLock { self.openFilesListing } },
            now: { now },
            settleAttempts: 2,
            settleInterval: .milliseconds(1)
        )
    }
}

@Suite("Remove Download checks each file again before it acts (#106)")
struct ICloudDownloadRemoverTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func ready(_ bytes: Int64) -> ICloudDownloadState {
        ICloudDownloadState(
            isRegularFile: true, isUbiquitous: true, isUploaded: true, hasConflicts: false,
            isDownloadedAndCurrent: true, allocatedBytes: bytes, isPurgeable: true,
            modified: now.addingTimeInterval(-3600)
        )
    }

    @Test func removesReadyFilesAndMeasuresWhatTheyFreed() async {
        let cloud = FakeICloud()
        let a = "/Users/someone/Documents/a.mov"
        let b = "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/b.mov"
        cloud[a] = ready(300)
        cloud[b] = ready(700)

        let report = await cloud.remover(home: home, now: now).removeDownloads(at: [
            URL(fileURLWithPath: a), URL(fileURLWithPath: b)
        ])

        #expect(cloud.evicted == [a, b])
        #expect(report.removed == [
            ICloudDownloadRemoval(path: a, bytesFreed: 300),
            ICloudDownloadRemoval(path: b, bytesFreed: 700)
        ])
        #expect(report.skipped.isEmpty)
        #expect(report.bytesFreed == 1000)
    }

    /// The scan said yes, the file changed since: the remover reads it again and
    /// leaves it. This is the gate that matters.
    @Test func aFileThatStoppedBeingReadyIsLeftAlone() async {
        let cloud = FakeICloud()
        let edited = "/Users/someone/Documents/edited.mov"
        let pinned = "/Users/someone/Documents/pinned.mov"
        let conflicted = "/Users/someone/Documents/conflict.mov"
        var state = ready(100); state.isUploaded = false
        cloud[edited] = state
        state = ready(100); state.isPurgeable = false
        cloud[pinned] = state
        state = ready(100); state.hasConflicts = true
        cloud[conflicted] = state

        let report = await cloud.remover(home: home, now: now).removeDownloads(at: [
            URL(fileURLWithPath: edited), URL(fileURLWithPath: pinned), URL(fileURLWithPath: conflicted)
        ])

        #expect(cloud.evicted.isEmpty)
        #expect(report.removed.isEmpty)
        #expect(report.skipped == [
            ICloudDownloadSkip(path: edited, reasonKey: ICloudDownloadDecision.notUploaded.skipReasonKey),
            ICloudDownloadSkip(path: pinned, reasonKey: ICloudDownloadDecision.keptOnThisMac.skipReasonKey),
            ICloudDownloadSkip(path: conflicted, reasonKey: ICloudDownloadDecision.hasConflicts.skipReasonKey)
        ])
    }

    /// The first pass says yes, then the file is saved while the open-file
    /// listing runs. The check right before the eviction reads it again and
    /// leaves it.
    @Test func aFileSavedDuringTheRunIsLeftAlone() async {
        let path = "/Users/someone/Documents/edited-meanwhile.mov"
        let readyState = ready(100)
        let stale: ICloudDownloadState = {
            var state = readyState
            state.isUploaded = false
            return state
        }()
        final class Reads: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            var evicted: [String] = []
        }
        let reads = Reads()
        let remover = ICloudDownloadRemover(
            home: home,
            readState: { _ in
                reads.lock.withLock {
                    reads.count += 1
                    return reads.count == 1 ? readyState : stale
                }
            },
            evict: { url in reads.lock.withLock { reads.evicted.append(url.path) } },
            listOpenFiles: { "" },
            now: { now },
            settleAttempts: 1,
            settleInterval: .milliseconds(1)
        )

        let report = await remover.removeDownloads(at: [URL(fileURLWithPath: path)])

        #expect(reads.evicted.isEmpty)
        #expect(report.removed.isEmpty)
        #expect(report.skipped == [ICloudDownloadSkip(path: path, reasonKey: ICloudDownloadDecision.notUploaded.skipReasonKey)])
    }

    /// A file that can't be read after its eviction is settled at once: the
    /// wait for the space to show can't change it.
    @Test func anUnreadableFileDoesNotHoldUpTheRun() async {
        let cloud = FakeICloud()
        let gone = "/Users/someone/Documents/moved-elsewhere.mov"
        cloud[gone] = ready(500)
        cloud.slowPaths = [gone]
        let remover = ICloudDownloadRemover(
            home: home,
            readState: { url in
                let path = url.standardizedFileURL.path
                if cloud.evicted.contains(path) { return nil }
                return cloud[path]
            },
            evict: { try cloud.evict($0) },
            listOpenFiles: { "" },
            now: { now },
            settleAttempts: 6,
            settleInterval: .milliseconds(400)
        )

        let started = Date()
        let report = await remover.removeDownloads(at: [URL(fileURLWithPath: gone)])

        #expect(Date().timeIntervalSince(started) < 0.4)
        #expect(report.removed == [ICloudDownloadRemoval(path: gone, bytesFreed: 0)])
    }

    @Test func nothingOutsideLargeFilesFoldersIsEvicted() async {
        let cloud = FakeICloud()
        let outside = "/Users/someone/Library/Application Support/App/store.db"
        cloud[outside] = ready(100)

        let report = await cloud.remover(home: home, now: now).removeDownloads(at: [URL(fileURLWithPath: outside)])

        #expect(cloud.evicted.isEmpty)
        #expect(report.skipped.map(\.reasonKey) == [ICloudDownloadDecision.outsideLargeFiles.skipReasonKey])
    }

    @Test func aRefusedEvictionIsReportedAndTheRestGoOn() async {
        let cloud = FakeICloud()
        let refused = "/Users/someone/Documents/refused.mov"
        let fine = "/Users/someone/Documents/fine.mov"
        cloud[refused] = ready(100)
        cloud[fine] = ready(200)
        cloud.failingPaths = [refused]

        let report = await cloud.remover(home: home, now: now).removeDownloads(at: [
            URL(fileURLWithPath: refused), URL(fileURLWithPath: fine)
        ])

        #expect(report.removed == [ICloudDownloadRemoval(path: fine, bytesFreed: 200)])
        #expect(report.skipped == [ICloudDownloadSkip(path: refused, reasonKey: ICloudDownloadRemover.evictFailedReasonKey)])
    }

    /// A file an app has open is left alone, and the rest still go. When the
    /// listing of open files can't be read, nothing goes.
    @Test func aFileOpenInAnAppStays() async {
        let cloud = FakeICloud()
        let open = "/Users/someone/Documents/open.mov"
        let closed = "/Users/someone/Documents/closed.mov"
        cloud[open] = ready(100)
        cloud[closed] = ready(200)
        cloud.openFilesListing = "p4242\ncFinal Cut Pro\nn/Users/someone/Documents\nn\(open)\n"

        let report = await cloud.remover(home: home, now: now).removeDownloads(at: [
            URL(fileURLWithPath: open), URL(fileURLWithPath: closed)
        ])

        #expect(cloud.evicted == [closed])
        #expect(report.skipped == [ICloudDownloadSkip(path: open, reasonKey: ICloudDownloadRemover.openInAppReasonKey)])

        let unknown = FakeICloud()
        unknown[closed] = ready(200)
        unknown.openFilesListing = nil
        let blind = await unknown.remover(home: home, now: now).removeDownloads(at: [URL(fileURLWithPath: closed)])
        #expect(unknown.evicted.isEmpty)
        #expect(blind.skipped.map(\.reasonKey) == [ICloudDownloadRemover.openCheckUnavailableReasonKey])
    }

    @Test func eachFileIsEvictedOnce() async {
        let cloud = FakeICloud()
        let a = "/Users/someone/Documents/a.mov"
        cloud[a] = ready(100)

        _ = await cloud.remover(home: home, now: now).removeDownloads(at: [
            URL(fileURLWithPath: a), URL(fileURLWithPath: "/Users/someone/Documents/./a.mov")
        ])

        #expect(cloud.evicted == [a])
    }

    /// The figure is what the disk gave back, never what the scan expected: a
    /// copy still there after the wait counts as nothing freed, and so does a
    /// file that can't be read afterwards.
    @Test func freedSpaceIsMeasuredNotAssumed() async {
        let cloud = FakeICloud()
        let slow = "/Users/someone/Documents/slow.mov"
        let vanished = "/Users/someone/Documents/vanished.mov"
        cloud[slow] = ready(400)
        cloud[vanished] = ready(500)
        cloud.slowPaths = [slow, vanished]

        let remover = ICloudDownloadRemover(
            home: home,
            readState: { url in
                let path = url.standardizedFileURL.path
                // Gone once it has been evicted.
                if path == vanished, cloud.evicted.contains(vanished) { return nil }
                return cloud[path]
            },
            evict: { try cloud.evict($0) },
            listOpenFiles: { "" },
            now: { now },
            settleAttempts: 2,
            settleInterval: .milliseconds(1)
        )
        let report = await remover.removeDownloads(at: [URL(fileURLWithPath: slow), URL(fileURLWithPath: vanished)])

        #expect(report.removed.map(\.bytesFreed) == [0, 0])
    }
}

@Suite("Large Files offers iCloud Drive's own files for Remove Download only (#106)")
struct ICloudDriveRootTests {
    @Test func theRootIsICloudDrivesOwnFolder() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(
            LargeFileScanPolicy.iCloudDriveRoot(home: home).path
                == "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs"
        )
        #expect(LargeFileScanSummary.rootName(LargeFileScanPolicy.iCloudDriveRoot(home: home)) == "iCloud Drive")
        #expect(LargeFileScanSummary.rootName(home.appendingPathComponent("Documents")) == "Documents")
    }

    @Test func rowsInICloudDriveNameItTheWayFinderDoes() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let root = LargeFileScanPolicy.iCloudDriveRoot(home: home)
        #expect(LargeFile.iCloudDriveLocation(for: root, home: home) == "iCloud Drive")
        #expect(LargeFile.iCloudDriveLocation(for: root.appendingPathComponent("Projects/Film"), home: home) == "iCloud Drive/Projects/Film")
        #expect(LargeFile.iCloudDriveLocation(for: home.appendingPathComponent("Documents"), home: home) == nil)
    }

    /// The delete gate already refuses anything under `~/Library`. Pinned here
    /// so a later change to that rule can't quietly make iCloud Drive's own
    /// files trashable, which would remove them from every device.
    @Test func theTrashGateRefusesICloudDriveFiles() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("purge-106-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let root = LargeFileScanPolicy.iCloudDriveRoot(home: home)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("clip.mov")
        try Data(repeating: 1, count: 1024).write(to: file)

        #expect(!LargeFileScanPolicy.isEligibleForDeletion(file, home: home, isAppRunning: { _ in false }))
    }

    /// A file there that isn't in iCloud has nothing on offer, so it isn't
    /// listed. The same file in a home-folder walk is listed for the Trash.
    @Test func aWalkOfICloudDriveListsOnlyFilesWithADownloadToRemove() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("purge-106-walk-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let drive = base.appendingPathComponent("drive", isDirectory: true)
        let documents = base.appendingPathComponent("documents", isDirectory: true)
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: drive.appendingPathComponent("local.bin"))
        try Data(repeating: 1, count: 8192).write(to: documents.appendingPathComponent("local.bin"))

        let events = LargeFileScanner().scanEvents(
            minBytes: 1024,
            staleDays: 0,
            roots: [documents],
            virtualMachineRoots: [],
            iCloudDriveRoots: [drive],
            installedApps: [],
            isAppRunning: { _ in false },
            home: base,
            exclusions: ScanExclusions(keys: []),
            isExcluded: { _ in false }
        )
        var files: [LargeFile] = []
        for await event in events {
            if case .file(let file) = event { files.append(file) }
        }

        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.path.deletingLastPathComponent().lastPathComponent == "documents")
        #expect(file.canMoveToTrash)
        #expect(!file.canRemoveDownload)
    }
}

@Suite("Remove Download in the store and History (#106)")
@MainActor
struct RemoveDownloadStoreTests {
    private let now = Date()

    private func row(_ path: String, synced: Bool, removable: Bool, trashable: Bool = true) -> LargeFile {
        LargeFile(
            path: URL(fileURLWithPath: path),
            sizeBytes: 1_000_000,
            lastUsed: Date(timeIntervalSince1970: 0),
            category: .video,
            syncsWithICloud: synced,
            canMoveToTrash: trashable,
            canRemoveDownload: removable
        )
    }

    @Test func deleteAndRemoveDownloadEachCountTheirOwnRows() {
        let scans = FakeScans()
        scans.hasAccess = true
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let base = "/tmp/purge-106-\(UUID().uuidString)"
        let local = row("\(base)/Documents/local.mov", synced: false, removable: false)
        let synced = row("\(base)/Documents/synced.mov", synced: true, removable: true)
        let uploading = row("\(base)/Documents/uploading.mov", synced: true, removable: false)
        let driveOnly = row("\(base)/Library/Mobile Documents/com~apple~CloudDocs/drive.mov", synced: true, removable: true, trashable: false)
        store.largeFiles = [local, synced, uploading, driveOnly]
        store.setAllLargeFilesSelected(true, ids: store.largeFiles.map(\.id))

        #expect(store.hasRemovableDownloads)
        #expect(Set(store.selectedTrashableLargeFiles.map(\.id)) == [local.id, synced.id, uploading.id])
        #expect(store.selectedLargeFileCount == 3)
        #expect(Set(store.selectedRemovableDownloads.map(\.id)) == [synced.id, driveOnly.id])

        store.requestRemoveDownloads()
        let request = store.pendingRemoveDownload
        #expect(Set(request?.files.map(\.id) ?? []) == [synced.id, driveOnly.id])
        #expect(request?.localOnlyCount == 1)
        #expect(request?.notReadyCount == 1)
        #expect(request?.fromSelection == true)
        #expect(store.isReviewingOrCleaning)
        store.dismissRemoveDownloads()

        // A row's menu opens the review for that file alone.
        store.requestRemoveDownloads(for: synced)
        #expect(store.pendingRemoveDownload?.files.map(\.id) == [synced.id])
        #expect(store.pendingRemoveDownload?.fromSelection == false)
        #expect(store.pendingRemoveDownload?.localOnlyCount == 0)
        store.dismissRemoveDownloads()
        store.requestRemoveDownloads(for: local)
        #expect(store.pendingRemoveDownload == nil)
    }

    /// A file in iCloud Drive's own folder never reaches the Trash, by Delete
    /// Selected or by Delete extra copies: trashing it would remove it from
    /// every device. The store leaves it out before the deleter is asked, so it
    /// isn't even reported as skipped.
    @Test func iCloudDriveRowsNeverReachTheTrash() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("purge-106-trash-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let drive = LargeFileScanPolicy.iCloudDriveRoot(home: home)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        func make(_ url: URL) throws -> URL {
            try Data(repeating: 0x5A, count: 4096).write(to: url)
            return url
        }
        let local = try make(downloads.appendingPathComponent("local.bin"))
        let keeper = try make(downloads.appendingPathComponent("keeper.bin"))
        let inDrive = try make(drive.appendingPathComponent("drive.bin"))
        func large(_ url: URL, trashable: Bool) -> LargeFile {
            LargeFile(path: url, sizeBytes: 4096, lastUsed: Date(timeIntervalSince1970: 0), category: .other,
                      syncsWithICloud: !trashable, canMoveToTrash: trashable, canRemoveDownload: !trashable)
        }
        let localRow = large(local, trashable: true)
        let keeperRow = large(keeper, trashable: true)
        let driveRow = large(inDrive, trashable: false)

        let trash = FakeTrash()
        let scans = FakeScans()
        scans.hasAccess = true
        defer { scans.cleanUp() }
        let store = scans.makeStore(fileDeleter: FileDeleter(home: home, trash: trash.trash))
        let drivePath = inDrive.standardizedFileURL.path

        // Delete Selected with both rows ticked.
        store.largeFiles = [localRow, driveRow]
        store.setAllLargeFilesSelected(true, ids: [localRow.id, driveRow.id])
        store.presentLargeFileDeletionSheet()
        await store.confirmLargeFileDeletion()
        #expect(trash.trashedPaths == [local.standardizedFileURL.path])
        let report = try #require(store.lastDeletionReport)
        let skippedPaths = report.skippedItems.map(\.path)
        #expect(!skippedPaths.contains(drivePath), "skipped: \(skippedPaths), deleted: \(report.deletedItems.map(\.path))")
        #expect(store.largeFiles.map(\.id) == [driveRow.id])

        // Delete extra copies, with the iCloud Drive row as a copy to go.
        store.largeFiles = [keeperRow, driveRow]
        store.pendingDuplicateCleanup = DuplicateCleanupRequest(sets: [
            DuplicateCopySet(id: "set", copies: [keeperRow, driveRow], suggestedKeeperID: keeperRow.id)
        ])
        await store.confirmDuplicateCleanup(keeperByGroupID: [:])
        #expect(trash.trashedPaths == [local.standardizedFileURL.path])
        #expect(fm.fileExists(atPath: drivePath))
    }

    /// A row that can't go to the Trash takes no part in a duplicate set, so
    /// Delete extra copies never offers it.
    @Test func iCloudDriveRowsStayOutOfDuplicates() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("purge-106-dupes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x42, count: 64 * 1024)
        let urls = ["a.bin", "b.bin", "c.bin"].map { folder.appendingPathComponent($0) }
        for url in urls { try bytes.write(to: url) }
        let rows = urls.enumerated().map { index, url in
            LargeFile(path: url, sizeBytes: Int64(bytes.count), lastUsed: Date(timeIntervalSince1970: 0), category: .other,
                      syncsWithICloud: index == 2, canMoveToTrash: index != 2, canRemoveDownload: index == 2)
        }

        let scans = FakeScans()
        scans.hasAccess = true
        defer { scans.cleanUp() }
        scans.largeFileEvents = rows.map { .file($0) }
        let store = scans.makeStore()
        await store.scanLargeFiles()
        for _ in 0..<100 where store.largeFileDuplicates.isChecking || store.largeFileDuplicates.index.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }

        let index = store.largeFileDuplicates.index
        #expect(index.groups.count == 1)
        #expect(Set(index.groups.first?.fileIDs ?? []) == [rows[0].id, rows[1].id])
        #expect(index.groupIDByFileID[rows[2].id] == nil)
    }

    @Test func noButtonWithoutARemovableFile() {
        let scans = FakeScans()
        scans.hasAccess = true
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        store.largeFiles = [row("/tmp/purge-106-\(UUID().uuidString)/Documents/a.mov", synced: true, removable: false)]
        #expect(!store.hasRemovableDownloads)
    }

    @Test func confirmingRemovesTheRowsAndRecordsThemAsStillInICloud() async throws {
        let scans = FakeScans()
        scans.hasAccess = true
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let home = URL(fileURLWithPath: "/tmp/purge-106-home-\(UUID().uuidString)", isDirectory: true)
        let readyPath = home.appendingPathComponent("Documents/ready.mov").path
        let notReadyPath = home.appendingPathComponent("Documents/not-ready.mov").path
        let cloud = FakeICloud()
        cloud[readyPath] = ICloudDownloadState(
            isRegularFile: true, isUbiquitous: true, isUploaded: true, hasConflicts: false,
            isDownloadedAndCurrent: true, allocatedBytes: 900, isPurgeable: true,
            modified: now.addingTimeInterval(-3600)
        )
        var notReady = cloud[readyPath]!
        notReady.isUploaded = false
        cloud[notReadyPath] = notReady
        store.iCloudDownloadRemover = cloud.remover(home: home, now: now)

        let ready = row(readyPath, synced: true, removable: true)
        let stale = row(notReadyPath, synced: true, removable: true)
        store.largeFiles = [ready, stale]
        store.setAllLargeFilesSelected(true, ids: [ready.id, stale.id])
        store.requestRemoveDownloads()
        await store.confirmRemoveDownloads()

        #expect(cloud.evicted == [readyPath])
        #expect(store.largeFiles.map(\.id) == [stale.id])
        #expect(!store.isDeleting)
        let outcome = try #require(store.removeDownloadResult)
        let result = outcome.report
        #expect(result.removed == [ICloudDownloadRemoval(path: readyPath, bytesFreed: 900)])
        #expect(result.skipped.map(\.path) == [notReadyPath])
        // The skipped row is still listed and still ticked, but the sheet lists
        // it already, so it isn't counted as another file still selected.
        #expect(store.largeFileSelection.ids == [stale.id])
        #expect(outcome.stillSelectedCount == 0)

        let entry = try #require(CleanupHistoryStore.shared.archive.entries.first)
        #expect(entry.kind == .iCloudDownloadsRemoved)
        #expect(entry.deletedItems.map(\.path) == [readyPath])
        #expect(entry.bytesMovedToTrash == 0)
        #expect(entry.trashedItems.isEmpty)
        #expect(entry.permanentlyDeletedItems.isEmpty)
        #expect(entry.bytesFreedByRemovedDownloads == 900)
        #expect(entry.skippedItems.map(\.reason) == [ICloudDownloadDecision.notUploaded.skipReasonKey])
    }

    /// The note accounts for every selected file left alone, by reason.
    @Test func mixedSelectionsAreSpelledOut() {
        #expect(RemoveDownloadConfirmSheet.leftOutNote(localOnly: 0, notReady: 0) == nil)
        #expect(RemoveDownloadConfirmSheet.leftOutNote(localOnly: 3, notReady: 0)
            == "3 other selected files aren't in iCloud, so they stay.")
        #expect(RemoveDownloadConfirmSheet.leftOutNote(localOnly: 0, notReady: 1)
            == "1 other selected file can't be kept only in iCloud right now, so it stays.")
        #expect(RemoveDownloadConfirmSheet.leftOutNote(localOnly: 3, notReady: 2)
            == "5 other selected files stay: 3 aren't in iCloud, 2 can't be kept only there right now.")
    }

    /// The iCloud chip shows exactly the files Keep Only in iCloud can act on,
    /// falls back to All once none are left, and is never restored at launch,
    /// before a scan has found anything.
    @Test func theICloudChipShowsOnlyFilesItCanActOn() {
        let base = "/tmp/purge-106-\(UUID().uuidString)"
        let files = [
            row("\(base)/Documents/local.mov", synced: false, removable: false),
            row("\(base)/Documents/synced.mov", synced: true, removable: true),
            row("\(base)/Documents/uploading.mov", synced: true, removable: false),
        ]
        let shown = LargeFileCategoryFilter.visibleIndices(
            in: files, rawValue: LargeFileCategoryFilter.iCloud, query: "", duplicates: .empty
        )
        #expect(shown == [1])
        #expect(LargeFileCategoryFilter.isICloudActive(rawValue: LargeFileCategoryFilter.iCloud, files: files))

        let noneLeft = [files[0], files[2]]
        #expect(!LargeFileCategoryFilter.isICloudActive(rawValue: LargeFileCategoryFilter.iCloud, files: noneLeft))
        #expect(LargeFileCategoryFilter.visibleIndices(
            in: noneLeft, rawValue: LargeFileCategoryFilter.iCloud, query: "", duplicates: .empty
        ) == [0, 1])

        let suite = ThrowawayDefaults()
        suite.defaults.set(LargeFileCategoryFilter.iCloud, forKey: LargeFileFilterDefaults.legacyCategoryKey)
        LargeFileFilterDefaults.removeLegacyCategory(userDefaults: suite.defaults)
        #expect(suite.defaults.object(forKey: LargeFileFilterDefaults.legacyCategoryKey) == nil)
    }

    @Test func historySaysTheFilesAreStillInICloud() throws {
        let entry = CleanupHistoryEntry(
            trigger: .manual,
            bytesMovedToTrash: 0,
            deletedItems: [
                CleanupHistoryDeletedItemDTO(path: "/Users/someone/Documents/a.mov", sizeBytes: 2_000_000_000, movedToTrash: false),
                CleanupHistoryDeletedItemDTO(path: "/Users/someone/Documents/b.mov", sizeBytes: 1_000_000_000, movedToTrash: false)
            ],
            kind: .iCloudDownloadsRemoved
        )
        let row = CleanupHistorySummaryRow(entry: entry)
        #expect(row.primaryFigure == formatBytes(3_000_000_000))
        #expect(row.detailText == "2 files, still in iCloud Drive")
        #expect(!CleanupLedgerStore.HistorySnapshot.importsIntoLedger(.iCloudDownloadsRemoved))

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(CleanupHistoryEntry.self, from: data)
        #expect(decoded.kind == .iCloudDownloadsRemoved)
    }
}

/// Remove Download is reached from one place. Clean Safe Items, scheduled cleans
/// and every other clean never call it, so the only route is a user picking
/// rows and confirming.
@Suite("Only the confirmed review reaches the eviction (#106)")
struct ICloudDownloadSourceAuditTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func evictionIsCalledFromOnePlace() throws {
        let appRoot = Self.repoRoot.appendingPathComponent("purge", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var evictCallers: [String] = []
        var removerCallers: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let relative = String(url.path.dropFirst(Self.repoRoot.path.count + 1))
            for line in source.split(separator: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                if code.contains("evictUbiquitousItem(") { evictCallers.append(relative) }
                if code.contains(".removeDownloads(at:") { removerCallers.append(relative) }
            }
        }
        #expect(evictCallers == ["purge/Services/ICloudDownloadRemover.swift"])
        #expect(removerCallers == ["purge/Services/PurgeStore.swift"])

        let store = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("purge/Services/PurgeStore.swift"),
            encoding: .utf8
        )
        let call = try #require(store.range(of: ".removeDownloads(at:"))
        let enclosing = try #require(store[..<call.lowerBound].range(of: "func ", options: .backwards))
        let signature = store[enclosing.lowerBound...].prefix(while: { $0 != "(" })
        #expect(signature == "func confirmRemoveDownloads")
    }
}

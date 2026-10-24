import Foundation
import Testing
@testable import Purge

/// A home folder the user moved and replaced with a link
/// (`~/Documents -> /Volumes/Data/Documents`) is walked at its target, and its
/// rows carry their real path (#273). Every fixture is a throwaway home in the
/// temporary folder, never the user's own.
@Suite("Large Files walks a home folder that is a link (#273)")
struct LargeFileSymlinkedRootTests {
    // MARK: - Fixtures

    /// A temporary folder holding a home and a stand-in for `/Volumes`.
    private struct Fixture {
        let base: URL
        var home: URL { base.appendingPathComponent("home", isDirectory: true) }
        var volumes: URL { base.appendingPathComponent("Volumes", isDirectory: true) }

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("purge-linked-root-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent("home", isDirectory: true), withIntermediateDirectories: true
            )
        }

        /// Writes a file under `base`, making its folders.
        @discardableResult
        func write(_ relative: String, bytes: Int = 4096) throws -> URL {
            let file = base.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x01, count: bytes).write(to: file)
            return file
        }

        func folder(_ relative: String) throws -> URL {
            let url = base.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        /// Puts a link at `home/<name>` that leads to `base/<target>`.
        @discardableResult
        func link(_ name: String, to target: String) throws -> URL {
            let link = home.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: base.appendingPathComponent(target, isDirectory: true)
            )
            return link
        }

        func root(_ name: String) -> URL { home.appendingPathComponent(name, isDirectory: true) }

        /// The path the scan gives a file under `base`.
        func listedPath(_ relative: String) -> String {
            base.appendingPathComponent(relative).standardizedFileURL.path
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    private struct Run {
        var files: [LargeFile] = []
        var summary: LargeFileScanSummary?
        var paths: [String] { files.map(\.id) }
    }

    private func scan(_ fixture: Fixture, roots: [String]) async -> Run {
        let stream = LargeFileScanner().scanEvents(
            minBytes: 1024,
            staleDays: 0,
            roots: roots.map(fixture.root),
            virtualMachineRoots: [],
            iCloudDriveRoots: [],
            installedApps: [],
            isAppRunning: { _ in false },
            home: fixture.home,
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

    // MARK: - The walk

    /// The bug: the enumerator does not follow a link at the root, so a moved
    /// Documents folder read as "couldn't be read" and listed nothing.
    @Test
    func linkedRootIsWalkedAtItsTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("home/Moved/Documents/film.mov")
        try fixture.write("home/Moved/Documents/Archive/backup.zip")
        try fixture.link("Documents", to: "home/Moved/Documents")

        let run = await scan(fixture, roots: ["Documents"])
        let summary = try #require(run.summary)

        #expect(Set(run.paths) == [
            fixture.listedPath("home/Moved/Documents/film.mov"),
            fixture.listedPath("home/Moved/Documents/Archive/backup.zip"),
        ])
        #expect(run.files.allSatisfy { $0.canMoveToTrash })
        #expect(summary.unreadableRoots.isEmpty)
        #expect(summary.checkedRoots.map(\.lastPathComponent) == ["Documents"])
    }

    /// Rows carry the real path, and the gate passes them: it reads the link
    /// again and finds the file inside the folder the root leads to.
    @Test
    func rowsUnderALinkedRootPassTheDeleteGate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("home/Moved/Downloads/installer.dmg")
        try fixture.link("Downloads", to: "home/Moved/Downloads")

        let run = await scan(fixture, roots: ["Downloads"])

        let file = try #require(run.files.first)
        #expect(file.id == fixture.listedPath("home/Moved/Downloads/installer.dmg"))
        #expect(LargeFileScanPolicy.isEligibleForDeletion(file.path, home: fixture.home))
    }

    /// Only the root's own link is followed. A link inside the folder still is
    /// not, so nothing outside the user's folders is listed through it.
    @Test
    func linksBelowTheRootAreNotFollowed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("home/Moved/Documents/kept.mov")
        try fixture.write("home/Outside/secret.db")
        try FileManager.default.createSymbolicLink(
            at: fixture.base.appendingPathComponent("home/Moved/Documents/Shortcut"),
            withDestinationURL: fixture.base.appendingPathComponent("home/Outside", isDirectory: true)
        )
        try fixture.link("Documents", to: "home/Moved/Documents")

        let run = await scan(fixture, roots: ["Documents"])

        #expect(run.paths == [fixture.listedPath("home/Moved/Documents/kept.mov")])
    }

    /// Two roots that lead into one folder walk it once: the same file listed
    /// twice would show up as its own duplicate.
    @Test
    func aRootInsideAnotherRootsFolderIsWalkedOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("home/Documents/Desktop/notes.mov")
        try fixture.write("home/Documents/report.pdf")
        try fixture.link("Desktop", to: "home/Documents/Desktop")

        let run = await scan(fixture, roots: ["Documents", "Desktop"])
        let summary = try #require(run.summary)

        #expect(run.paths.sorted() == [
            fixture.listedPath("home/Documents/Desktop/notes.mov"),
            fixture.listedPath("home/Documents/report.pdf"),
        ])
        #expect(summary.unreadableRoots.isEmpty)
        #expect(summary.checkedRoots.map(\.lastPathComponent) == ["Documents", "Desktop"])
    }

    /// On the default volume `documents` is `Documents`, so a link spelled
    /// in other capitals still leads into the folder another root walks
    /// (the 2026-10-22 entry in `docs/safety-notes.md`).
    @Test(.enabled(if: Self.temporaryVolumeIgnoresCase, "needs a case-insensitive volume"))
    func aRootLinkedIntoAnotherRootInOtherCapitalsIsWalkedOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("home/Documents/Desktop/notes.mov")
        try fixture.link("Desktop", to: "home/documents/Desktop")

        let run = await scan(fixture, roots: ["Documents", "Desktop"])

        #expect(run.paths == [fixture.listedPath("home/Documents/Desktop/notes.mov")])
        #expect(run.summary?.unreadableRoots.isEmpty == true)
    }

    static var temporaryVolumeIgnoresCase: Bool {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames == false
    }

    @Test
    func twoRootsLinkedToOneFolderListEachFileOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("home/Moved/Everything/clip.mov")
        try fixture.link("Movies", to: "home/Moved/Everything")
        try fixture.link("Music", to: "home/Moved/Everything")

        let run = await scan(fixture, roots: ["Movies", "Music"])

        #expect(run.paths == [fixture.listedPath("home/Moved/Everything/clip.mov")])
        #expect(run.summary?.checkedRoots.map(\.lastPathComponent) == ["Movies", "Music"])
    }

    /// A link into `~/Library`, here a cloud provider's folder, is not walked.
    /// Trashing a file there removes it from every device, and the summary
    /// says why the folder was left out instead of "couldn't be opened".
    @Test
    func aLinkIntoLibraryIsNotWalkedAndTheSummarySaysWhere() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let cloudFile = try fixture.write("home/Library/CloudStorage/OneDrive-Personal/Documents/deck.key")
        try fixture.link("Documents", to: "home/Library/CloudStorage/OneDrive-Personal/Documents")

        let run = await scan(fixture, roots: ["Documents"])
        let summary = try #require(run.summary)

        #expect(run.files.isEmpty)
        let unreadable = try #require(summary.unreadableRoots.first)
        #expect(unreadable.name == "Documents")
        #expect(unreadable.reason.contains("OneDrive-Personal/Documents"))
        #expect(summary.checkedRoots.isEmpty)
        // Neither spelling of the file passes the gate.
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(cloudFile, home: fixture.home))
        let throughLink = fixture.root("Documents").appendingPathComponent("deck.key")
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(throughLink, home: fixture.home))
    }

    // MARK: - Where a link may lead

    @Test
    func aRootThatIsNotALinkIsWalkedWhereItIs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let documents = try fixture.folder("home/Documents")

        let walked = LargeFileScanPolicy.walkedFolder(for: documents, home: fixture.home, volumes: fixture.volumes)
        #expect(walked == documents)
    }

    @Test(arguments: [
        "Volumes/Data/Documents",
        "Volumes/Data",
        "home/Moved/Documents",
    ])
    func aLinkToAFolderTheUserCouldHaveMovedItToIsFollowed(target: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = try fixture.folder(target)
        let link = try fixture.link("Documents", to: target)

        let walked = LargeFileScanPolicy.walkedFolder(for: link, home: fixture.home, volumes: fixture.volumes)
        #expect(walked?.path == folder.resolvingSymlinksInPath().path)
    }

    @Test(arguments: [
        // `/Volumes` itself, and places that are neither in the home folder nor on a volume.
        "Volumes",
        "Elsewhere/Documents",
        // The home folder and folders above it would walk `~/Library`.
        "home",
        "",
        // Folders whose files the gate refuses anyway.
        "home/Library/CloudStorage/Dropbox",
        "home/Library",
        "Volumes/Data/Library/Documents",
        "home/.hidden/Documents",
        "Volumes/Data/Mac.pvm",
        "home/Code/node_modules",
    ])
    func aLinkToAnywhereElseIsNotFollowed(target: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder(target)
        let link = try fixture.link("Documents", to: target)

        #expect(LargeFileScanPolicy.walkedFolder(for: link, home: fixture.home, volumes: fixture.volumes) == nil)
    }

    @Test
    func aLinkToAFileIsNotFollowed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("home/Moved/Documents.zip")
        let link = fixture.home.appendingPathComponent("Documents")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: fixture.base.appendingPathComponent("home/Moved/Documents.zip")
        )

        #expect(LargeFileScanPolicy.walkedFolder(for: link, home: fixture.home, volumes: fixture.volumes) == nil)
    }

    // MARK: - The delete gate

    /// A file reached through a link inside a root is not the root's file. The
    /// scan never lists it, and the gate refuses it too, by its real folder.
    @Test
    func theGateRefusesAFileReachedThroughALinkBelowTheRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("home/Downloads")
        try fixture.write("home/Outside/secret.db")
        try FileManager.default.createSymbolicLink(
            at: fixture.base.appendingPathComponent("home/Downloads/Shortcut"),
            withDestinationURL: fixture.base.appendingPathComponent("home/Outside", isDirectory: true)
        )

        let throughLink = fixture.base.appendingPathComponent("home/Downloads/Shortcut/secret.db")
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(throughLink, home: fixture.home))
    }

    /// The gate reads the link again at delete time: a file under a folder
    /// the root no longer leads to is refused.
    @Test
    func theGateFollowsTheLinkAsItIsAtDeleteTime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("home/Moved/Movies/trip.mov")
        try fixture.folder("home/Other/Movies")
        let link = try fixture.link("Movies", to: "home/Moved/Movies")

        let run = await scan(fixture, roots: ["Movies"])
        let file = try #require(run.files.first)
        #expect(LargeFileScanPolicy.isEligibleForDeletion(file.path, home: fixture.home))

        try FileManager.default.removeItem(at: link)
        try fixture.link("Movies", to: "home/Other/Movies")
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(file.path, home: fixture.home))
    }

    /// Inside a Safari download bundle only the whole bundle goes, in a linked
    /// Downloads folder as in a plain one.
    @Test
    func aFileInsideASafariDownloadInALinkedDownloadsIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("home/Moved/Downloads/Movie.mov.download/Info.plist", bytes: 16)
        let inner = try fixture.write("home/Moved/Downloads/Movie.mov.download/Movie.mov")
        try fixture.link("Downloads", to: "home/Moved/Downloads")

        let bundle = inner.deletingLastPathComponent()
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(inner, home: fixture.home))
        #expect(LargeFileScanPolicy.isEligibleForDeletion(bundle, home: fixture.home, isAppRunning: { _ in false }))
    }

    // MARK: - Model stores

    /// A model store inside a linked folder is skipped by the walk whichever
    /// way its path is spelled, so its weights are never listed one by one.
    @Test
    func aModelStoreNamedByItsRealPathCountsAsInsideTheWalk() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let hub = try fixture.folder("home/Moved/Documents/hf/hub")
        try fixture.link("Documents", to: "home/Moved/Documents")

        let roots = AIModelScanPolicy.rootsInsideLargeFileScan(
            home: fixture.home, environment: ["HF_HUB_CACHE": hub.path]
        ).map(\.path)
        #expect(roots.contains(hub.standardizedFileURL.path))
    }

    // MARK: - Duplicates

    /// Two rows can still name one file when a folder on the way is a link.
    /// They are one file, not two copies: keeping one and trashing the other
    /// would trash the only copy.
    @Test
    func twoPathsToOneFileAreNeverADuplicatePair() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let real = try fixture.write("home/Moved/Documents/film.mov", bytes: 96 * 1024)
        try fixture.link("Documents", to: "home/Moved/Documents")
        let throughLink = fixture.root("Documents").appendingPathComponent("film.mov")

        let rows = [real, throughLink].map { url in
            LargeFile(path: url, sizeBytes: 96 * 1024, lastUsed: Date(), category: .video)
        }
        #expect(Set(rows.map(\.id)).count == 2)

        let index = await DuplicateFileDetector().findDuplicates(in: rows)
        #expect(index.isEmpty)
    }

    /// A real copy beside them is still found. Only the second name is
    /// dropped, so the group is the file and its copy, each named once.
    @Test
    func aRealCopyIsStillFoundBesideASecondName() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = Data((0..<(96 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let original = fixture.base.appendingPathComponent("home/Moved/Documents/film.mov")
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try payload.write(to: original)
        let copy = fixture.base.appendingPathComponent("home/Moved/Documents/film copy.mov")
        try payload.write(to: copy)
        try fixture.link("Documents", to: "home/Moved/Documents")
        let throughLink = fixture.root("Documents").appendingPathComponent("film.mov")

        let rows = [original, throughLink, copy].map { url in
            LargeFile(path: url, sizeBytes: Int64(payload.count), lastUsed: Date(), category: .video)
        }
        let index = await DuplicateFileDetector().findDuplicates(in: rows)

        let group = try #require(index.groups.first)
        #expect(index.groups.count == 1)
        #expect(Set(group.fileIDs) == [rows[0].id, rows[2].id])
    }
}

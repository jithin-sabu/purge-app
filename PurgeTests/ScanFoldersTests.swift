import Foundation
import Testing
@testable import Purge

/// The folders the user adds for Large Files and Developer Projects to walk
/// too (#318), and what Large Files does with them. Every fixture is a
/// throwaway home and a stand-in for `/Volumes` in the temporary folder, never
/// the user's own folders or drives, and every saved list goes to a temporary
/// handoff folder.
@Suite("Folders the user adds for Large Files and Developer Projects (#318)")
struct ScanFoldersTests {
    // MARK: - Fixtures

    private struct Fixture {
        let base: URL
        var home: URL { base.appendingPathComponent("home", isDirectory: true) }
        var volumes: URL { base.appendingPathComponent("Volumes", isDirectory: true) }

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("purge-scan-folders-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
        }

        @discardableResult
        func folder(_ relative: String) throws -> URL {
            let url = base.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        @discardableResult
        func write(_ relative: String, bytes: Int = 4096) throws -> URL {
            let file = base.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x01, count: bytes).write(to: file)
            return file
        }

        func url(_ relative: String) -> URL {
            base.appendingPathComponent(relative, isDirectory: true)
        }

        func refusal(_ relative: String, otherRoots: [URL] = [], isLocalDisk: Bool = true) -> AppFolders.Refusal? {
            ScanFolders.refusal(
                forPicked: url(relative), home: home, otherRoots: otherRoots,
                volumes: volumes, isLocalDisk: { _ in isLocalDisk }
            )
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    // MARK: - What may be added

    @Test("A whole drive may be added, though the uninstaller's list still refuses one")
    func wholeDriveIsAllowed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/T7/Media")

        #expect(fixture.refusal("Volumes/T7") == nil)
        #expect(AppFolders.refusal(
            forPicked: fixture.url("Volumes/T7"), home: fixture.home, otherRoots: [],
            volumes: fixture.volumes, isLocalDisk: { _ in true }
        ) == .tooBroad)
    }

    @Test(
        "A drive that holds a Mac or a Time Machine backup is refused, and so is a folder in it",
        arguments: ["System", "Users", "Backups.backupdb"]
    )
    func driveWithAWholeDiskIsRefused(marker: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/Old/\(marker)")
        try fixture.folder("Volumes/Old/Stuff")

        #expect(fixture.refusal("Volumes/Old") == .holdsWholeDisk)
        #expect(fixture.refusal("Volumes/Old/Stuff") == .holdsWholeDisk)
    }

    @Test("A network share, cloud drive or macFUSE mount is refused")
    func notLocalIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/Share/Projects")

        #expect(fixture.refusal("Volumes/Share/Projects", isLocalDisk: false) == .notOnWritableLocalDisk)
        #expect(fixture.refusal("Volumes/Share", isLocalDisk: false) == .notOnWritableLocalDisk)
    }

    @Test("Links, Library, hidden folders, bundles and the home folder are refused")
    func narrowRules() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/T7/Real")
        try fixture.folder("Volumes/T7/Library/Caches")
        try fixture.folder("Volumes/T7/.hidden")
        try fixture.folder("Volumes/T7/Tool.app/Contents")
        try FileManager.default.createSymbolicLink(
            at: fixture.url("Volumes/T7/Linked"), withDestinationURL: fixture.url("Volumes/T7/Real")
        )

        #expect(fixture.refusal("Volumes/T7/Linked") == .throughLink)
        #expect(fixture.refusal("Volumes/T7/Library/Caches") == .insideLibraryOrBundle)
        #expect(fixture.refusal("Volumes/T7/.hidden") == .insideLibraryOrBundle)
        #expect(fixture.refusal("Volumes/T7/Tool.app") == .insideLibraryOrBundle)
        #expect(fixture.refusal("home") == .tooBroad)
        #expect(fixture.refusal("Volumes/T7/Missing") == .notAFolder)
    }

    @Test("A folder Large Files already walks, or one inside it, adds nothing")
    func insideALargeFilesRootIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let big = try fixture.folder("home/Documents/Big")
        let work = try fixture.folder("home/Work")

        try withTemporaryHandoffRoot {
            AppFolders.$volumes.withValue(fixture.volumes) {
                #expect(ScanFolders.add(big, home: fixture.home).refusal == .alreadyIncluded)
                #expect(ScanFolders.add(fixture.url("home/Documents"), home: fixture.home).refusal == .alreadyIncluded)
                // A home folder Large Files doesn't walk may be added.
                #expect(ScanFolders.add(work, home: fixture.home).refusal == nil)
            }
        }
    }

    // MARK: - The saved list

    @Test("Added folders are saved, listed and removed, apart from the uninstaller's list")
    func roundTrip() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.folder("Volumes/T7")
        let inside = try fixture.folder("Volumes/T7/Media")

        try withTemporaryHandoffRoot {
            AppFolders.$volumes.withValue(fixture.volumes) {
                let added = ScanFolders.add(drive, home: fixture.home)
                #expect(added.refusal == nil)
                #expect(!added.saveFailed)
                #expect(ScanFolders.pickedFolders().map(\.path) == [drive.standardizedFileURL.path])
                #expect(ScanFolders.roots(home: fixture.home).map(\.path) == [drive.standardizedFileURL.path])
                #expect(AppFolders.pickedFolders().isEmpty)

                // A folder on a drive already on the list adds nothing.
                #expect(ScanFolders.add(inside, home: fixture.home).refusal == .alreadyIncluded)
                #expect(ScanFolders.pickedFolders().count == 1)

                #expect(ScanFolders.remove(path: drive.standardizedFileURL.path))
                #expect(ScanFolders.pickedFolders().isEmpty)
                #expect(ScanFolders.roots(home: fixture.home).isEmpty)
            }
        }
    }

    @Test("A folder on an unplugged drive stays saved, reads Not connected, and is not walked")
    func unpluggedDrive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let media = try fixture.folder("Volumes/T7/Media")

        try withTemporaryHandoffRoot {
            try AppFolders.$volumes.withValue(fixture.volumes) {
                #expect(ScanFolders.add(media, home: fixture.home).refusal == nil)
                try FileManager.default.removeItem(at: fixture.url("Volumes/T7"))

                let entries = ScanFolders.entries(home: fixture.home)
                #expect(entries.count == 1)
                #expect(entries.first?.isDisconnected == true)
                #expect(entries.first?.isAvailable == false)
                #expect(ScanFolders.roots(home: fixture.home).isEmpty)
                #expect(ScanFolders.pickedFolders().count == 1)
            }
        }
    }

    @Test("Clean Safe Items' check matches a saved folder by its spelling, connected or not")
    func savedFolderCheck() {
        let snapshot = ScanFolders.Snapshot(walked: [], saved: ["/Volumes/T7/Code"])
        ScanFolders.$snapshotOverride.withValue(snapshot) {
            #expect(ScanFolders.isInsideSavedFolder("/Volumes/T7/Code/app/node_modules"))
            #expect(ScanFolders.isInsideSavedFolder("/Volumes/T7/Code"))
            #expect(!ScanFolders.isInsideSavedFolder("/Volumes/T7/Code2/app/node_modules"))
            #expect(!ScanFolders.isInsideSavedFolder("/Users/someone/Code/app/node_modules"))
        }
    }

    // MARK: - Large Files

    @Test("The Large Files gate takes a file under an added folder, and only while it is added")
    func largeFilesGate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.folder("Volumes/T7/Media")
        let file = try fixture.write("Volumes/T7/Media/film.mov")
        let outside = try fixture.write("Volumes/T7/Other/film.mov")
        // One level down: a Library right in the picked folder would make it
        // look like a copy of a home folder, which the list refuses.
        let inLibrary = try fixture.write("Volumes/T7/Media/Old/Library/film.mov")
        func passes(_ url: URL, roots: [URL]? = nil, isLocalDisk: Bool = true) -> Bool {
            LargeFileScanPolicy.isEligibleForDeletion(
                url, home: fixture.home, volumes: fixture.volumes,
                isLocalDisk: { _ in isLocalDisk }, addedRoots: roots
            )
        }

        #expect(passes(file, roots: [drive]))
        #expect(!passes(file, roots: []))
        #expect(!passes(outside, roots: [drive]))
        #expect(!passes(inLibrary, roots: [drive]))
        // A share mounted inside the folder reads as not local.
        #expect(!passes(file, roots: [drive], isLocalDisk: false))

        // Read from the saved list when the caller passes none.
        try withTemporaryHandoffRoot {
            AppFolders.$volumes.withValue(fixture.volumes) {
                #expect(!passes(file))
                #expect(ScanFolders.add(drive, home: fixture.home, volumes: fixture.volumes).refusal == nil)
                #expect(passes(file))
                #expect(ScanFolders.remove(path: drive.standardizedFileURL.path))
                #expect(!passes(file))
            }
        }
    }

    @Test("A VM bundle on an added drive is one item the gate takes while it is not in use")
    func virtualMachineOnADrive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.folder("Volumes/T7")
        let vm = try fixture.folder("Volumes/T7/VMs/Linux.utm")
        try fixture.write("Volumes/T7/VMs/Linux.utm/Data/disk.img")

        #expect(LargeFileScanPolicy.isEligibleForDeletion(
            vm, home: fixture.home, volumes: fixture.volumes, isLocalDisk: { _ in true },
            isAppRunning: { _ in false }, addedRoots: [drive]
        ))
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(
            vm.appendingPathComponent("Data/disk.img"), home: fixture.home, volumes: fixture.volumes,
            isLocalDisk: { _ in true }, isAppRunning: { _ in false }, addedRoots: [drive]
        ))
    }

    @Test("The scan walks an added folder and names one that isn't connected")
    func scanWalksAddedFolders() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.folder("Volumes/T7")
        let file = try fixture.write("Volumes/T7/Media/film.mov")
        let gone = fixture.url("Volumes/Old/Media")

        let stream = LargeFileScanner().scanEvents(
            minBytes: 1024,
            staleDays: 0,
            roots: [],
            virtualMachineRoots: [],
            iCloudDriveRoots: [],
            addedFolders: [
                ScanFolders.Entry(path: drive.standardizedFileURL.path, refusal: nil),
                ScanFolders.Entry(path: gone.standardizedFileURL.path, refusal: .notAFolder)
            ],
            installedApps: [],
            isAppRunning: { _ in false },
            home: fixture.home,
            exclusions: ScanExclusions(keys: []),
            isExcluded: { _ in false }
        )
        var paths: [String] = []
        var summary: LargeFileScanSummary?
        for await event in stream {
            switch event {
            case .file(let found): paths.append(found.id)
            case .finished(let finished): summary = finished
            }
        }

        #expect(paths.contains(file.standardizedFileURL.path))
        let unread = try #require(summary).unreadableRoots
        #expect(unread.map(\.path.path) == [gone.standardizedFileURL.path])
        let root = try #require(unread.first)
        #expect(root.isDisconnected)
        #expect(LargeFileScanSummaryCard.unreadableText(root) == "Media isn\u{2019}t connected. Connect its drive and scan again.")
    }

    // MARK: - Review fixes

    @Test("A folder another sync service keeps is refused, and so is one inside it")
    func otherSyncServicesAreRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("home/Dropbox/.dropbox", bytes: 1)
        try fixture.folder("home/Dropbox/Photos")
        try fixture.write("Volumes/T7/Shared/.stfolder", bytes: 1)

        #expect(fixture.refusal("home/Dropbox") == .syncs)
        #expect(fixture.refusal("home/Dropbox/Photos") == .syncs)
        #expect(fixture.refusal("Volumes/T7/Shared") == .syncs)
    }

    @Test(
        "An APFS Time Machine drive is refused, for these folders and the uninstaller's",
        arguments: ["backup_manifest.plist", "2026-11-01-120000.backup", "2026-11-17-090000.inprogress"]
    )
    func timeMachineDriveIsRefused(marker: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        if marker.hasSuffix(".plist") {
            try fixture.write("Volumes/Backups/\(marker)", bytes: 1)
        } else {
            try fixture.folder("Volumes/Backups/\(marker)")
        }
        try fixture.folder("Volumes/Backups/Applications")

        #expect(fixture.refusal("Volumes/Backups") == .holdsWholeDisk)
        let drives = AppFolders.driveRoots(volumes: fixture.volumes, isLocalDisk: { _ in true })
        #expect(drives.isEmpty)
    }

    @Test("Inside an added drive, copies of a Mac, a home folder or a backup and synced folders are skipped and refused")
    func nothingFromCopiesOrSyncedFolders() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.folder("Volumes/T7")
        try fixture.folder("Volumes/T7/Archive/OldMac/System")
        let macCopy = try fixture.write("Volumes/T7/Archive/OldMac/Users/bob/Movies/clip.mov")
        try fixture.folder("Volumes/T7/Archive/OldHome/Library")
        let homeCopy = try fixture.write("Volumes/T7/Archive/OldHome/Documents/report.zip")
        try fixture.write("Volumes/T7/Dropbox/.dropbox", bytes: 1)
        let synced = try fixture.write("Volumes/T7/Dropbox/video.mov")
        try fixture.folder("Volumes/T7/2026-11-01-120000.backup/Data")
        let backup = try fixture.write("Volumes/T7/2026-11-01-120000.backup/Data/disk.img")
        // A Unity project keeps a Library folder of its own and is walked.
        try fixture.folder("Volumes/T7/Games/Racer/Library")
        try fixture.folder("Volumes/T7/Games/Racer/Assets")
        let unity = try fixture.write("Volumes/T7/Games/Racer/Assets/intro.mov")
        let plain = try fixture.write("Volumes/T7/Media/film.mov")

        let stream = LargeFileScanner().scanEvents(
            minBytes: 1024, staleDays: 0, roots: [], virtualMachineRoots: [], iCloudDriveRoots: [],
            addedFolders: [ScanFolders.Entry(path: drive.standardizedFileURL.path, refusal: nil)],
            installedApps: [], isAppRunning: { _ in false }, home: fixture.home,
            exclusions: ScanExclusions(keys: []), isExcluded: { _ in false }
        )
        var paths: Set<String> = []
        for await event in stream {
            if case .file(let file) = event { paths.insert(file.id) }
        }
        func passes(_ url: URL) -> Bool {
            LargeFileScanPolicy.isEligibleForDeletion(
                url, home: fixture.home, volumes: fixture.volumes, isLocalDisk: { _ in true }, addedRoots: [drive]
            )
        }

        for blocked in [macCopy, homeCopy, synced, backup] {
            #expect(!paths.contains(blocked.standardizedFileURL.path), "\(blocked.path) was listed")
            #expect(!passes(blocked), "\(blocked.path) passed the gate")
        }
        for allowed in [unity, plain] {
            #expect(paths.contains(allowed.standardizedFileURL.path), "\(allowed.path) was not listed")
            #expect(passes(allowed), "\(allowed.path) did not pass the gate")
        }
    }

    @Test("The off-limits rule reads the same from names as from disk")
    func offLimitsFromNames() {
        #expect(ScanFolders.isOffLimits(name: "OldMac", childNames: ["System", "Applications"]))
        #expect(ScanFolders.isOffLimits(name: "OldHome", childNames: ["Library", "Desktop"]))
        #expect(ScanFolders.isOffLimits(name: "Shared", childNames: [".sync", "notes"]))
        #expect(ScanFolders.isOffLimits(name: "2026-11-01-120000.backup", childNames: []))
        #expect(!ScanFolders.isOffLimits(name: "Racer", childNames: ["Library", "Assets", "ProjectSettings"]))
        #expect(!ScanFolders.isOffLimits(name: "Code", childNames: ["website", "api"]))
    }

    @Test("Only a folder added outside the home folder changes how projects clean")
    func homeFoldersKeepHomeRules() {
        let home = "/Users/someone"
        let snapshot = ScanFolders.Snapshot(
            walked: ["/Users/someone/Developer", "/Volumes/T7"],
            saved: ["/Users/someone/Developer", "/Volumes/T7", "/Volumes/Archive"]
        )
        ScanFolders.$snapshotOverride.withValue(snapshot) {
            #expect(ScanFolders.addedRootOutsideHome(holding: "/Users/someone/Developer/app", home: home) == nil)
            #expect(ScanFolders.addedRootOutsideHome(holding: "/Volumes/T7/Code/app", home: home) == "/Volumes/T7")
            #expect(!ScanFolders.isInsideSavedFolder("/Users/someone/Developer/app/node_modules", home: home))
            #expect(ScanFolders.isInsideSavedFolder("/Volumes/T7/Code/app/node_modules", home: home))
            #expect(ScanFolders.isInsideSavedFolder("/Volumes/Archive/blog/node_modules", home: home))
        }
    }

    @Test("An added folder that is itself an Ollama store stays out of Large Files")
    func addedFolderThatIsAModelStore() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let store = URL(fileURLWithPath: "/Volumes/T7/Models", isDirectory: true)
        let inside = AIModelScanPolicy.rootsInsideLargeFileScan(
            home: home, environment: ["OLLAMA_MODELS": store.path], addedRoots: [store]
        )
        #expect(inside.map(\.path).contains(store.path))
    }

    @Test("An added folder that goes away before the walk reaches it is named as not connected")
    func driveGoneBeforeTheWalk() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gone = fixture.url("Volumes/T7")
        let stream = LargeFileScanner().scanEvents(
            minBytes: 1024, staleDays: 0, roots: [], virtualMachineRoots: [], iCloudDriveRoots: [],
            addedFolders: [ScanFolders.Entry(path: gone.standardizedFileURL.path, refusal: nil)],
            installedApps: [], isAppRunning: { _ in false }, home: fixture.home,
            exclusions: ScanExclusions(keys: []), isExcluded: { _ in false }
        )
        var summary: LargeFileScanSummary?
        for await event in stream {
            if case .finished(let finished) = event { summary = finished }
        }
        let root = try #require(summary?.unreadableRoots.first)
        #expect(root.isDisconnected)
        #expect(root.path.standardizedFileURL.path == gone.standardizedFileURL.path)
    }

    @Test("A limited scan judges only the added folders inside home")
    func limitedScanReadsOnlyHomeFolders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let work = try fixture.folder("home/Work")
        let drive = try fixture.folder("Volumes/T7")
        try withTemporaryHandoffRoot {
            AppFolders.$volumes.withValue(fixture.volumes) {
                #expect(ScanFolders.add(work, home: fixture.home).refusal == nil)
                #expect(ScanFolders.add(drive, home: fixture.home).refusal == nil)
                let homePath = fixture.home.standardizedFileURL.path
                let judged = ScanFolders.entries(home: fixture.home, including: { PathContainment.isInside($0, homePath) })
                #expect(judged.map(\.path) == [work.standardizedFileURL.path])
            }
        }
    }

    @Test("A limited scan never follows a home folder's link out of home")
    func limitedScanDoesNotFollowLinksOut() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/T7/Documents")
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent("Documents"),
            withDestinationURL: fixture.url("Volumes/T7/Documents")
        )
        func roots(insideHomeOnly: Bool) -> [String] {
            ScanFolders.fixedRoots(
                home: fixture.home, volumes: fixture.volumes, isLocalDisk: { _ in true }, insideHomeOnly: insideHomeOnly
            ).map(\.path)
        }
        #expect(roots(insideHomeOnly: false).contains { $0.hasSuffix("/Volumes/T7/Documents") })
        #expect(!roots(insideHomeOnly: true).contains { $0.hasSuffix("/Volumes/T7/Documents") })
    }

    @Test("A limited scan stops a chain of links before it leaves home, and keeps one that stays")
    func limitedScanStopsLinkChains() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fm = FileManager.default
        try fixture.folder("Volumes/T7/Documents")
        try fixture.folder("home/Real/Movies")
        // ~/Documents -> ~/Linked -> the drive: the first hop stays in home.
        try fm.createSymbolicLink(at: fixture.url("home/Linked"), withDestinationURL: fixture.url("Volumes/T7/Documents"))
        try fm.createSymbolicLink(atPath: fixture.home.appendingPathComponent("Documents").path, withDestinationPath: "Linked")
        // ~/Movies -> ~/Real/Movies stays in home all the way.
        try fm.createSymbolicLink(atPath: fixture.home.appendingPathComponent("Movies").path, withDestinationPath: "Real/Movies")

        let home = fixture.home
        #expect(ProtectedLocations.resolvedStayingInside(home.appendingPathComponent("Documents").path, root: home) == nil)
        #expect(ProtectedLocations.resolvedStayingInside(home.appendingPathComponent("Movies").path, root: home) != nil)
        let roots = ScanFolders.fixedRoots(
            home: home, volumes: fixture.volumes, isLocalDisk: { _ in true }, insideHomeOnly: true
        ).map(\.path)
        #expect(!roots.contains { $0.hasSuffix("/Volumes/T7/Documents") })
        #expect(roots.contains { $0.hasSuffix("/home/Real/Movies") })
    }

    @Test("In a limited scan, a saved home folder that became a link out of home is refused without reading the drive")
    func limitedScanRefusesSavedFolderLinkedOut() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let work = try fixture.folder("home/Work")
        try fixture.folder("Volumes/T7/Code")
        try withTemporaryHandoffRoot {
            try AppFolders.$volumes.withValue(fixture.volumes) {
                #expect(ScanFolders.add(work, home: fixture.home).refusal == nil)
                try FileManager.default.removeItem(at: work)
                try FileManager.default.createSymbolicLink(at: work, withDestinationURL: fixture.url("Volumes/T7/Code"))
                let homePath = fixture.home.standardizedFileURL.path
                // `isLocalDisk` is asked only once `refusal` reaches the disk
                // checks; for this folder it must never be asked at all.
                var askedAbout: [String] = []
                let entries = ScanFolders.entries(
                    home: fixture.home,
                    isLocalDisk: { url in askedAbout.append(url.path); return true },
                    including: { PathContainment.isInside($0, homePath) },
                    insideHomeOnly: true
                )
                #expect(entries.map(\.refusal) == [.throughLink])
                #expect(!askedAbout.contains { $0.contains("/Volumes/T7") })
            }
        }
    }

    @Test("A drive-top link, such as the startup disk under /Volumes, stays refused when whole drives are allowed")
    func driveTopLinkIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Disk/System")
        try fixture.folder("Disk/Users")
        try FileManager.default.createSymbolicLink(at: fixture.url("Volumes/Startup"), withDestinationURL: fixture.url("Disk"))

        #expect(fixture.refusal("Volumes/Startup") == .throughLink)
    }

    @Test("The real delete path takes a file under an added folder, and refuses it once the folder is removed")
    func fileDeleterFollowsTheSavedList() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.folder("Volumes/T7")
        let film = try fixture.write("Volumes/T7/Media/film.mov")
        let trash = FakeTrash()
        let deleter = FileDeleter(home: fixture.home, trash: trash.trash)

        try await withTemporaryHandoffRoot {
            try await AppFolders.$volumes.withValue(fixture.volumes) {
                #expect(ScanFolders.add(drive, home: fixture.home).refusal == nil)
                let first = try await deleter.deleteUserSelectedFiles(at: [film])
                #expect(first.deletedItems.map(\.path) == [film.path])

                #expect(ScanFolders.remove(path: drive.standardizedFileURL.path))
                let second = try await deleter.deleteUserSelectedFiles(at: [film])
                #expect(second.deletedItems.isEmpty)
                #expect(second.skippedItems.map(\.path) == [film.path])
            }
        }
        #expect(trash.trashedPaths == [film.standardizedFileURL.path])
    }

    @Test("A file named like a backup doesn't make a drive Time Machine, and a dated backup folder anywhere is refused")
    func timeMachineNamesNeedTheDatedFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Volumes/T7/notes.backup", bytes: 1)
        try fixture.folder("Volumes/T7/Applications")
        try fixture.folder("Volumes/T7/Archive/2026-11-01-120000.backup/Data")

        #expect(fixture.refusal("Volumes/T7") == nil)
        #expect(AppFolders.driveRoots(volumes: fixture.volumes, isLocalDisk: { _ in true }).count == 1)
        #expect(fixture.refusal("Volumes/T7/Archive/2026-11-01-120000.backup/Data") == .holdsWholeDisk)
        #expect(!AppFolders.isTimeMachineBackupName("notes.backup"))
        #expect(AppFolders.isTimeMachineBackupName("2026-11-01-120000.backup"))
    }

    @Test("A VM bundle that holds a copied Mac is neither listed nor taken by the gate")
    func vmBundleHoldingACopiedMac() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.folder("Volumes/T7")
        let copy = try fixture.folder("Volumes/T7/Copy.utm")
        try fixture.folder("Volumes/T7/Copy.utm/System")
        try fixture.write("Volumes/T7/Copy.utm/Users/bob/disk.img")

        let stream = LargeFileScanner().scanEvents(
            minBytes: 1024, staleDays: 0, roots: [], virtualMachineRoots: [], iCloudDriveRoots: [],
            addedFolders: [ScanFolders.Entry(path: drive.standardizedFileURL.path, refusal: nil)],
            installedApps: [], isAppRunning: { _ in false }, home: fixture.home,
            exclusions: ScanExclusions(keys: []), isExcluded: { _ in false }
        )
        var paths: [String] = []
        for await event in stream {
            if case .file(let file) = event { paths.append(file.id) }
        }
        #expect(!paths.contains { $0.contains("Copy.utm") })
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(
            copy, home: fixture.home, volumes: fixture.volumes, isLocalDisk: { _ in true },
            isAppRunning: { _ in false }, addedRoots: [drive]
        ))
    }
}

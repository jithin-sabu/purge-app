import Foundation
import Testing
@testable import Purge

/// The folders the App Uninstaller lists apps from (#99): each attached drive's
/// `Applications` folder, and folders the user adds. Every fixture is a
/// throwaway home and a stand-in for `/Volumes` in the temporary folder, never
/// the user's own folders or drives.
@Suite("App folders on drives and folders the user adds (#99)")
struct AppFoldersTests {
    // MARK: - Fixtures

    private struct Fixture {
        let base: URL
        var home: URL { base.appendingPathComponent("home", isDirectory: true) }
        var volumes: URL { base.appendingPathComponent("Volumes", isDirectory: true) }

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("purge-app-folders-\(UUID().uuidString)", isDirectory: true)
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
        func link(_ relative: String, to target: String) throws -> URL {
            let link = base.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: base.appendingPathComponent(target, isDirectory: true)
            )
            return link
        }

        func url(_ relative: String) -> URL {
            base.appendingPathComponent(relative, isDirectory: true)
        }

        func refusal(_ relative: String, otherRoots: [URL] = []) -> AppFolders.Refusal? {
            AppFolders.refusal(
                forPicked: url(relative), home: home, otherRoots: otherRoots,
                volumes: volumes, isLocalDisk: { _ in true }
            )
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    // MARK: - Drives

    @Test("A drive's top-level Applications folder is listed")
    func driveApplicationsFolderIsListed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/SSD/Applications/Luminar Neo.app")

        let roots = AppFolders.driveRoots(volumes: fixture.volumes, isLocalDisk: { _ in true })
        #expect(roots.map(\.lastPathComponent) == ["Applications"])
        #expect(roots.first?.deletingLastPathComponent().lastPathComponent == "SSD")
    }

    @Test("A drive with no Applications folder adds nothing")
    func driveWithoutApplicationsAddsNothing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/SSD/Projects")

        #expect(AppFolders.driveRoots(volumes: fixture.volumes, isLocalDisk: { _ in true }).isEmpty)
    }

    @Test("The startup disk's link, a linked Applications and hidden entries are skipped")
    func linksAndHiddenEntriesAreSkipped() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // `/Volumes/Macintosh HD` is a link to `/`.
        try fixture.folder("boot/Applications")
        try fixture.link("Volumes/Macintosh HD", to: "boot")
        // An installer image's `Applications -> /Applications`.
        try fixture.folder("Volumes/Installer")
        try fixture.link("Volumes/Installer/Applications", to: "boot/Applications")
        try fixture.folder("Volumes/.timemachine/Applications")

        #expect(AppFolders.driveRoots(volumes: fixture.volumes, isLocalDisk: { _ in true }).isEmpty)
    }

    @Test("A network share or cloud drive is skipped")
    func networkDriveIsSkipped() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/NAS/Applications")

        #expect(AppFolders.driveRoots(volumes: fixture.volumes, isLocalDisk: { _ in false }).isEmpty)
    }

    @Test("Another Mac's system or data volume, and a Time Machine drive, are skipped")
    func wholeMacVolumesAreSkipped() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/Old Mac/Applications")
        try fixture.folder("Volumes/Old Mac/System")
        try fixture.folder("Volumes/Old Mac - Data/Applications")
        try fixture.folder("Volumes/Old Mac - Data/Users")
        try fixture.folder("Volumes/Backup/Applications")
        try fixture.folder("Volumes/Backup/Backups.backupdb")

        #expect(AppFolders.driveRoots(volumes: fixture.volumes, isLocalDisk: { _ in true }).isEmpty)
    }

    @Test("The real startup disk passes the local disk check and a missing path does not")
    func localDiskCheck() {
        #expect(AppFolders.isOnLocalDisk(FileManager.default.temporaryDirectory))
        #expect(!AppFolders.isOnLocalDisk(URL(fileURLWithPath: "/no/such/folder-\(UUID().uuidString)")))
    }

    // MARK: - Folders the user adds

    @Test("A folder in the home folder or on a drive can be added")
    func ordinaryFoldersCanBeAdded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("home/Apps")
        try fixture.folder("Volumes/SSD/Apps/Photo")

        #expect(fixture.refusal("home/Apps") == nil)
        #expect(fixture.refusal("Volumes/SSD/Apps") == nil)
        #expect(fixture.refusal("Volumes/SSD/Apps/Photo") == nil)
    }

    @Test("A missing folder is refused")
    func missingFolderIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(fixture.refusal("Volumes/SSD/Apps") == .notAFolder)
    }

    @Test("The home folder, a folder above it, and a whole drive are refused")
    func broadFoldersAreRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/SSD")

        #expect(fixture.refusal("home") == .tooBroad)
        #expect(fixture.refusal("") == .tooBroad)
        #expect(fixture.refusal("Volumes/SSD") == .tooBroad)
    }

    @Test("A folder outside the home folder and the drives is refused")
    func outsideFolderIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("elsewhere/Apps")
        #expect(fixture.refusal("elsewhere/Apps") == .outsideHomeAndDrives)
    }

    @Test("Library, hidden folders, and folders inside an app or package are refused")
    func libraryAndBundlesAreRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("home/Library/Apps")
        try fixture.folder("home/library/Apps")
        try fixture.folder("home/.apps")
        try fixture.folder("Volumes/SSD/Tool.app/Contents")
        try fixture.folder("Volumes/SSD/Kit.framework/Apps")

        #expect(fixture.refusal("home/Library/Apps") == .insideLibraryOrBundle)
        #expect(fixture.refusal("home/library/Apps") == .insideLibraryOrBundle)
        #expect(fixture.refusal("home/.apps") == .insideLibraryOrBundle)
        #expect(fixture.refusal("Volumes/SSD/Tool.app/Contents") == .insideLibraryOrBundle)
        #expect(fixture.refusal("Volumes/SSD/Kit.framework/Apps") == .insideLibraryOrBundle)
    }

    @Test("A link, or a folder reached through one, is refused")
    func linksAreRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/SSD/Apps/Photo")
        try fixture.link("home/Apps", to: "Volumes/SSD/Apps")

        #expect(fixture.refusal("home/Apps") == .throughLink)
        #expect(fixture.refusal("home/Apps/Photo") == .throughLink)
    }

    @Test("A folder on a network share is refused")
    func networkFolderIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/NAS/Apps")
        let refusal = AppFolders.refusal(
            forPicked: fixture.url("Volumes/NAS/Apps"), home: fixture.home, otherRoots: [],
            volumes: fixture.volumes, isLocalDisk: { _ in false }
        )
        #expect(refusal == .notOnWritableLocalDisk)
    }

    @Test("A copy of a Mac or of a home folder is refused")
    func wholeDiskCopiesAreRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/SSD/Old Mac/Users")
        try fixture.folder("Volumes/SSD/Old Home/Library")

        #expect(fixture.refusal("Volumes/SSD/Old Mac") == .holdsWholeDisk)
        #expect(fixture.refusal("Volumes/SSD/Old Home") == .holdsWholeDisk)
    }

    @Test("A folder already listed, inside one, or holding one is refused")
    func overlappingFoldersAreRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/SSD/Applications/Adobe")
        let driveRoot = fixture.url("Volumes/SSD/Applications")
        try fixture.folder("home/Apps/Sub")
        let picked = fixture.url("home/Apps/Sub")

        #expect(fixture.refusal("Volumes/SSD/Applications", otherRoots: [driveRoot]) == .alreadyIncluded)
        #expect(fixture.refusal("Volumes/SSD/Applications/Adobe", otherRoots: [driveRoot]) == .alreadyIncluded)
        #expect(fixture.refusal("home/Apps", otherRoots: [picked]) == .holdsAnotherFolder)
    }

    @Test("A folder inside another Mac's volume or an old home folder is refused")
    func foldersInsideWholeDiskCopiesAreRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/Old Mac - Data/Users")
        try fixture.folder("Volumes/Old Mac - Data/Applications")
        try fixture.folder("Volumes/SSD/Old Home/Library")
        try fixture.folder("Volumes/SSD/Old Home/Desktop")
        try fixture.folder("Volumes/SSD/Old Mac/Users/bob/Apps")
        // A drive's own top folder may hold a `Library` of the user's.
        try fixture.folder("Volumes/Work/Library")
        try fixture.folder("Volumes/Work/Apps")

        #expect(fixture.refusal("Volumes/Old Mac - Data/Applications") == .holdsWholeDisk)
        #expect(fixture.refusal("Volumes/SSD/Old Home/Desktop") == .holdsWholeDisk)
        #expect(fixture.refusal("Volumes/SSD/Old Mac/Users/bob/Apps") == .holdsWholeDisk)
        #expect(fixture.refusal("Volumes/Work/Apps") == nil)
    }

    @Test("The walk of an added folder skips build output, git checkouts and Mac copies")
    func addedFolderWalkSkipsBuildsCheckoutsAndCopies() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = try fixture.folder("Volumes/SSD/Apps")
        try fixture.folder("Volumes/SSD/Apps/Tool.app")
        try fixture.folder("Volumes/SSD/Apps/Vendor/Suite.app")
        try fixture.folder("Volumes/SSD/Apps/game/build/macos/Build/Products/Release/Game.app")
        try fixture.folder("Volumes/SSD/Apps/editor/src-tauri/target/release/bundle/macos/Editor.app")
        try fixture.folder("Volumes/SSD/Apps/repo/.git")
        try fixture.folder("Volumes/SSD/Apps/repo/Repo.app")
        try fixture.folder("Volumes/SSD/Apps/Old Macs/MacBook/System")
        try fixture.folder("Volumes/SSD/Apps/Old Macs/MacBook/Applications/Safari.app")

        let listed = try #require(AppFolders.appBundleURLs(in: root, home: fixture.home))
            .map { $0.lastPathComponent }.sorted()
        #expect(listed == ["Suite.app", "Tool.app"])

        // The gate agrees with the list.
        let roots = [root.standardizedFileURL.path]
        for skipped in ["game/build/macos/Build/Products/Release/Game.app", "repo/Repo.app",
                        "Old Macs/MacBook/Applications/Safari.app"] {
            let path = root.appendingPathComponent(skipped).standardizedFileURL.path
            #expect(AppFolders.folderDepth(ofAppAtPath: path, roots: roots, home: fixture.home) == nil, "\(skipped)")
        }
        let kept = root.appendingPathComponent("Vendor/Suite.app").standardizedFileURL.path
        #expect(AppFolders.folderDepth(ofAppAtPath: kept, roots: roots, home: fixture.home) == 1)
    }

    @Test("The built-in Applications folders are walked as before")
    func builtInFoldersKeepTheirWalk() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let applications = try fixture.folder("home/Applications/build/Tool.app")
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = applications.appendingPathComponent("build/Tool.app").standardizedFileURL.path
        #expect(AppFolders.folderDepth(ofAppAtPath: path, roots: [applications.standardizedFileURL.path], home: fixture.home) == 1)
    }

    // MARK: - Saved list    // MARK: - Saved list

    @Test("Added folders are saved, listed, and removed")
    func addedFoldersRoundTrip() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let apps = try fixture.folder("home/Apps")
        try fixture.folder("home/Apps/Tool.app")

        try withTemporaryHandoffRoot {
            try AppFolders.$volumes.withValue(fixture.volumes) {
                let added = AppFolders.add(apps, home: fixture.home)
                #expect(added.refusal == nil)
                #expect(!added.saveFailed)
                #expect(AppFolders.pickedFolders().map(\.path) == [apps.standardizedFileURL.path])
                #expect(AppFolders.roots(home: fixture.home).map(\.path).contains(apps.standardizedFileURL.path))

                // Adding it twice is refused, and nothing is saved twice.
                #expect(AppFolders.add(apps, home: fixture.home).refusal == .alreadyIncluded)
                #expect(AppFolders.pickedFolders().count == 1)

                #expect(AppFolders.remove(path: apps.standardizedFileURL.path))
                #expect(AppFolders.pickedFolders().isEmpty)
                #expect(!AppFolders.roots(home: fixture.home).map(\.path).contains(apps.standardizedFileURL.path))
            }
        }
    }

    @Test("An added folder that is gone, or became a link, drops out of the roots but stays saved")
    func missingAddedFolderDropsOut() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let apps = try fixture.folder("Volumes/SSD/Apps")
        try fixture.folder("Volumes/Other/Apps")

        try withTemporaryHandoffRoot {
            try AppFolders.$volumes.withValue(fixture.volumes) {
                #expect(AppFolders.add(apps, home: fixture.home).refusal == nil)
                try FileManager.default.removeItem(at: apps)
                #expect(!AppFolders.roots(home: fixture.home).map(\.path).contains(apps.path))
                #expect(AppFolders.pickedFolders().count == 1)

                try fixture.link("Volumes/SSD/Apps", to: "Volumes/Other/Apps")
                #expect(!AppFolders.roots(home: fixture.home).map(\.path).contains(apps.path))
            }
        }
    }

    @Test("Settings lists the built-in folders, each drive's, and added ones, unplugged ones marked")
    func settingsListing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.folder("Volumes/SSD/Applications")
        let added = try fixture.folder("Volumes/SSD/Apps")
        let gone = try fixture.folder("Volumes/Old/Apps")

        try withTemporaryHandoffRoot {
            try AppFolders.$volumes.withValue(fixture.volumes) {
                #expect(AppFolders.add(added, home: fixture.home).refusal == nil)
                #expect(AppFolders.add(gone, home: fixture.home).refusal == nil)
                try FileManager.default.removeItem(at: fixture.url("Volumes/Old"))

                let rows = AppFolderListing.load(home: fixture.home).rows
                #expect(rows.map(\.kind) == [.builtIn, .builtIn, .drive, .added, .added])
                #expect(rows[2].path == fixture.url("Volumes/SSD/Applications").path)
                #expect(rows[3].isAvailable)
                #expect(!rows[4].isAvailable)
            }
        }
    }

    @Test("The roots start with the two built-in Applications folders")
    func builtInRootsComeFirst() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try withTemporaryHandoffRoot {
            AppFolders.$volumes.withValue(fixture.volumes) {
                let roots = AppFolders.roots(home: fixture.home).map(\.path)
                #expect(roots == ["/Applications", fixture.home.appendingPathComponent("Applications").path])
            }
        }
    }
}

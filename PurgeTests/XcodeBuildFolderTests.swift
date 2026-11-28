import Foundation
import Testing
@testable import Purge

/// Xcode build folders outside DerivedData (#480). Every fixture is a
/// throwaway home folder, laid out as `xcodebuild -derivedDataPath` lays one out.
private enum Fixture {
    typealias Policy = XcodeBuildFolderScanPolicy

    static func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-test-480-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    static func infoPlist(workspace: String?, lastAccessed: Date? = Date(timeIntervalSince1970: 1_793_000_000)) throws -> Data {
        var plist: [String: Any] = [:]
        if let workspace { plist["WorkspacePath"] = workspace }
        if let lastAccessed { plist["LastAccessedDate"] = lastAccessed }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// A build folder as Xcode 26 leaves one, at `relative` below `home`.
    @discardableResult
    static func buildFolder(
        _ home: URL,
        _ relative: String,
        workspace: String? = nil,
        extraFiles: [String] = []
    ) throws -> URL {
        let folder = home.appendingPathComponent(relative, isDirectory: true)
        let fm = FileManager.default
        for name in ["Build/Products/Debug", "Logs/Build", "ModuleCache.noindex", "Index.noindex", "SourcePackages"] {
            try fm.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("Build/Products/Debug/App"))
        let workspacePath = workspace ?? home.appendingPathComponent("Developer/App/App.xcodeproj").path
        try infoPlist(workspace: workspacePath).write(to: folder.appendingPathComponent("info.plist"))
        for name in extraFiles {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        return folder.standardizedFileURL
    }

    static let noOpenFiles: OpenFileCheck.Lister = { "" }

    static func walk(_ home: URL, access: ScanAccess = .full) -> [String] {
        Policy.buildFolders(
            in: Policy.searchRoots(home: home), home: home, access: access, lister: noOpenFiles
        ).map(\.path)
    }
}

@Suite("Xcode build folders outside DerivedData (#480)")
struct XcodeBuildFolderTests {
    typealias Policy = XcodeBuildFolderScanPolicy

    // MARK: The mark

    @Test("a folder xcodebuild made is known by what is in it, whatever its name")
    func markReadsXcodesInfoPlist() throws {
        let home = try Fixture.makeHome()
        let folder = try Fixture.buildFolder(home, "Developer/dd-460.noindex")
        let mark = try #require(Policy.mark(at: folder.path))
        #expect(mark.workspacePath == home.appendingPathComponent("Developer/App/App.xcodeproj").path)
        #expect(mark.lastAccessed == Date(timeIntervalSince1970: 1_793_000_000))
    }

    @Test("a folder holding anything Xcode doesn't make is not a build folder")
    func extraFileRemovesTheMark() throws {
        let home = try Fixture.makeHome()
        let withLog = try Fixture.buildFolder(home, "Developer/a", extraFiles: ["test.log"])
        let withResult = try Fixture.buildFolder(home, "Developer/b")
        try FileManager.default.createDirectory(
            at: withResult.appendingPathComponent("run.xcresult"), withIntermediateDirectories: true
        )
        #expect(Policy.mark(at: withLog.path) == nil)
        #expect(Policy.mark(at: withResult.path) == nil)
        // Finder's own file doesn't count.
        let withDSStore = try Fixture.buildFolder(home, "Developer/c", extraFiles: [".DS_Store"])
        #expect(Policy.mark(at: withDSStore.path) != nil)
    }

    @Test("no info.plist, no WorkspacePath, a relative path or no Build folder means no mark")
    func incompleteFoldersHaveNoMark() throws {
        let home = try Fixture.makeHome()
        let fm = FileManager.default

        let noPlist = try Fixture.buildFolder(home, "Developer/no-plist")
        try fm.removeItem(at: noPlist.appendingPathComponent("info.plist"))
        #expect(Policy.mark(at: noPlist.path) == nil)

        let noWorkspace = try Fixture.buildFolder(home, "Developer/no-workspace")
        try Fixture.infoPlist(workspace: nil).write(to: noWorkspace.appendingPathComponent("info.plist"))
        #expect(Policy.mark(at: noWorkspace.path) == nil)

        let relative = try Fixture.buildFolder(home, "Developer/relative")
        try Fixture.infoPlist(workspace: "App.xcodeproj").write(to: relative.appendingPathComponent("info.plist"))
        #expect(Policy.mark(at: relative.path) == nil)

        let noBuild = try Fixture.buildFolder(home, "Developer/no-build")
        try fm.removeItem(at: noBuild.appendingPathComponent("Build"))
        #expect(Policy.mark(at: noBuild.path) == nil)

        let noLogs = try Fixture.buildFolder(home, "Developer/no-logs")
        try fm.removeItem(at: noLogs.appendingPathComponent("Logs"))
        #expect(Policy.mark(at: noLogs.path) == nil)

        let notAPlist = try Fixture.buildFolder(home, "Developer/not-a-plist")
        try Data("hello".utf8).write(to: notAPlist.appendingPathComponent("info.plist"))
        #expect(Policy.mark(at: notAPlist.path) == nil)
    }

    @Test("a link, or a folder whose info.plist or Build is a link, has no mark")
    func linksHaveNoMark() throws {
        let home = try Fixture.makeHome()
        let fm = FileManager.default
        let real = try Fixture.buildFolder(home, "Developer/real")

        let linkedFolder = home.appendingPathComponent("Developer/linked")
        try fm.createSymbolicLink(at: linkedFolder, withDestinationURL: real)
        #expect(Policy.mark(at: linkedFolder.path) == nil)

        let linkedPlist = try Fixture.buildFolder(home, "Developer/linked-plist")
        try fm.removeItem(at: linkedPlist.appendingPathComponent("info.plist"))
        try fm.createSymbolicLink(
            at: linkedPlist.appendingPathComponent("info.plist"),
            withDestinationURL: real.appendingPathComponent("info.plist")
        )
        #expect(Policy.mark(at: linkedPlist.path) == nil)

        let linkedBuild = try Fixture.buildFolder(home, "Developer/linked-build")
        try fm.removeItem(at: linkedBuild.appendingPathComponent("Build"))
        try fm.createSymbolicLink(
            at: linkedBuild.appendingPathComponent("Build"),
            withDestinationURL: real.appendingPathComponent("Build")
        )
        #expect(Policy.mark(at: linkedBuild.path) == nil)
    }

    @Test("an oversized info.plist is not Xcode's")
    func oversizedPlistIsRefused() throws {
        let home = try Fixture.makeHome()
        let folder = try Fixture.buildFolder(home, "Developer/big")
        let plist: [String: Any] = [
            "WorkspacePath": "/Users/someone/App.xcodeproj",
            "Padding": String(repeating: "x", count: Int(Policy.maxInfoPlistBytes))
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("info.plist"))
        #expect(Policy.mark(at: folder.path) == nil)
    }

    // MARK: evaluate's rule

    @Test("only a marked folder below home and outside Library is allowed")
    func whitelistNeedsHomeAndMark() throws {
        let home = try Fixture.makeHome()
        let developer = try Fixture.buildFolder(home, "Developer/dd-1.noindex")
        let library = try Fixture.buildFolder(home, "Library/Caches/dd")
        let plain = home.appendingPathComponent("Developer/notes")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        #expect(Policy.isWhitelistedPath(developer.path, home: home.path))
        #expect(!Policy.isWhitelistedPath(library.path, home: home.path))
        #expect(!Policy.isWhitelistedPath(plain.path, home: home.path))
        #expect(!Policy.isWhitelistedPath(home.path, home: home.path))
        // A marked folder in another home is not this home's.
        let other = try Fixture.makeHome()
        #expect(!Policy.isWhitelistedPath(developer.path, home: other.path))
    }

    @Test("a folder reached through a link into Library is refused")
    func linkIntoLibraryIsRefused() throws {
        let home = try Fixture.makeHome()
        try Fixture.buildFolder(home, "Library/Developer/Builds/dd")
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("Developer"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: home.appendingPathComponent("Developer/Builds"),
            withDestinationURL: home.appendingPathComponent("Library/Developer/Builds")
        )
        let throughLink = home.appendingPathComponent("Developer/Builds/dd").path
        #expect(Policy.mark(at: throughLink) != nil)
        #expect(!Policy.isWhitelistedPath(throughLink, home: home.path))
    }

    @Test("evaluate never allows a marked folder outside the real home")
    func evaluateRefusesTemporaryFolders() throws {
        let home = try Fixture.makeHome()
        let folder = try Fixture.buildFolder(home, "Developer/dd")
        #expect(DeletionSafetyPolicy.evaluate(folder) != .allow)
    }

    // MARK: Discovery

    @Test("the walk finds build folders in project folders, nested ones and DerivedData's projects")
    func walkFindsBuildFolders() throws {
        let home = try Fixture.makeHome()
        let top = try Fixture.buildFolder(home, "Developer/dd-460.noindex")
        let nested = try Fixture.buildFolder(home, "Developer/release-1.18.1.noindex/dd")
        let third = try Fixture.buildFolder(home, "Projects/client/ci/dd")
        let derived = try Fixture.buildFolder(home, "Developer/DerivedData/App-abcdef")
        let homeChild = try Fixture.buildFolder(home, "builds.noindex")

        let found = Fixture.walk(home)
        #expect(Set(found) == Set([top, nested, third, derived, homeChild].map(\.path)))
    }

    @Test("the walk stops three levels down and never enters hidden folders, bundles or Library")
    func walkStaysInItsLane() throws {
        let home = try Fixture.makeHome()
        try Fixture.buildFolder(home, "Developer/a/b/c/dd")
        try Fixture.buildFolder(home, "Developer/.hidden/dd")
        try Fixture.buildFolder(home, "Developer/Tool.app/Contents/dd")
        try Fixture.buildFolder(home, "Developer/Purge.xcarchive/dd")
        try Fixture.buildFolder(home, "Library/dd")
        try Fixture.buildFolder(home, "Developer/web/node_modules/dd")
        try Fixture.buildFolder(home, "Developer/app/build")
        try Fixture.buildFolder(home, "Developer/elsewhere/deep/x/y")

        #expect(Fixture.walk(home).isEmpty)
    }

    @Test("a build folder inside another is never listed, and a link is never followed")
    func walkStopsAtAFindAndSkipsLinks() throws {
        let home = try Fixture.makeHome()
        let outer = try Fixture.buildFolder(home, "Developer/outer")
        let fm = FileManager.default
        // Build/Products/Debug sits inside the found folder; no second row comes from it.
        try fm.createDirectory(at: home.appendingPathComponent("Elsewhere"), withIntermediateDirectories: true)
        let target = try Fixture.buildFolder(home, "Elsewhere/dd")
        try fm.createSymbolicLink(at: home.appendingPathComponent("Developer/linked"), withDestinationURL: target)

        #expect(Fixture.walk(home) == [outer.path])
    }

    @Test("a root inside a listed build folder adds no nested row")
    func nestedRootIsDropped() throws {
        let home = try Fixture.makeHome()
        let outer = try Fixture.buildFolder(home, "Developer/outer")
        try Fixture.buildFolder(home, "Developer/outer/Logs/nested")
        let found = Policy.walk(
            [home.appendingPathComponent("Developer"), home.appendingPathComponent("Developer/outer/Logs")],
            home: home, access: .full, addedRoots: [], nonLocalMounts: []
        )
        #expect(found.map(\.path) == [outer.path])
    }

    @Test("a case-insensitive second spelling of a root is walked once")
    func rootsAreWalkedOnce() throws {
        let home = try Fixture.makeHome()
        let folder = try Fixture.buildFolder(home, "Developer/dd")
        // On a case-sensitive volume `developer` doesn't exist and is skipped anyway.
        let found = Policy.walk(
            [home.appendingPathComponent("Developer"), home.appendingPathComponent("developer")],
            home: home,
            access: .full
        )
        #expect(found.map(\.path) == [folder.path])
    }

    @Test("without Full Disk Access the walk never enters Documents")
    func limitedWalkSkipsProtectedFolders() throws {
        let home = try Fixture.makeHome()
        try Fixture.buildFolder(home, "Documents/dd")
        let developer = try Fixture.buildFolder(home, "Developer/dd")
        #expect(Fixture.walk(home, access: .limited) == [developer.path])
        #expect(Set(Fixture.walk(home, access: .full)).count == 2)
    }

    @Test("a folder a process has open is left off the list")
    func openFolderIsNotOffered() throws {
        let home = try Fixture.makeHome()
        let busy = try Fixture.buildFolder(home, "Developer/busy")
        let idle = try Fixture.buildFolder(home, "Developer/idle")
        let listing: OpenFileCheck.Lister = {
            "p4242\ncXcode\nn\(busy.path)/Index.noindex/DataStore/v5/units\n"
        }
        let found = Policy.buildFolders(
            in: [home.appendingPathComponent("Developer")], home: home, access: .full, lister: listing
        )
        #expect(found.map(\.path) == [idle.path])
    }

    @Test("an open file counts for its own folder only, not one whose name starts the same")
    func openFileMatchesWholeFolderNames() {
        let map = ["/h/Developer/dd": "/h/Developer/dd", "/private/h/Developer/dd": "/h/Developer/dd"]
        #expect(Policy.foldersHolding("/h/Developer/dd-2/Logs/x", folderBySpelling: map).isEmpty)
        #expect(Policy.foldersHolding("/h/Developer/dd/Logs/x", folderBySpelling: map) == ["/h/Developer/dd"])
        #expect(Policy.foldersHolding("/private/h/Developer/dd", folderBySpelling: map) == ["/h/Developer/dd"])
        #expect(Policy.foldersHolding("localhost:8080", folderBySpelling: map).isEmpty)
    }

    @Test("when open files can't be listed, nothing is offered")
    func unreadableListingOffersNothing() throws {
        let home = try Fixture.makeHome()
        try Fixture.buildFolder(home, "Developer/dd")
        let found = Policy.buildFolders(
            in: [home.appendingPathComponent("Developer")], home: home, access: .full, lister: { nil }
        )
        #expect(found.isEmpty)
    }

    @Test("a folder a LaunchAgent starts a program from is left off the list")
    func launchAgentFolderIsNotOffered() throws {
        let home = try Fixture.makeHome()
        let started = try Fixture.buildFolder(home, "Developer/bench")
        let idle = try Fixture.buildFolder(home, "Developer/idle")
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let job: [String: Any] = [
            "Label": "com.example.bench",
            "ProgramArguments": [started.appendingPathComponent("Build/Products/Debug/App").path]
        ]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("com.example.bench.plist"))

        let found = Policy.buildFolders(
            in: [home.appendingPathComponent("Developer")], home: home, access: .full, lister: Fixture.noOpenFiles
        )
        #expect(found.map(\.path) == [idle.path])
    }

    // MARK: Right before the move

    @Test("the move check passes other paths and holds a build folder that is in use")
    func immediateBoundary() throws {
        let home = try Fixture.makeHome()
        let folder = try Fixture.buildFolder(home, "Developer/dd")
        let other = home.appendingPathComponent("Developer/notes")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let busy: OpenFileCheck.Lister = { "p1\ncxcodebuild\nn\(folder.path)/Logs/Build/x\n" }

        #expect(Policy.passesImmediateTrashBoundary(other, home: home.path, lister: { nil }))
        #expect(Policy.passesImmediateTrashBoundary(folder, home: home.path, lister: Fixture.noOpenFiles))
        #expect(!Policy.passesImmediateTrashBoundary(folder, home: home.path, lister: busy))
        #expect(!Policy.passesImmediateTrashBoundary(folder, home: home.path, lister: { nil }))
    }

    @Test("FileDeleter's default move check runs the build folder check")
    func defaultMoveCheckIncludesBuildFolders() throws {
        let home = try Fixture.makeHome()
        let folder = try Fixture.buildFolder(home, "Developer/dd")
        let check = FileDeleter.defaultImmediateMoveCheck(home: home.path, openFiles: { nil })
        #expect(!check(folder))
        let free = FileDeleter.defaultImmediateMoveCheck(home: home.path, openFiles: Fixture.noOpenFiles)
        #expect(free(folder))
    }

    @Test("the move check holds a folder a LaunchAgent starts a program from")
    func immediateBoundaryHoldsLaunchAgentFolder() throws {
        let home = try Fixture.makeHome()
        let folder = try Fixture.buildFolder(home, "Developer/dd")
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let job: [String: Any] = ["Label": "x", "Program": folder.appendingPathComponent("Build/Products/Debug/App").path]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("x.plist"))
        #expect(!Policy.passesImmediateTrashBoundary(folder, home: home.path, lister: Fixture.noOpenFiles))
    }

    // MARK: Review of #482

    @Test("a folder offered as a build folder that loses its mark stays, at the move and in the list")
    func lostMarkIsRefused() throws {
        let home = try Fixture.makeHome()
        let folder = try Fixture.buildFolder(home, "Developer/dd")
        Policy.recordOffered([folder])
        #expect(Policy.passesImmediateTrashBoundary(folder, home: home.path, lister: Fixture.noOpenFiles))
        #expect(!Policy.refusesDeletion(folder))

        // Saved at the folder's top between the scan and the move.
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        #expect(!Policy.passesImmediateTrashBoundary(folder, home: home.path, lister: Fixture.noOpenFiles))
        #expect(Policy.refusesDeletion(folder))

        // info.plist removed: no longer looks like a build folder at all, and still stays.
        let other = try Fixture.buildFolder(home, "Developer/other")
        Policy.recordOffered([other])
        try FileManager.default.removeItem(at: other.appendingPathComponent("info.plist"))
        #expect(!Policy.passesImmediateTrashBoundary(other, home: home.path, lister: Fixture.noOpenFiles))
        #expect(Policy.refusesDeletion(other))

        // A folder no scan offered, with no mark, is not this rule's.
        let plain = home.appendingPathComponent("Developer/plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(Policy.passesImmediateTrashBoundary(plain, home: home.path, lister: { nil }))
        #expect(!Policy.refusesDeletion(plain))
    }

    @Test("the list may reuse a read for two seconds; a move reads the folder again")
    func listReusesRecentRead() throws {
        let home = try Fixture.makeHome()
        let folder = try Fixture.buildFolder(home, "Developer/dd")
        Policy.recordOffered([folder])
        let start = Date()
        #expect(!Policy.refusesDeletion(folder, reuseRecentRead: true, now: start))
        try Data("x".utf8).write(to: folder.appendingPathComponent("stray.txt"))
        #expect(!Policy.refusesDeletion(folder, reuseRecentRead: true, now: start.addingTimeInterval(1)))
        #expect(Policy.refusesDeletion(folder, reuseRecentRead: true, now: start.addingTimeInterval(3)))
        #expect(Policy.refusesDeletion(folder, reuseRecentRead: false, now: start.addingTimeInterval(1)))
    }

    @Test("below a folder added in Settings, the walk skips another sync service's folder")
    func walkSkipsOffLimitsBelowAddedFolders() throws {
        let home = try Fixture.makeHome()
        let added = home.appendingPathComponent("Clients")
        try Fixture.buildFolder(home, "Clients/Shared/app/dd")
        try Data().write(to: home.appendingPathComponent("Clients/Shared/.dropbox"))
        let kept = try Fixture.buildFolder(home, "Clients/other/dd")
        let found = Policy.walk([added], home: home, access: .full, addedRoots: [added.path], nonLocalMounts: [])
        #expect(found.map(\.path) == [kept.path])
    }

    @Test("the move refuses a build folder below an off-limits folder in an added folder")
    func moveRefusesBelowOffLimits() throws {
        let home = try Fixture.makeHome()
        let added = home.appendingPathComponent("Clients").path
        let synced = try Fixture.buildFolder(home, "Clients/Shared/app/dd")
        try Data().write(to: home.appendingPathComponent("Clients/Shared/.dropbox"))
        let fine = try Fixture.buildFolder(home, "Clients/other/dd")
        ScanFolders.$snapshotOverride.withValue(.init(walked: [added], saved: [added])) {
            #expect(!Policy.passesImmediateTrashBoundary(synced, home: home.path, lister: Fixture.noOpenFiles))
            #expect(Policy.passesImmediateTrashBoundary(fine, home: home.path, lister: Fixture.noOpenFiles))
        }
    }

    @Test("the walk and the move stay off a mount that is not a local disk")
    func nonLocalMountsAreSkipped() throws {
        let home = try Fixture.makeHome()
        let share = home.appendingPathComponent("Developer/share").path
        let onShare = try Fixture.buildFolder(home, "Developer/share/dd")
        let local = try Fixture.buildFolder(home, "Developer/dd")
        let found = Policy.walk(
            [home.appendingPathComponent("Developer")], home: home, access: .full,
            addedRoots: [], nonLocalMounts: [share]
        )
        #expect(found.map(\.path) == [local.path])
        // A root added in Settings below the share is never read either.
        try Fixture.buildFolder(home, "Developer/share/client/dd")
        let belowShare = Policy.walk(
            [home.appendingPathComponent("Developer/share/client")], home: home, access: .full,
            addedRoots: [], nonLocalMounts: [share]
        )
        #expect(belowShare.isEmpty)
        // Home itself on a share, as a network home folder is, is not listed.
        try Fixture.buildFolder(home, "homechild.noindex")
        let homeOnShare = Policy.walk([home], home: home, access: .full, addedRoots: [], nonLocalMounts: [home.path])
        #expect(homeOnShare.isEmpty)
        let homeLocal = Policy.walk([home], home: home, access: .full, addedRoots: [], nonLocalMounts: [])
        #expect(homeLocal.map(\.lastPathComponent) == ["homechild.noindex"])
        #expect(!Policy.passesImmediateTrashBoundary(
            onShare, home: home.path, lister: Fixture.noOpenFiles, nonLocalMounts: [share]
        ))
    }

    @Test("a LaunchAgent whose program is a link into the folder, or spelled in another case, holds it")
    func launchAgentLinksAndCaseCount() throws {
        let home = try Fixture.makeHome()
        let folder = try Fixture.buildFolder(home, "Developer/bench")
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("agent"),
            withDestinationURL: folder.appendingPathComponent("Build/Products/Debug/App")
        )
        let job: [String: Any] = ["Label": "linked", "Program": bin.appendingPathComponent("agent").path]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("linked.plist"))
        #expect(Policy.launchAgentStartsProgram(from: folder, home: home))
        #expect(!Policy.passesImmediateTrashBoundary(folder, home: home.path, lister: Fixture.noOpenFiles))
        #expect(Policy.buildFolders(
            in: [home.appendingPathComponent("Developer")], home: home, access: .full, lister: Fixture.noOpenFiles
        ).isEmpty)

        // The same folder named in upper case, where the volume ignores case.
        try FileManager.default.removeItem(at: agents.appendingPathComponent("linked.plist"))
        let upper = folder.path.replacingOccurrences(of: "/Developer/bench", with: "/DEVELOPER/BENCH")
        guard FileManager.default.fileExists(atPath: upper) else { return }
        let cased: [String: Any] = ["Label": "cased", "Program": upper + "/Build/Products/Debug/App"]
        try PropertyListSerialization.data(fromPropertyList: cased, format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("cased.plist"))
        #expect(Policy.launchAgentStartsProgram(from: folder, home: home))
    }

    @Test("a folder spelled in another case is checked against the never-delete lists by its path on disk")
    func neverDeleteMatchesCaseOnDisk() throws {
        let home = try Fixture.makeHome()
        let folder = try Fixture.buildFolder(home, "Pictures/X/dd")
        let lower = home.appendingPathComponent("pictures/X/dd").path
        guard FileManager.default.fileExists(atPath: lower) else { return }
        #expect(!Policy.isWhitelistedPath(lower, home: home.path))
        #expect(!Policy.isWhitelistedPath(folder.path, home: home.path))
    }

    // MARK: Rows

    @Test("rows are Check First, one per folder, labelled with the folder's path")
    func rowsAreCheckFirst() throws {
        let home = try Fixture.makeHome()
        let folder = try Fixture.buildFolder(home, "Developer/dd-460.noindex")
        let label = Policy.labelPrefix + folder.path
        #expect(Policy.folderPath(inLabel: label) == folder.path)
        #expect(Policy.folderPath(inLabel: "Xcode Derived Data") == nil)
        #expect(BrandIconMapping.slug(forDefinitionKey: label) == "xcode")

        let info = Policy.safetyInfo(forFolder: folder.path, home: home, access: .full)
        #expect(info.level == .medium)
        #expect(info.headline == "Xcode Build Files in dd-460.noindex")
        let base = SafetyInfo.fromExplanationDatabase(key: Policy.explanationKey)
        #expect(base.level == .medium)
    }

    @Test("a nested build folder's headline names its parent too")
    func nestedHeadlineNamesParent() throws {
        let home = try Fixture.makeHome()
        let top = try Fixture.buildFolder(home, "Developer/dd-460.noindex")
        let nested = try Fixture.buildFolder(home, "Developer/release-1.18.1.noindex/dd")
        let homeChild = try Fixture.buildFolder(home, "builds.noindex")
        #expect(Policy.displayName(ofFolder: top.path, home: home) == "dd-460.noindex")
        #expect(Policy.displayName(ofFolder: nested.path, home: home) == "release-1.18.1.noindex/dd")
        #expect(Policy.displayName(ofFolder: homeChild.path, home: home) == "builds.noindex")
        let info = Policy.safetyInfo(forFolder: nested.path, home: home, access: .full)
        #expect(info.headline == "Xcode Build Files in release-1.18.1.noindex/dd")
    }

    @Test("the explanation names the project and says when it is gone")
    func explanationText() throws {
        let home = try Fixture.makeHome()
        let projectFolder = home.appendingPathComponent("Developer/purge-460-digits")
        try FileManager.default.createDirectory(
            at: projectFolder.appendingPathComponent("purge.xcodeproj"), withIntermediateDirectories: true
        )
        let present = try Fixture.buildFolder(
            home, "Developer/dd-460", workspace: projectFolder.appendingPathComponent("purge.xcodeproj").path
        )
        let gone = try Fixture.buildFolder(
            home, "Developer/dd-324", workspace: home.appendingPathComponent("Developer/purge-324/purge.xcodeproj").path
        )

        let presentText = Policy.safetyInfo(forFolder: present.path, home: home, access: .full).explanation
        #expect(presentText.hasPrefix("Built from purge-460-digits on "))
        #expect(presentText.hasSuffix("Xcode makes these files again the next time you build the project."))

        let goneText = Policy.safetyInfo(forFolder: gone.path, home: home, access: .full).explanation
        #expect(goneText.hasPrefix("Built from purge-324 on "))
        #expect(goneText.hasSuffix("That folder is no longer on this Mac."))

        // The rows' text and the "project is gone" link read the same answer.
        #expect(Policy.isProjectGone(gone.path))
        #expect(!Policy.isProjectGone(present.path))
        // A project that comes back clears it on the next scan.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Developer/purge-324/purge.xcodeproj"), withIntermediateDirectories: true
        )
        _ = Policy.safetyInfo(forFolder: gone.path, home: home, access: .full)
        #expect(!Policy.isProjectGone(gone.path))
    }

    @Test("a project Purge may not look at is never called gone")
    func unknownProjectIsNotCalledGone() {
        let text = XcodeBuildFolderScanPolicy.explanation(
            project: "App", lastBuilt: nil, projectExists: nil, rebuildNote: "Note."
        )
        #expect(text == "Built from App. Note.")
    }

    @Test("the project name is the folder holding the project, or the package itself")
    func projectNames() {
        #expect(Policy.projectName(of: "/Users/a/Developer/purge-460/purge.xcodeproj") == "purge-460")
        #expect(Policy.projectName(of: "/Users/a/Developer/App/App.xcodeproj/project.xcworkspace") == "App")
        #expect(Policy.projectName(of: "/Users/a/Developer/Tool.xcworkspace") == "Developer")
        #expect(Policy.projectName(of: "/Users/a/Developer/MyPackage") == "MyPackage")
    }
}

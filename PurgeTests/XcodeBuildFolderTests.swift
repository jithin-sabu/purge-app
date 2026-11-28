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
        #expect(goneText.hasSuffix("That project is no longer on this Mac."))
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

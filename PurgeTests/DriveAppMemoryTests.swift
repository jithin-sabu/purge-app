import Foundation
import Testing
@testable import Purge

/// An app on a drive that is unplugged still owns its leftovers (#99). The
/// drives are folders in a stand-in for `/Volumes`, and the remembered list is
/// written to a temporary folder, never the user's own.
@Suite("Apps remembered on drives that are unplugged (#99)")
struct DriveAppMemoryTests {
    private struct Fixture {
        let base: URL
        var home: URL { base.appendingPathComponent("home", isDirectory: true) }
        var volumes: URL { base.appendingPathComponent("Volumes", isDirectory: true) }

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("purge-drive-memory-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
        }

        func app(_ relative: String, id: String) throws -> URL {
            let bundle = base.appendingPathComponent(relative, isDirectory: true)
            let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: NSDictionary = ["CFBundleIdentifier": id]
            info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
            return bundle
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    private func withDrives<T>(_ fixture: Fixture, _ body: () throws -> T) throws -> T {
        try withTemporaryHandoffRoot {
            try AppFolders.$volumes.withValue(fixture.volumes) { try body() }
        }
    }

    @Test("Apps in a drive's Applications folder are remembered, apps in /Applications are not")
    func onlyDriveAppsAreRemembered() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.app("Volumes/SSD/Applications/Luminar Neo.app", id: "com.skylum.luminarneo")
        let builtIn = try fixture.app("home/Applications/Tool.app", id: "com.purgetest.tool")

        try withDrives(fixture) {
            DriveAppMemory.record(bundles: [drive, builtIn], home: fixture.home, isTestHost: false)
            let entries = DriveAppMemory.entries()
            #expect(entries.map(\.bundlePath) == [drive.standardizedFileURL.path])
            #expect(entries.first?.bundleID == "com.skylum.luminarneo")
            #expect(entries.first?.name == "Luminar Neo")
        }
    }

    @Test("A remembered app on a drive that is unplugged still counts")
    func unpluggedDriveAppStillCounts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.app("Volumes/SSD/Applications/Luminar Neo.app", id: "com.skylum.luminarneo")

        try withDrives(fixture) {
            DriveAppMemory.record(bundles: [drive], home: fixture.home, isTestHost: false)
            // Ejected: the whole drive folder is gone.
            try FileManager.default.removeItem(at: fixture.volumes.appendingPathComponent("SSD"))
            DriveAppMemory.record(bundles: [], home: fixture.home, isTestHost: false)

            #expect(DriveAppMemory.apps().map(\.bundleID) == ["com.skylum.luminarneo"])
        }
    }

    @Test("An app gone from a drive that is still plugged in is forgotten")
    func removedDriveAppIsForgotten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.app("Volumes/SSD/Applications/Tool.app", id: "com.purgetest.tool")

        try withDrives(fixture) {
            DriveAppMemory.record(bundles: [drive], home: fixture.home, isTestHost: false)
            try FileManager.default.removeItem(at: drive)

            #expect(DriveAppMemory.apps().isEmpty)
            DriveAppMemory.record(bundles: [], home: fixture.home, isTestHost: false)
            #expect(DriveAppMemory.entries().isEmpty)
        }
    }

    @Test("A different drive with the same name does not make Purge forget an app")
    func sameNameDriveKeepsTheApp() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // The folder is there and the bundle is not: on the drive it was seen
        // on, that means it is gone; on another drive, it means nothing.
        let root = try fixture.app("Volumes/SSD/Applications/Placeholder.app", id: "com.purgetest.placeholder")
            .deletingLastPathComponent()
        let entry = DriveAppMemory.Entry(
            bundlePath: root.appendingPathComponent("Foo.app").path,
            bundleID: "com.purgetest.foo",
            name: "Foo",
            rootPath: root.path,
            lastSeen: Date(),
            volumeID: "DRIVE-A"
        )
        #expect(DriveAppMemory.mayStillBeInstalled(entry, volumeID: { _ in "DRIVE-B" }))
        #expect(!DriveAppMemory.mayStillBeInstalled(entry, volumeID: { _ in "DRIVE-A" }))
    }

    @Test("The test host never writes the list")
    func testHostNeverWrites() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.app("Volumes/SSD/Applications/Tool.app", id: "com.purgetest.tool")

        try withDrives(fixture) {
            DriveAppMemory.record(bundles: [drive], home: fixture.home, isTestHost: true)
            #expect(!FileManager.default.fileExists(atPath: DriveAppMemory.file.path))
        }
    }

    @Test("An app judged for removal never counts as its own survivor")
    func appIsNotItsOwnSurvivor() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.app("Volumes/SSD/Applications/Tool.app", id: "com.purgetest.tool")

        try withDrives(fixture) {
            DriveAppMemory.record(bundles: [drive], home: fixture.home, isTestHost: false)
            #expect(DriveAppMemory.apps(excluding: drive.standardizedFileURL.path).isEmpty)
            #expect(DriveAppMemory.apps().count == 1)
        }
    }

    @Test("Signatures are read once per version of a drive app")
    func claimsAreReadOncePerVersion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.app("Volumes/SSD/Applications/Editor.app", id: "com.vendor.editor")
        let root = fixture.volumes.appendingPathComponent("SSD/Applications").standardizedFileURL.path
        var reads = 0
        let readClaims: (URL) -> InstalledCodeEvidence = { _ in
            reads += 1
            var claims = InstalledCodeEvidence()
            claims.add(CodeSignature(identifier: "com.vendor.editor", teamID: "TEAM123456", appGroups: ["TEAM123456.com.vendor.shared"]))
            return claims
        }

        let first = DriveAppMemory.seenEntries([drive], roots: [root], now: Date(), readClaims: readClaims)
        #expect(first.first?.teamIDs == ["TEAM123456"])
        #expect(first.first?.appGroups == ["team123456.com.vendor.shared"])
        _ = DriveAppMemory.seenEntries([drive], roots: [root], now: Date(), known: first, readClaims: readClaims)
        #expect(reads == 1)

        // An update changes the version, and the claims are read again.
        let info: NSDictionary = ["CFBundleIdentifier": "com.vendor.editor", "CFBundleVersion": "2"]
        info.write(to: drive.appendingPathComponent("Contents/Info.plist"), atomically: true)
        _ = DriveAppMemory.seenEntries([drive], roots: [root], now: Date(), known: first, readClaims: readClaims)
        #expect(reads == 2)
    }

    @Test("An app replaced in place at the same version has its signatures read again")
    func sameVersionReplacementRereadsClaims() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let drive = try fixture.app("Volumes/SSD/Applications/Editor.app", id: "com.vendor.editor")
        let root = fixture.volumes.appendingPathComponent("SSD/Applications").standardizedFileURL.path
        var reads = 0
        let readClaims: (URL) -> InstalledCodeEvidence = { _ in
            reads += 1
            return InstalledCodeEvidence()
        }

        let first = DriveAppMemory.seenEntries([drive], roots: [root], now: Date(), readClaims: readClaims)
        #expect(reads == 1)
        // Same id and version, but the bundle was written again.
        let info = drive.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: info.path)
        _ = DriveAppMemory.seenEntries([drive], roots: [root], now: Date(), known: first, readClaims: readClaims)
        #expect(reads == 2)
    }

    @Test("Two drives with an app at the same path are both remembered")
    func sameMountPathKeepsBothDrives() {
        func entry(_ id: String, volume: String) -> DriveAppMemory.Entry {
            DriveAppMemory.Entry(
                bundlePath: "/Volumes/SSD/Applications/Foo.app",
                bundleID: id,
                name: "Foo",
                rootPath: "/Volumes/SSD/Applications",
                lastSeen: Date(),
                appGroups: ["group.\(id)"],
                volumeID: volume
            )
        }
        let driveA = entry("com.purgetest.foo-a", volume: "DRIVE-A")
        let driveB = entry("com.purgetest.foo-b", volume: "DRIVE-B")

        // Drive A is out and B is in: seeing B's app must not replace A's.
        let merged = DriveAppMemory.merged([driveA], seen: [driveB], mayStillBeInstalled: { _ in true })
        #expect(Set(merged.compactMap(\.bundleID)) == ["com.purgetest.foo-a", "com.purgetest.foo-b"])
        #expect(merged.contains { $0.appGroups == ["group.com.purgetest.foo-a"] })

        // Seeing B again updates only B's entry.
        let again = DriveAppMemory.merged(merged, seen: [driveB], mayStillBeInstalled: { _ in true })
        #expect(again.count == 2)
    }

    @Test("Unlisted drive apps join the survivors, but not ones already listed or being removed")
    func unlistedDriveAppsJoinSurvivors() {
        func app(_ path: String) -> InstalledApp {
            InstalledApp(
                name: (path as NSString).lastPathComponent,
                bundleURL: URL(fileURLWithPath: path, isDirectory: true),
                bundleID: "com.purgetest.\((path as NSString).lastPathComponent)",
                bundleSizeBytes: 0,
                isRunning: false
            )
        }
        let listed = app("/Volumes/SSD/Applications/Listed.app")
        let unplugged = app("/Volumes/Old/Applications/Unplugged.app")
        let going = app("/Volumes/Old/Applications/Going.app")

        let extra = PurgeStore.unlistedDriveApps(
            besides: [listed],
            removing: [going.id],
            remembered: [listed, unplugged, going]
        )
        #expect(extra.map(\.id) == [unplugged.id])
    }
}

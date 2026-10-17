import Foundation
import Testing
@testable import Purge

/// The Everything else groups (#220): which folders feed which group, which a
/// limited scan skips, and how bytes are claimed once against the five Overview
/// categories. Pure functions over made-up paths; nothing here touches the disk.
@Suite("Everything else groups")
struct EverythingElseGroupTests {
    private let gb: Int64 = 1_000_000_000
    private let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
    private let users = URL(fileURLWithPath: "/Users", isDirectory: true)

    private func roots(access: ScanAccess, steam: [URL] = [], others: [URL] = []) -> [EverythingElseMeasureRoot] {
        EverythingElseRootPlan.roots(home: home, access: access, steamLibraries: steam, otherUserHomes: others, usersFolder: users)
    }

    private func root(_ group: EverythingElseGroup, _ path: String, _ kind: EverythingElseMeasureRoot.Kind = .children) -> EverythingElseMeasureRoot {
        EverythingElseMeasureRoot(group: group, url: URL(fileURLWithPath: path, isDirectory: true), kind: kind, isLockedWithoutAccess: false)
    }

    // MARK: Group definitions

    @Test func theMeasuredGroupsComeInClaimOrderAndTheDisplayGroupsLast() {
        #expect(EverythingElseGroup.measured == [
            .appsOutsideApplications, .managedLibraries, .uncleanableCaches, .appData,
            .yourFiles, .hiddenToolFolders, .otherUsers
        ])
        #expect(!EverythingElseGroup.macOS.isMeasured)
        #expect(!EverythingElseGroup.notMeasured.isMeasured)
        #expect(!EverythingElseGroup.macOS.isShownOnOverview)
        #expect(EverythingElseGroup.notMeasured.isShownOnOverview)
    }

    @Test func everyGroupHasItsFolders() {
        let plan = roots(access: .full, steam: [URL(fileURLWithPath: "/Volumes/Games/SteamLibrary")], others: [users.appendingPathComponent("bob")])
        func paths(_ group: EverythingElseGroup) -> [String] {
            plan.filter { $0.group == group }.map(\.path)
        }
        #expect(paths(.appsOutsideApplications).contains("/Volumes/Games/SteamLibrary/steamapps/common"))
        #expect(paths(.appsOutsideApplications).contains("/Users/alice/Library/Application Support/JetBrains/Toolbox/apps"))
        #expect(paths(.appsOutsideApplications).contains("/Users/Shared/Epic Games"))
        #expect(paths(.managedLibraries).contains("/Users/alice/Library/Mail"))
        #expect(paths(.managedLibraries).contains("/Users/alice/Pictures/Photos Library.photoslibrary"))
        #expect(paths(.uncleanableCaches) == ["/Users/alice/Library/Caches"])
        #expect(paths(.appData) == [
            "/Users/alice/Library/Application Support",
            "/Users/alice/Library/Containers",
            "/Users/alice/Library/Group Containers"
        ])
        #expect(paths(.yourFiles) == EverythingElseRootPlan.yourFileFolders.map { "/Users/alice/\($0)" })
        #expect(paths(.hiddenToolFolders) == ["/Users/alice"])
        #expect(paths(.otherUsers) == ["/Users/bob"])
        #expect(paths(.macOS).isEmpty)
        #expect(paths(.notMeasured).isEmpty)
    }

    @Test func librariesAndOtherUsersAreMeasuredWholeAndTheRestByFolder() {
        let plan = roots(access: .full, others: [users.appendingPathComponent("Shared")])
        for root in plan {
            switch root.group {
            case .managedLibraries, .otherUsers:
                #expect(root.kind == .whole, "\(root.path)")
            case .appsOutsideApplications, .uncleanableCaches, .appData, .yourFiles, .hiddenToolFolders:
                #expect(root.kind == .children, "\(root.path)")
            case .macOS, .notMeasured:
                Issue.record("\(root.group) has no roots to walk")
            }
        }
    }

    @Test func otherUserHomesLeaveOutTheCurrentUserAndHiddenEntries() {
        let homes = EverythingElseRootPlan.otherUserHomes(in: users, names: ["bob", ".localized", "alice", "Shared"], home: home)
        #expect(homes.map(\.path) == ["/Users/Shared", "/Users/bob"])
    }

    @Test func steamLibrariesComeFromTheVDF() {
        let vdf = """
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"/Users/alice/Library/Application Support/Steam"
        \t\t"label"\t\t""
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"/Volumes/Games/SteamLibrary"
        \t}
        }
        """
        let libraries = SteamLibraryFolders.libraryRoots(fromVDF: vdf)
        #expect(libraries.map(\.path) == ["/Users/alice/Library/Application Support/Steam", "/Volumes/Games/SteamLibrary"])
    }

    // MARK: Access gating

    @Test func withFullDiskAccessNothingIsLocked() {
        let plan = roots(access: .full)
        #expect(plan.allSatisfy { !$0.isLockedWithoutAccess })
    }

    @Test func aLimitedScanLocksTheProtectedRootsAndNothingElse() {
        let plan = roots(access: .limited, others: [users.appendingPathComponent("bob")])
        let locked = Set(plan.filter(\.isLockedWithoutAccess).map(\.path))
        let open = Set(plan.filter { !$0.isLockedWithoutAccess }.map(\.path))
        for relative in ["Documents", "Desktop", "Downloads", "Library/Containers", "Library/Group Containers", "Library/Mail", "Library/Messages"] {
            #expect(locked.contains("/Users/alice/\(relative)"), Comment(rawValue: relative))
        }
        for relative in ["Movies", "Music", "Pictures", "Library/Caches", "Library/Application Support"] {
            #expect(open.contains("/Users/alice/\(relative)"), Comment(rawValue: relative))
        }
        #expect(open.contains("/Users/alice"))
        #expect(open.contains("/Users/bob"))
    }

    @Test func aLimitedScanNeverSizesAMediaLibraryOrTheAddressBook() {
        // Reading inside these puts a Photos, Media & Apple Music or Contacts
        // prompt on screen in Purge's name, so a limited walk stays out, whether
        // they are roots of their own or folders inside Pictures and Music.
        let plan = roots(access: .limited)
        for root in plan where root.group == .managedLibraries {
            #expect(root.isLockedWithoutAccess, Comment(rawValue: root.path))
        }
        #expect(!EverythingElseRootPlan.isReadableByLimitedWalk(home.appendingPathComponent("Pictures/Photos Library.photoslibrary"), home: home))
        #expect(!EverythingElseRootPlan.isReadableByLimitedWalk(home.appendingPathComponent("Music/Music"), home: home))
        #expect(!EverythingElseRootPlan.isReadableByLimitedWalk(home.appendingPathComponent("Movies/Holiday.imovielibrary"), home: home))
        #expect(!EverythingElseRootPlan.isReadableByLimitedWalk(home.appendingPathComponent("Library/Application Support/AddressBook"), home: home))
        #expect(!EverythingElseRootPlan.isReadableByLimitedWalk(home.appendingPathComponent("Library/Containers/com.apple.mail"), home: home))
        #expect(EverythingElseRootPlan.isReadableByLimitedWalk(home.appendingPathComponent("Pictures/Scans"), home: home))
        #expect(EverythingElseRootPlan.isReadableByLimitedWalk(home.appendingPathComponent("Library/Application Support/CoreAIKit"), home: home))
        // With Full Disk Access the same roots are open.
        #expect(roots(access: .full).allSatisfy { !$0.isLockedWithoutAccess })
    }

    @Test func aLockedGroupSaysSoInTheBreakdown() {
        let plan = roots(access: .limited)
        var measurement = EverythingElseMeasurement(access: .limited)
        measurement.apply(.planned(plan))
        for root in plan where root.isLockedWithoutAccess {
            measurement.apply(.skipped(root, locked: true))
        }
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 100 * gb)
        #expect(breakdown[.yourFiles]?.isLocked == true)
        #expect(breakdown[.appData]?.isLocked == true)
        #expect(breakdown[.managedLibraries]?.isLocked == true)
        #expect(breakdown[.uncleanableCaches]?.isLocked == false)
        #expect(breakdown[.hiddenToolFolders]?.isLocked == false)
        // Measured roots still to come, so this group is not finished yet.
        #expect(breakdown[.uncleanableCaches]?.isFinished == false)
        // Every library is locked without access, so that group is done at once.
        #expect(breakdown[.managedLibraries]?.isFinished == true)
        // No other users on this Mac: nothing to wait for.
        #expect(breakdown[.otherUsers]?.isFinished == true)
    }

    // MARK: Claim order

    @Test func aCacheAppCachesFoundAddsNothingUnderAppData() {
        var measurement = EverythingElseMeasurement(access: .full)
        let support = root(.appData, "/Users/alice/Library/Application Support")
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: support, folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Application Support/Chrome", bytes: 5 * gb),
            OverviewSizedItem(path: "/Users/alice/Library/Application Support/CoreAIKit", bytes: 66 * gb)
        ], looseFileBytes: 0)))
        let breakdown = EverythingElseBreakdown(
            measurement: measurement,
            claimedFirst: [OverviewSizedItem(path: "/Users/alice/Library/Application Support/Chrome/Default/Cache", bytes: 3 * gb)],
            everythingElseBytes: 200 * gb
        )
        let appData = breakdown[.appData]
        #expect(appData?.bytes == 68 * gb)
        #expect(appData?.folders.map(\.name) == ["CoreAIKit", "Chrome"])
        #expect(appData?.folders.map(\.bytes) == [66 * gb, 2 * gb])
        #expect(appData?.folders.last?.measuredBytes == 5 * gb)
    }

    @Test func aFolderACategoryAlreadyCountsWholeIsLeftOut() {
        var measurement = EverythingElseMeasurement(access: .full)
        let caches = root(.uncleanableCaches, "/Users/alice/Library/Caches")
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: caches, folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Caches/com.apple.dt.Xcode", bytes: 4 * gb),
            OverviewSizedItem(path: "/Users/alice/Library/Caches/Splash", bytes: 76 * gb)
        ], looseFileBytes: 0)))
        let breakdown = EverythingElseBreakdown(
            measurement: measurement,
            claimedFirst: [OverviewSizedItem(path: "/Users/alice/Library/Caches/com.apple.dt.Xcode", bytes: 4 * gb)],
            everythingElseBytes: 200 * gb
        )
        #expect(breakdown[.uncleanableCaches]?.bytes == 76 * gb)
        #expect(breakdown[.uncleanableCaches]?.folders.map(\.name) == ["Splash"])
    }

    @Test func aSteamGameCountsOnceUnderAppsOutsideApplications() {
        var measurement = EverythingElseMeasurement(access: .full)
        let common = root(.appsOutsideApplications, "/Users/alice/Library/Application Support/Steam/steamapps/common")
        let support = root(.appData, "/Users/alice/Library/Application Support")
        // The walk reports App data first: claim order is by group, not by arrival.
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: support, folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Application Support/Steam", bytes: 80 * gb)
        ], looseFileBytes: 0)))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: common, folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Application Support/Steam/steamapps/common/Hades", bytes: 73 * gb)
        ], looseFileBytes: 0)))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 200 * gb)
        #expect(breakdown[.appsOutsideApplications]?.bytes == 73 * gb)
        #expect(breakdown[.appData]?.bytes == 7 * gb)
        #expect(breakdown.measuredBytes == 80 * gb)
    }

    @Test func aPhotosLibraryComesOutOfYourFiles() {
        var measurement = EverythingElseMeasurement(access: .full)
        let photos = root(.managedLibraries, "/Users/alice/Pictures/Photos Library.photoslibrary", .whole)
        let pictures = root(.yourFiles, "/Users/alice/Pictures")
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: photos, totalBytes: 30 * gb)))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: pictures, folders: [
            OverviewSizedItem(path: "/Users/alice/Pictures/Photos Library.photoslibrary", bytes: 30 * gb),
            OverviewSizedItem(path: "/Users/alice/Pictures/Scans", bytes: 2 * gb)
        ], looseFileBytes: 1 * gb)))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 200 * gb)
        #expect(breakdown[.managedLibraries]?.bytes == 30 * gb)
        #expect(breakdown[.yourFiles]?.bytes == 3 * gb)
        #expect(breakdown[.yourFiles]?.folders.map(\.name) == ["Scans"])
        // The loose files join the smaller line.
        #expect(breakdown[.yourFiles]?.smallerBytes == 1 * gb)
        #expect(breakdown[.yourFiles]?.smallerFolderCount == 0)
    }

    @Test func aLargeFileInsideAFolderIsNotCountedAgain() {
        var measurement = EverythingElseMeasurement(access: .full)
        let movies = root(.yourFiles, "/Users/alice/Movies")
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: movies, folders: [
            OverviewSizedItem(path: "/Users/alice/Movies/Trips", bytes: 20 * gb)
        ], looseFileBytes: 5 * gb)))
        let breakdown = EverythingElseBreakdown(
            measurement: measurement,
            claimedFirst: [
                OverviewSizedItem(path: "/Users/alice/Movies/Trips/iceland.mov", bytes: 12 * gb),
                OverviewSizedItem(path: "/Users/alice/Movies/loose.mov", bytes: 4 * gb)
            ],
            everythingElseBytes: 200 * gb
        )
        #expect(breakdown[.yourFiles]?.bytes == 9 * gb)
        #expect(breakdown[.yourFiles]?.folders.first?.bytes == 8 * gb)
        #expect(breakdown[.yourFiles]?.smallerBytes == 1 * gb)
    }

    @Test func devToolsKeepsItsPartOfAHiddenFolder() {
        var measurement = EverythingElseMeasurement(access: .full)
        let hidden = root(.hiddenToolFolders, "/Users/alice")
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: hidden, folders: [
            OverviewSizedItem(path: "/Users/alice/.npm", bytes: 6 * gb),
            OverviewSizedItem(path: "/Users/alice/.cargo", bytes: 3 * gb)
        ], looseFileBytes: 0)))
        let breakdown = EverythingElseBreakdown(
            measurement: measurement,
            claimedFirst: [OverviewSizedItem(path: "/Users/alice/.npm/_cacache", bytes: 5 * gb)],
            everythingElseBytes: 200 * gb
        )
        #expect(breakdown[.hiddenToolFolders]?.bytes == 4 * gb)
        #expect(breakdown[.hiddenToolFolders]?.folders.map(\.name) == [".cargo", ".npm"])
    }

    // MARK: The floor and the remainder

    @Test func foldersUnderTheFloorRollIntoOneLine() {
        var measurement = EverythingElseMeasurement(access: .full)
        let support = root(.appData, "/Users/alice/Library/Application Support")
        var folders = [OverviewSizedItem(path: "/Users/alice/Library/Application Support/Big", bytes: 12 * gb)]
        for index in 0..<41 {
            folders.append(OverviewSizedItem(path: "/Users/alice/Library/Application Support/small-\(index)", bytes: 100_000_000))
        }
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: support, folders: folders, looseFileBytes: 200_000_000)))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 200 * gb)
        let appData = breakdown[.appData]
        #expect(appData?.folders.map(\.name) == ["Big"])
        let smaller: Int64 = 41 * 100_000_000 + 200_000_000
        #expect(appData?.smallerFolderCount == 41)
        #expect(appData?.smallerBytes == smaller)
        #expect(appData?.bytes == 12 * gb + smaller)
    }

    @Test func theRemainderMakesThePageAddUp() {
        var measurement = EverythingElseMeasurement(access: .full)
        let support = root(.appData, "/Users/alice/Library/Application Support")
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: support, folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Application Support/Big", bytes: 60 * gb)
        ], looseFileBytes: 0)))
        measurement.apply(.macOS(14 * gb))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 100 * gb)
        #expect(breakdown.macOSBytes == 14 * gb)
        #expect(breakdown.notMeasuredBytes == 26 * gb)
        // The Overview has no macOS line, so macOS stays in its remainder.
        #expect(breakdown.notMeasuredOnOverviewBytes == 40 * gb)
        #expect(breakdown.bytes(for: .appData) == 60 * gb)
        #expect(breakdown.bytes(for: .macOS) == 14 * gb)
        #expect(breakdown.bytes(for: .notMeasured) == 26 * gb)
    }

    @Test func sizesAsCountedNeverGoBelowZero() {
        // Clones and purgeable files can make the walk overstate (#131).
        var measurement = EverythingElseMeasurement(access: .full)
        let support = root(.appData, "/Users/alice/Library/Application Support")
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: support, folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Application Support/Big", bytes: 120 * gb)
        ], looseFileBytes: 0)))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 100 * gb)
        #expect(breakdown.notMeasuredBytes == 0)
        #expect(breakdown.notMeasuredOnOverviewBytes == 0)
    }

    @Test func groupsSortBiggestFirstWithEmptyOnesInClaimOrder() {
        var measurement = EverythingElseMeasurement(access: .full)
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: root(.yourFiles, "/Users/alice/Documents"), folders: [
            OverviewSizedItem(path: "/Users/alice/Documents/Work", bytes: 50 * gb)
        ], looseFileBytes: 0)))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: root(.appData, "/Users/alice/Library/Containers"), folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Containers/x", bytes: 70 * gb)
        ], looseFileBytes: 0)))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 200 * gb)
        #expect(breakdown.measuredGroupsBySize.prefix(2) == [.appData, .yourFiles])
        #expect(Array(breakdown.measuredGroupsBySize.dropFirst(2)) == [
            .appsOutsideApplications, .managedLibraries, .uncleanableCaches, .hiddenToolFolders, .otherUsers
        ])
    }

    @Test func aHiddenFolderLeavesTheBreakdown() {
        var measurement = EverythingElseMeasurement(access: .full)
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: root(.appData, "/Users/alice/Library/Containers"), folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Containers/x", bytes: 70 * gb),
            OverviewSizedItem(path: "/Users/alice/Library/Containers/y", bytes: 5 * gb)
        ], looseFileBytes: 0)))
        let exclusions = ScanExclusions(keys: ["/Users/alice/Library/Containers/x"])
        let hidden = measurement.droppingFolders { exclusions.covers(path: $0) }
        let breakdown = EverythingElseBreakdown(measurement: hidden, claimedFirst: [], everythingElseBytes: 200 * gb)
        #expect(breakdown[.appData]?.bytes == 5 * gb)
        #expect(breakdown[.appData]?.folders.map(\.name) == ["y"])
    }

    @Test func theSystemVolumeFigureComesFromDiskutil() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CapacityInUse</key><integer>14087151616</integer>
        <key>VolumeName</key><string>Macintosh HD</string>
        </dict></plist>
        """
        #expect(EverythingElseMeasurer.parseSystemVolumeUsedBytes(Data(plist.utf8)) == 14_087_151_616)
        #expect(EverythingElseMeasurer.parseSystemVolumeUsedBytes(Data("nope".utf8)) == nil)
    }
}

/// The walk itself, on a temporary folder: which children it sizes, what it
/// leaves alone, and that a limited scan never reads a protected root.
@Suite("Everything else measurer")
struct EverythingElseMeasurerTests {
    @Test func measuresTheFoldersInsideARootAndTheLooseFilesBesideThem() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("purge-ee-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("App"), withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: support.appendingPathComponent("App/data.bin"))
        try Data(count: 50_000).write(to: support.appendingPathComponent("loose.plist"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".tool"), withIntermediateDirectories: true)
        try Data(count: 120_000).write(to: home.appendingPathComponent(".tool/cache.bin"))
        try Data(count: 10_000).write(to: home.appendingPathComponent("visible.txt"))

        let measurer = EverythingElseMeasurer()
        var events: [EverythingElseMeasureEvent] = []
        for await event in measurer.measureStream(access: .full, home: home, steamLibraries: [], otherUserHomes: [], readsSystemVolume: false) {
            events.append(event)
        }

        let measured = events.compactMap { event -> EverythingElseMeasuredRoot? in
            if case .measured(let root) = event { return root }
            return nil
        }
        let appData = try #require(measured.first { $0.root.group == .appData && $0.root.url.lastPathComponent == "Application Support" })
        #expect(appData.folders.map { $0.path.hasSuffix("/App") } == [true])
        #expect(appData.folders.first.map { $0.bytes >= 300_000 } == true)
        #expect(appData.looseFileBytes >= 50_000)

        let hidden = try #require(measured.first { $0.root.group == .hiddenToolFolders })
        #expect(hidden.folders.map { $0.path.hasSuffix("/.tool") } == [true])
        // Home's visible files are nobody's tool folder.
        #expect(hidden.looseFileBytes == 0)

        // Roots that are not there are skipped, not measured as empty.
        let skipped = events.filter { if case .skipped(_, locked: false) = $0 { return true } else { return false } }
        #expect(!skipped.isEmpty)
        #expect(!events.contains { if case .macOS = $0 { return true } else { return false } })
    }

    @Test func aLimitedScanSkipsProtectedRootsWithoutReadingThem() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("purge-ee-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents/Work"), withIntermediateDirectories: true)
        try Data(count: 200_000).write(to: home.appendingPathComponent("Documents/Work/a.bin"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Movies/Trips"), withIntermediateDirectories: true)
        try Data(count: 200_000).write(to: home.appendingPathComponent("Movies/Trips/b.mov"))

        let measurer = EverythingElseMeasurer()
        var events: [EverythingElseMeasureEvent] = []
        for await event in measurer.measureStream(access: .limited, home: home, steamLibraries: [], otherUserHomes: [], readsSystemVolume: false) {
            events.append(event)
        }
        let lockedPaths = events.compactMap { event -> String? in
            if case .skipped(let root, locked: true) = event { return root.path }
            return nil
        }
        let measuredPaths = events.compactMap { event -> String? in
            if case .measured(let root) = event { return root.root.path }
            return nil
        }
        // The walk spells a temporary home `/private/var/…`; normalize both sides.
        let documents = OverviewSizedItem.normalized(home.appendingPathComponent("Documents").path)
        let movies = OverviewSizedItem.normalized(home.appendingPathComponent("Movies").path)
        #expect(lockedPaths.contains(documents))
        #expect(!measuredPaths.contains(documents))
        #expect(measuredPaths.contains(movies))
    }
}

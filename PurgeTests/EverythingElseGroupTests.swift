import Foundation
import Testing
@testable import Purge

/// The Everything else groups (#159, #220): which folders feed which group, which
/// a limited scan skips, how bytes are claimed once against the five Overview
/// categories, and how the page sorts them into what you can do. Pure functions
/// over made-up paths; nothing here touches the disk.
@Suite("Everything else groups")
struct EverythingElseGroupTests {
    private let gb: Int64 = 1_000_000_000
    private let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
    private let users = URL(fileURLWithPath: "/Users", isDirectory: true)

    private func roots(
        access: ScanAccess,
        steam: [URL] = [],
        others: [URL] = [],
        homeNames: [String] = []
    ) -> [EverythingElseMeasureRoot] {
        EverythingElseRootPlan.roots(
            home: home,
            access: access,
            steamLibraries: steam,
            otherUserHomes: others,
            homeFolderNames: homeNames,
            usersFolder: users
        )
    }

    private func root(_ group: EverythingElseGroup, _ path: String, _ kind: EverythingElseMeasureRoot.Kind = .children) -> EverythingElseMeasureRoot {
        EverythingElseMeasureRoot(group: group, url: URL(fileURLWithPath: path, isDirectory: true), kind: kind, isLockedWithoutAccess: false)
    }

    // MARK: Group definitions

    @Test func theMeasuredGroupsComeInClaimOrderAndTheDisplayGroupsLast() {
        #expect(EverythingElseGroup.measured == [
            .otherApps, .mediaLibraries, .mailAndMessages, .protectedCaches,
            .developer, .appData, .documents, .otherUsers
        ])
        for group in [EverythingElseGroup.trash, .macOS, .systemData] {
            #expect(!group.isMeasured)
        }
    }

    @Test func everyGroupBelongsToTheBucketThatSaysWhatToDo() {
        #expect(EverythingElseBucket.managedInApps.groups == [.otherApps, .mediaLibraries, .mailAndMessages, .trash])
        #expect(EverythingElseBucket.yourFiles.groups == [.developer, .documents])
        #expect(EverythingElseBucket.leftAlone.groups == [.protectedCaches, .appData])
        #expect(EverythingElseBucket.managedByMacOS.groups == [.otherUsers, .macOS, .systemData])
        // Every group is in exactly one bucket.
        let all = EverythingElseBucket.allCases.flatMap(\.groups)
        #expect(all.count == EverythingElseGroup.allCases.count)
        #expect(Set(all) == Set(EverythingElseGroup.allCases))
    }

    @Test func everyGroupHasItsFolders() {
        let plan = roots(
            access: .full,
            steam: [URL(fileURLWithPath: "/Users/alice/SteamLibrary")],
            others: [users.appendingPathComponent("bob")],
            homeNames: ["Developer", "Documents", "Library", "Tabletop", ".cargo"]
        )
        func paths(_ group: EverythingElseGroup) -> [String] {
            plan.filter { $0.group == group }.map(\.path)
        }
        #expect(paths(.otherApps).contains("/Users/alice/SteamLibrary/steamapps/common"))
        #expect(paths(.otherApps).contains("/Users/alice/Library/Application Support/JetBrains/Toolbox/apps"))
        #expect(paths(.otherApps).contains("/Users/Shared/Epic Games"))
        #expect(paths(.mediaLibraries).contains("/Users/alice/Pictures/Photos Library.photoslibrary"))
        #expect(paths(.mailAndMessages) == ["/Users/alice/Library/Mail", "/Users/alice/Library/Messages"])
        #expect(paths(.protectedCaches) == ["/Users/alice/Library/Caches"])
        #expect(paths(.developer) == ["/Users/alice/Developer", "/Users/alice/Library/Developer", "/Users/alice"])
        #expect(paths(.appData) == [
            "/Users/alice/Library/Application Support",
            "/Users/alice/Library/Containers",
            "/Users/alice/Library/Group Containers",
            "/Users/alice/Library"
        ])
        #expect(paths(.documents) == EverythingElseRootPlan.documentFolders.map { "/Users/alice/\($0)" } + ["/Users/alice"])
        #expect(paths(.otherUsers) == ["/Users/bob"])
        for group in [EverythingElseGroup.trash, .macOS, .systemData] {
            #expect(paths(group).isEmpty)
        }
    }

    @Test func eachRootIsWalkedTheWayItsFolderNeeds() {
        let plan = roots(access: .full, others: [users.appendingPathComponent("Shared")], homeNames: ["Developer"])
        let home = OverviewSizedItem.normalized(self.home.path)
        for root in plan {
            switch root.group {
            case .mediaLibraries, .mailAndMessages, .otherUsers:
                #expect(root.kind == .whole, "\(root.path)")
            case .developer where root.path == home:
                #expect(root.kind == .hiddenChildren)
            case .appData where root.path == "\(home)/Library":
                #expect(root.kind == .childrenExcept(Set(EverythingElseRootPlan.libraryFoldersMeasuredElsewhere.map { $0.lowercased() })))
            case .documents where root.path == home:
                guard case .childrenExcept(let skipped) = root.kind else {
                    Issue.record("the rest of home is walked by folder")
                    continue
                }
                // The folders other roots walk, and the project folder this home has.
                #expect(skipped.isSuperset(of: ["documents", "pictures", "library", "applications", "developer"]))
            case .otherApps, .protectedCaches, .developer, .appData, .documents:
                #expect(root.kind == .children, "\(root.path)")
            case .trash, .macOS, .systemData:
                Issue.record("\(root.group) has no roots to walk")
            }
        }
    }

    @Test func projectFoldersAreMatchedAsTheDiskSpellsThemAndWalkedOnce() {
        // A case-insensitive disk lists one folder; it must become one root (#175).
        let folders = EverythingElseRootPlan.developerFolders(inHome: home, names: ["developer", "Projects", ".code", "Pictures"])
        #expect(folders.map(\.lastPathComponent) == ["Projects", "developer"])
        let plan = roots(access: .full, homeNames: ["developer"])
        #expect(plan.filter { $0.group == .developer && $0.url.lastPathComponent.lowercased() == "developer" }.map(\.path)
            == ["/Users/alice/developer", "/Users/alice/Library/Developer"])
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
        let plan = roots(access: .full, homeNames: ["Developer"])
        #expect(plan.allSatisfy { !$0.isLockedWithoutAccess })
    }

    @Test func aLimitedScanLocksTheProtectedRootsAndNothingElse() {
        let plan = roots(access: .limited, others: [users.appendingPathComponent("bob")], homeNames: ["Developer"])
        let locked = Set(plan.filter(\.isLockedWithoutAccess).map(\.path))
        let open = Set(plan.filter { !$0.isLockedWithoutAccess }.map(\.path))
        for relative in ["Documents", "Desktop", "Downloads", "Library/Containers", "Library/Group Containers", "Library/Mail", "Library/Messages", "Library"] {
            #expect(locked.contains("/Users/alice/\(relative)"), Comment(rawValue: relative))
        }
        for relative in ["Movies", "Music", "Pictures", "Library/Caches", "Library/Application Support", "Library/Developer", "Developer"] {
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
        for root in plan where root.group == .mediaLibraries || root.group == .mailAndMessages {
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
        #expect(breakdown[.documents]?.isLocked == true)
        #expect(breakdown[.appData]?.isLocked == true)
        #expect(breakdown[.mailAndMessages]?.isLocked == true)
        #expect(breakdown[.protectedCaches]?.isLocked == false)
        #expect(breakdown[.developer]?.isLocked == false)
        // Measured roots still to come, so this group is not finished yet.
        #expect(breakdown[.protectedCaches]?.isFinished == false)
        // Mail and Messages are both locked without access, so that group is done at once.
        #expect(breakdown[.mailAndMessages]?.isFinished == true)
        // No other users on this Mac: nothing to wait for.
        #expect(breakdown[.otherUsers]?.isFinished == true)
    }

    @Test func progressCountsEveryRootTheWalkDealtWith() {
        let support = root(.appData, "/Users/alice/Library/Application Support")
        let caches = root(.protectedCaches, "/Users/alice/Library/Caches")
        let epic = root(.otherApps, "/Users/Shared/Epic Games")
        var measurement = EverythingElseMeasurement(access: .full)
        #expect(measurement.currentRoot == nil)
        measurement.apply(.planned([epic, caches, support]))
        #expect(measurement.finishedRootCount == 0)
        #expect(measurement.currentRoot == epic)

        // Not on this Mac: skipped, which still counts as done.
        measurement.apply(.skipped(epic, locked: false))
        #expect(measurement.finishedRootCount == 1)
        #expect(measurement.currentRoot == caches)
        #expect(measurement.hasFinished(.otherApps))

        measurement.apply(.measured(EverythingElseMeasuredRoot(root: caches, folders: [], looseFileBytes: 0)))
        #expect(measurement.finishedRootCount == 2)
        #expect(measurement.currentRoot == support)
        #expect(!measurement.hasFinished(.appData))
    }

    /// The page counts progress in groups, and only the groups with a root on
    /// this Mac: a group lands as one figure, however many roots it has.
    @Test func progressCountsGroupsWithARootOnThisMac() {
        let support = root(.appData, "/Users/alice/Library/Application Support")
        let containers = root(.appData, "/Users/alice/Library/Containers")
        let caches = root(.protectedCaches, "/Users/alice/Library/Caches")
        var measurement = EverythingElseMeasurement(access: .full)
        #expect(measurement.plannedGroups.isEmpty)

        measurement.apply(.planned([caches, support, containers]))
        #expect(measurement.plannedGroups == [.protectedCaches, .appData])
        #expect(measurement.finishedGroupCount == 0)

        measurement.apply(.measured(EverythingElseMeasuredRoot(root: caches, folders: [], looseFileBytes: 0)))
        #expect(measurement.finishedGroupCount == 1)

        // App Data has two roots; one done is not the group done.
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: support, folders: [], looseFileBytes: 0)))
        #expect(measurement.finishedGroupCount == 1)
        measurement.apply(.skipped(containers, locked: true))
        #expect(measurement.finishedGroupCount == 2)
    }

    /// The ring's figure moves inside a root as its folders are sized, and
    /// its ceiling is where finishing that root would put it.
    @Test func walkFractionMovesInsideARootAndNeverPastItsCeiling() {
        let caches = root(.protectedCaches, "/Users/alice/Library/Caches")
        let support = root(.appData, "/Users/alice/Library/Application Support")
        var measurement = EverythingElseMeasurement(access: .full)
        #expect(measurement.walkFraction == 0)
        #expect(measurement.walkCeiling == 0)

        measurement.apply(.planned([caches, support]))
        #expect(measurement.walkFraction == 0)
        #expect(measurement.walkCeiling == 0.5)

        measurement.apply(.progress(caches, 0.5))
        #expect(measurement.walkFraction == 0.25)
        #expect(measurement.walkCeiling == 0.5)

        // Finishing the root clears its progress and moves the ceiling on.
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: caches, folders: [], looseFileBytes: 0)))
        #expect(measurement.rootProgress.isEmpty)
        #expect(measurement.walkFraction == 0.5)
        #expect(measurement.walkCeiling == 1)

        // Progress for a root that is not the current one changes nothing shown.
        measurement.apply(.progress(caches, 0.9))
        #expect(measurement.walkFraction == 0.5)

        // Chunks report from their own threads: a late, lower figure never moves it back.
        measurement.apply(.progress(support, 0.6))
        measurement.apply(.progress(support, 0.4))
        #expect(measurement.walkFraction == 0.8)

        measurement.isComplete = true
        #expect(measurement.walkFraction == 1)
        #expect(measurement.walkCeiling == 1)
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
        let caches = root(.protectedCaches, "/Users/alice/Library/Caches")
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: caches, folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Caches/com.apple.dt.Xcode", bytes: 4 * gb),
            OverviewSizedItem(path: "/Users/alice/Library/Caches/Splash", bytes: 76 * gb)
        ], looseFileBytes: 0)))
        let breakdown = EverythingElseBreakdown(
            measurement: measurement,
            claimedFirst: [OverviewSizedItem(path: "/Users/alice/Library/Caches/com.apple.dt.Xcode", bytes: 4 * gb)],
            everythingElseBytes: 200 * gb
        )
        #expect(breakdown[.protectedCaches]?.bytes == 76 * gb)
        #expect(breakdown[.protectedCaches]?.folders.map(\.name) == ["Splash"])
    }

    @Test func aSteamGameCountsOnceUnderOtherApps() {
        var measurement = EverythingElseMeasurement(access: .full)
        let common = root(.otherApps, "/Users/alice/Library/Application Support/Steam/steamapps/common")
        let support = root(.appData, "/Users/alice/Library/Application Support")
        // The walk reports App Data first: claim order is by group, not by arrival.
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: support, folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Application Support/Steam", bytes: 80 * gb)
        ], looseFileBytes: 0)))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: common, folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Application Support/Steam/steamapps/common/Hades", bytes: 73 * gb)
        ], looseFileBytes: 0)))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 200 * gb)
        #expect(breakdown[.otherApps]?.bytes == 73 * gb)
        #expect(breakdown[.appData]?.bytes == 7 * gb)
        #expect(breakdown.measuredBytes == 80 * gb)
    }

    @Test func aPhotosLibraryComesOutOfDocumentsAndKeepsItsPlainName() {
        var measurement = EverythingElseMeasurement(access: .full)
        let photos = root(.mediaLibraries, "/Users/alice/Pictures/Photos Library.photoslibrary", .whole)
        let pictures = root(.documents, "/Users/alice/Pictures")
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: photos, totalBytes: 30 * gb)))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: pictures, folders: [
            OverviewSizedItem(path: "/Users/alice/Pictures/Photos Library.photoslibrary", bytes: 30 * gb),
            OverviewSizedItem(path: "/Users/alice/Pictures/Scans", bytes: 2 * gb)
        ], looseFileBytes: 1 * gb)))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 200 * gb)
        #expect(breakdown[.mediaLibraries]?.bytes == 30 * gb)
        #expect(breakdown[.mediaLibraries]?.folders.map(\.name) == ["Photos Library"])
        #expect(breakdown[.documents]?.bytes == 3 * gb)
        #expect(breakdown[.documents]?.folders.map(\.name) == ["Scans"])
        // The loose files join the smaller line.
        #expect(breakdown[.documents]?.smallerBytes == 1 * gb)
        #expect(breakdown[.documents]?.smallerFolderCount == 0)
    }

    @Test func aLargeFileInsideAFolderIsNotCountedAgain() {
        var measurement = EverythingElseMeasurement(access: .full)
        let movies = root(.documents, "/Users/alice/Movies")
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
        #expect(breakdown[.documents]?.bytes == 9 * gb)
        #expect(breakdown[.documents]?.folders.first?.bytes == 8 * gb)
        #expect(breakdown[.documents]?.smallerBytes == 1 * gb)
    }

    @Test func devToolsKeepsItsPartOfAHiddenFolder() {
        var measurement = EverythingElseMeasurement(access: .full)
        let hidden = root(.developer, "/Users/alice", .hiddenChildren)
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: hidden, folders: [
            OverviewSizedItem(path: "/Users/alice/.npm", bytes: 6 * gb),
            OverviewSizedItem(path: "/Users/alice/.cargo", bytes: 3 * gb)
        ], looseFileBytes: 0)))
        let breakdown = EverythingElseBreakdown(
            measurement: measurement,
            claimedFirst: [OverviewSizedItem(path: "/Users/alice/.npm/_cacache", bytes: 5 * gb)],
            everythingElseBytes: 200 * gb
        )
        #expect(breakdown[.developer]?.bytes == 4 * gb)
        #expect(breakdown[.developer]?.folders.map(\.name) == [".cargo", ".npm"])
    }

    @Test func theRestOfHomeNeverSwallowsTheFoldersInsideIt() {
        // Two roots sit on the home folder itself. Neither claims home as a path,
        // so the folders walked under home keep their own figures.
        var measurement = EverythingElseMeasurement(access: .full)
        let hidden = root(.developer, "/Users/alice", .hiddenChildren)
        let rest = root(.documents, "/Users/alice", .childrenExcept(["documents"]))
        let documents = root(.documents, "/Users/alice/Documents")
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: hidden, folders: [
            OverviewSizedItem(path: "/Users/alice/.cargo", bytes: 3 * gb)
        ], looseFileBytes: 0)))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: documents, folders: [
            OverviewSizedItem(path: "/Users/alice/Documents/Work", bytes: 5 * gb)
        ], looseFileBytes: 0)))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: rest, folders: [
            OverviewSizedItem(path: "/Users/alice/Tabletop", bytes: 28 * gb)
        ], looseFileBytes: 0)))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 200 * gb)
        #expect(breakdown[.developer]?.bytes == 3 * gb)
        #expect(breakdown[.documents]?.bytes == 33 * gb)
        #expect(Set(breakdown[.documents]?.folders.map(\.name) ?? []) == ["Tabletop", "Work"])
    }

    // MARK: The floor, the remainder and the cap

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
        // The biggest of them are kept by name for the popover.
        #expect(appData?.smallerFolders.count == EverythingElseBreakdown.listedSmallerFolderCount)
        #expect(appData?.smallerBytes == smaller)
        #expect(appData?.bytes == 12 * gb + smaller)
    }

    @Test func systemDataIsWhatLetsThePageAddUp() {
        var measurement = EverythingElseMeasurement(access: .full)
        let support = root(.appData, "/Users/alice/Library/Application Support")
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: support, folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Application Support/Big", bytes: 60 * gb)
        ], looseFileBytes: 0)))
        measurement.apply(.macOS(14 * gb))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 100 * gb, trashBytes: 3 * gb)
        #expect(breakdown.macOSBytes == 14 * gb)
        #expect(breakdown.trashBytes == 3 * gb)
        #expect(breakdown.systemDataBytes == 23 * gb)
        #expect(breakdown.bytes(for: .appData) == 60 * gb)
        #expect(breakdown.bytes(for: .trash) == 3 * gb)
        #expect(breakdown.bytes(for: .systemData) == 23 * gb)
        let total = EverythingElseGroup.allCases.reduce(Int64(0)) { $0 + breakdown.bytes(for: $1) }
        #expect(total == 100 * gb)
        #expect(!breakdown.isApproximate)
    }

    @Test func theGroupsNeverAddUpToMoreThanEverythingElse() {
        // Clones and purgeable files can make the walk overstate (#131), and a
        // saved category total has no paths to take out.
        var measurement = EverythingElseMeasurement(access: .full)
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: root(.protectedCaches, "/Users/alice/Library/Caches"), folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Caches/Splash", bytes: 70 * gb)
        ], looseFileBytes: 0)))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: root(.documents, "/Users/alice/Downloads"), folders: [
            OverviewSizedItem(path: "/Users/alice/Downloads/Old", bytes: 50 * gb)
        ], looseFileBytes: 0)))
        measurement.apply(.macOS(14 * gb))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 100 * gb, trashBytes: 5 * gb)
        // Held in claim order: Protected Caches keeps its 70 GB, Documents the 30 left.
        #expect(breakdown.bytes(for: .protectedCaches) == 70 * gb)
        #expect(breakdown.bytes(for: .documents) == 30 * gb)
        #expect(breakdown.bytes(for: .macOS) == 0)
        #expect(breakdown.bytes(for: .trash) == 0)
        #expect(breakdown.systemDataBytes == 0)
        #expect(breakdown.isApproximate)
        let total = EverythingElseGroup.allCases.reduce(Int64(0)) { $0 + breakdown.bytes(for: $1) }
        #expect(total == 100 * gb)
    }

    @Test func aSavedCategoryTotalMarksTheBreakdownApproximate() {
        let measurement = EverythingElseMeasurement(access: .full)
        let exact = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 100 * gb)
        let saved = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 100 * gb, includesRecordedFigures: true)
        #expect(!exact.isApproximate)
        #expect(saved.isApproximate)
    }

    @Test func groupsSortBiggestFirstWithEmptyOnesInClaimOrder() {
        var measurement = EverythingElseMeasurement(access: .full)
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: root(.documents, "/Users/alice/Documents"), folders: [
            OverviewSizedItem(path: "/Users/alice/Documents/Work", bytes: 50 * gb)
        ], looseFileBytes: 0)))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: root(.appData, "/Users/alice/Library/Containers"), folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Containers/x", bytes: 70 * gb)
        ], looseFileBytes: 0)))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 200 * gb)
        #expect(breakdown.measuredGroupsBySize.prefix(2) == [.appData, .documents])
        #expect(Array(breakdown.measuredGroupsBySize.dropFirst(2)) == [
            .otherApps, .mediaLibraries, .mailAndMessages, .protectedCaches, .developer, .otherUsers
        ])
    }

    @Test func anExcludedFolderLeavesTheBreakdown() {
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

    // MARK: The page's sections

    private func sampleBreakdown(trashBytes: Int64? = 3_000_000_000) -> EverythingElseBreakdown {
        var measurement = EverythingElseMeasurement(access: .full)
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: root(.mediaLibraries, "/Users/alice/Pictures/Photos Library.photoslibrary", .whole), totalBytes: 48 * gb)))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: root(.developer, "/Users/alice/Developer"), folders: [
            OverviewSizedItem(path: "/Users/alice/Developer/engine", bytes: 120 * gb),
            OverviewSizedItem(path: "/Users/alice/Developer/site", bytes: 2 * gb),
            OverviewSizedItem(path: "/Users/alice/Developer/tiny", bytes: 300_000_000)
        ], looseFileBytes: 0)))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: root(.documents, "/Users/alice/Documents"), folders: [
            OverviewSizedItem(path: "/Users/alice/Documents/Work", bytes: 25 * gb)
        ], looseFileBytes: 0)))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: root(.protectedCaches, "/Users/alice/Library/Caches"), folders: [
            OverviewSizedItem(path: "/Users/alice/Library/Caches/Splash", bytes: 21 * gb)
        ], looseFileBytes: 0)))
        measurement.apply(.macOS(14 * gb))
        return EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 300 * gb, trashBytes: trashBytes)
    }

    @Test func theSectionsFollowWhatYouCanDoAndListTheBiggestFirst() {
        let sections = EverythingElseSection.sections(for: sampleBreakdown())
        #expect(sections.map(\.bucket) == [.managedInApps, .yourFiles, .leftAlone, .managedByMacOS])
        let files = sections[1]
        // Rows from both groups, mixed by size, and the smaller folders in one line.
        #expect(files.items.map(\.id) == [
            "/Users/alice/Developer/engine", "/Users/alice/Documents/Work", "/Users/alice/Developer/site", "smaller.developer"
        ])
        #expect(files.bytes == (120 + 25 + 2) * gb + 300_000_000)
        let apps = sections[0]
        #expect(apps.items.map(\.group) == [.mediaLibraries, .trash])
        let macOS = sections[3]
        #expect(macOS.items.map(\.group) == [.systemData, .macOS])
    }

    @Test func anUnreadableTrashAsksForAccessAndSortsLast() {
        let sections = EverythingElseSection.sections(for: sampleBreakdown(trashBytes: nil))
        let apps = sections.first { $0.bucket == .managedInApps }
        #expect(apps?.items.last?.group == .trash)
        #expect(apps?.items.last?.isLocked == true)
    }

    @Test func pickingATileListsThatGroupAlone() {
        let sections = EverythingElseSection.sections(for: sampleBreakdown(), onlyGroup: .developer)
        #expect(sections.map(\.bucket) == [.yourFiles])
        #expect(sections.first?.items.allSatisfy { $0.group == .developer } == true)
        #expect(sections.first?.bytes == 122 * gb + 300_000_000)
    }

    @Test func tilesTooSmallToLabelJoinTheSmallerFoldersTile() {
        let rows = [
            EverythingElseItem(group: .appData, kind: .folder(EverythingElseFolder(path: "/a/Android", bytes: 29 * gb, measuredBytes: 29 * gb, group: .appData)), bytes: 29 * gb),
            EverythingElseItem(group: .appData, kind: .folder(EverythingElseFolder(path: "/a/Tiny", bytes: 1 * gb, measuredBytes: 1 * gb, group: .appData)), bytes: 1 * gb),
            EverythingElseItem(group: .appData, kind: .folder(EverythingElseFolder(path: "/a/Mid", bytes: 8 * gb, measuredBytes: 8 * gb, group: .appData)), bytes: 8 * gb),
            EverythingElseItem(group: .appData, kind: .smaller(count: 40, biggest: [
                EverythingElseFolder(path: "/a/Small", bytes: 900_000_000, measuredBytes: 900_000_000, group: .appData)
            ]), bytes: 2 * gb)
        ]
        let rolled = EverythingElseSection.rollingUpTinyRows(rows, group: .appData, below: Double(5 * gb))
        #expect(rolled.map(\.id) == ["/a/Android", "/a/Mid", "smaller.appData"])
        // The tiny folder joins the 40 smaller ones, and leads their list by size.
        guard case .smaller(let count, let biggest) = rolled.last?.kind else {
            Issue.record("the last tile is the smaller folders")
            return
        }
        #expect(count == 41)
        #expect(biggest.map(\.name) == ["Tiny", "Small"])
        #expect(rolled.last?.bytes == 3 * gb)
        // The biggest row keeps its tile however small the group is.
        let alone = EverythingElseSection.rollingUpTinyRows(Array(rows.prefix(2)), group: .appData, below: Double(100 * gb))
        #expect(alone.first?.id == "/a/Android")
    }

    @Test func aGroupContainerDropsItsTeamIDFromTheName() {
        func folder(_ name: String) -> EverythingElseFolder {
            EverythingElseFolder(path: "/Users/alice/Library/Group Containers/\(name)", bytes: gb, measuredBytes: gb, group: .appData)
        }
        #expect(folder("HUAQ24HBR6.dev.orbstack").displayName == "dev.orbstack")
        #expect(folder("group.com.apple.notes").displayName == "group.com.apple.notes")
        #expect(folder("Android").displayName == "Android")
    }

    // MARK: Hints

    @Test func xcodesFoldersPointToDevTools() {
        let hint = EverythingElseFolderHint.hint(
            for: "/Users/alice/Library/Developer/CoreSimulator",
            group: .developer,
            home: home,
            steamGames: [:]
        )
        #expect(hint?.action == .showInDevTools)
    }

    /// A dot folder the uninstaller lists as a command-line tool points there,
    /// and only that folder (#225).
    @Test func commandLineToolFolderPointsToTheUninstaller() throws {
        let tools = ["/Users/alice/.hermes": "hermes"]
        let hint = try #require(EverythingElseFolderHint.hint(
            for: "/Users/alice/.hermes",
            group: .developer,
            home: home,
            steamGames: [:],
            commandLineTools: tools
        ))
        #expect(hint.action == .showInCommandLineTools)
        #expect(hint.steps.hasPrefix("hermes"))
        #expect(EverythingElseFolderHint.hint(
            for: "/Users/alice/.nvm", group: .developer, home: home, steamGames: [:], commandLineTools: tools
        ) == nil)
    }

    /// Removals that skip the Trash say "permanently", the word the rest of
    /// the app uses for them.
    @Test func steamsUninstallSaysItIsPermanent() throws {
        let game = SteamGame(appID: "1145360", name: "Hades", installPath: "/Users/alice/Library/Application Support/Steam/steamapps/common/Hades")
        let hint = try #require(EverythingElseFolderHint.hint(
            for: game.installPath,
            group: .otherApps,
            home: home,
            steamGames: [game.installPath: game]
        ))
        #expect(hint.steps.contains("permanently"))
        #expect(!hint.steps.contains("for good"))
        #expect(!hint.steps.contains("keeps your saves"))
    }
}

/// The walk itself, on a temporary folder: which children it sizes, what it
/// leaves alone, and that a limited scan never reads a protected root.
@Suite("Everything else measurer")
struct EverythingElseMeasurerTests {
    private func walk(access: ScanAccess, home: URL, users: URL) async -> [EverythingElseMeasureEvent] {
        var events: [EverythingElseMeasureEvent] = []
        let stream = EverythingElseMeasurer().measureStream(
            access: access,
            home: home,
            steamLibraries: [],
            otherUserHomes: [],
            usersFolder: users,
            readsSystemVolume: false
        )
        for await event in stream {
            events.append(event)
        }
        return events
    }

    private func measured(_ events: [EverythingElseMeasureEvent]) -> [EverythingElseMeasuredRoot] {
        events.compactMap { event in
            if case .measured(let root) = event { return root }
            return nil
        }
    }

    @Test func measuresTheFoldersInsideARootAndTheLooseFilesBesideThem() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("purge-ee-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let users = base.appendingPathComponent("Users", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("App"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: support.appendingPathComponent("App/data.bin"))
        try Data(count: 50_000).write(to: support.appendingPathComponent("loose.plist"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".tool"), withIntermediateDirectories: true)
        try Data(count: 120_000).write(to: home.appendingPathComponent(".tool/cache.bin"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: home.appendingPathComponent("visible.txt"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Tabletop"), withIntermediateDirectories: true)
        try Data(count: 80_000).write(to: home.appendingPathComponent("Tabletop/map.png"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Developer/engine"), withIntermediateDirectories: true)
        try Data(count: 90_000).write(to: home.appendingPathComponent("Developer/engine/main.swift"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Unity"), withIntermediateDirectories: true)
        try Data(count: 70_000).write(to: home.appendingPathComponent("Library/Unity/cache.bin"))

        let events = await walk(access: .full, home: home, users: users)
        let roots = measured(events)

        let appData = try #require(roots.first { $0.root.group == .appData && $0.root.url.lastPathComponent == "Application Support" })
        #expect(appData.folders.map { $0.path.hasSuffix("/App") } == [true])
        #expect(appData.folders.first.map { $0.bytes >= 300_000 } == true)
        #expect(appData.looseFileBytes >= 50_000)

        // The rest of Library: Unity, but not Application Support, which has its own root.
        let library = try #require(roots.first { $0.root.group == .appData && $0.root.url.lastPathComponent == "Library" })
        #expect(library.folders.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["Unity"])

        // The home folder's dot folders, without the Trash or any loose file.
        let hidden = try #require(roots.first { $0.root.group == .developer && $0.root.kind == .hiddenChildren })
        #expect(hidden.folders.map { URL(fileURLWithPath: $0.path).lastPathComponent } == [".tool"])
        #expect(hidden.looseFileBytes == 0)

        // A project folder is walked by project.
        let projects = try #require(roots.first { $0.root.group == .developer && $0.root.url.lastPathComponent == "Developer" })
        #expect(projects.folders.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["engine"])

        // The rest of home: Tabletop, but not Library or Developer.
        let rest = try #require(roots.first { $0.root.group == .documents && $0.root.path == OverviewSizedItem.normalized(home.path) })
        #expect(rest.folders.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["Tabletop"])
        #expect(rest.looseFileBytes == 0)

        // Roots that are not there are skipped, not measured as empty.
        let skipped = events.filter { if case .skipped(_, locked: false) = $0 { return true } else { return false } }
        #expect(!skipped.isEmpty)
        #expect(!events.contains { if case .macOS = $0 { return true } else { return false } })
    }

    @Test func aLimitedScanSkipsProtectedRootsWithoutReadingThem() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("purge-ee-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let users = base.appendingPathComponent("Users", isDirectory: true)
        try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents/Work"), withIntermediateDirectories: true)
        try Data(count: 200_000).write(to: home.appendingPathComponent("Documents/Work/a.bin"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Movies/Trips"), withIntermediateDirectories: true)
        try Data(count: 200_000).write(to: home.appendingPathComponent("Movies/Trips/b.mov"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Calendars"), withIntermediateDirectories: true)

        let events = await walk(access: .limited, home: home, users: users)
        let lockedPaths = events.compactMap { event -> String? in
            if case .skipped(let root, locked: true) = event { return root.path }
            return nil
        }
        let measuredPaths = measured(events).map(\.root.path)
        // The walk spells a temporary home `/private/var/…`; normalize both sides.
        let documents = OverviewSizedItem.normalized(home.appendingPathComponent("Documents").path)
        let movies = OverviewSizedItem.normalized(home.appendingPathComponent("Movies").path)
        let library = OverviewSizedItem.normalized(home.appendingPathComponent("Library").path)
        #expect(lockedPaths.contains(documents))
        #expect(!measuredPaths.contains(documents))
        #expect(measuredPaths.contains(movies))
        // The rest of Library holds folders macOS guards with prompts of its own.
        #expect(lockedPaths.contains(library))
        #expect(!measuredPaths.contains(library))
    }
}

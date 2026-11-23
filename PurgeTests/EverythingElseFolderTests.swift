import Foundation
import Testing
@testable import Purge

/// Opening a folder on the Everything else map (#437): which folders open, how
/// an opened folder's tiles are counted so they add up to the tile that was
/// opened, the sizer on a real temporary folder, and the store's path down
/// and back up. The store tests use `FakeScans`, so nothing here walks this Mac.
@Suite("Everything else folders")
struct EverythingElseFolderTests {
    private static let gb: Int64 = 1_000_000_000
    private static let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    private static func root(_ group: EverythingElseGroup, _ path: String, kind: EverythingElseMeasureRoot.Kind = .children) -> EverythingElseMeasureRoot {
        EverythingElseMeasureRoot(group: group, url: URL(fileURLWithPath: path, isDirectory: true), kind: kind, isLockedWithoutAccess: false)
    }

    private static func item(_ path: String, _ bytes: Int64) -> OverviewSizedItem {
        OverviewSizedItem(path: path, bytes: bytes)
    }

    // MARK: Which folders open

    @Test func onlyTheGroupsThatListFoldersOpen() {
        let opening = EverythingElseGroup.allCases.filter(\.opensFolders)
        #expect(opening == [.otherApps, .protectedCaches, .developer, .appData, .documents])
        for group in EverythingElseGroup.allCases {
            let url = Self.home.appendingPathComponent("Documents/Work")
            #expect(EverythingElseFolderOpening.canOpen(url, group: group, access: .full, home: Self.home) == group.opensFolders)
        }
    }

    @Test func aMediaLibraryNeverOpensWhereverItIs() {
        for name in ["Old.photoslibrary", "Photos Library.photoslibrary", "Trip.imovielibrary", "GarageBand", "Show.theater"] {
            let url = Self.home.appendingPathComponent("Documents/Archive/\(name)")
            #expect(!EverythingElseFolderOpening.canOpen(url, group: .documents, access: .full, home: Self.home), Comment(rawValue: name))
        }
    }

    @Test func aLimitedScanOpensOnlyWhereTheWalkMayRead() {
        let addressBook = Self.home.appendingPathComponent("Library/Application Support/AddressBook")
        #expect(EverythingElseFolderOpening.canOpen(addressBook, group: .appData, access: .full, home: Self.home))
        #expect(!EverythingElseFolderOpening.canOpen(addressBook, group: .appData, access: .limited, home: Self.home))
        let work = Self.home.appendingPathComponent("Developer/app")
        #expect(EverythingElseFolderOpening.canOpen(work, group: .developer, access: .limited, home: Self.home))
    }

    // MARK: Counting

    /// A project's `node_modules`, which Dev Tools lists, came out of the
    /// project's tile, so it comes out of the opened project too.
    @Test func whatACategoryCountedStaysOutOfTheOpenedFolder() throws {
        let documents = Self.root(.documents, "/Users/tester/Documents")
        var measurement = EverythingElseMeasurement(access: .full)
        measurement.apply(.measured(EverythingElseMeasuredRoot(
            root: documents,
            folders: [Self.item("/Users/tester/Documents/App", 100 * Self.gb)],
            looseFileBytes: 0
        )))
        measurement.isComplete = true
        let claimedFirst = [Self.item("/Users/tester/Documents/App/node_modules", 30 * Self.gb)]
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: claimedFirst, everythingElseBytes: 500 * Self.gb)
        let tile = try #require(breakdown[.documents]?.folders.first)
        #expect(tile.bytes == 70 * Self.gb)

        let contents = EverythingElseFolderContents(
            path: tile.path,
            folders: [
                Self.item("/Users/tester/Documents/App/node_modules", 30 * Self.gb),
                Self.item("/Users/tester/Documents/App/src", 50 * Self.gb)
            ],
            openablePaths: [],
            looseFileBytes: 20 * Self.gb
        )
        let level = EverythingElseFolderLevel(
            folder: tile,
            contents: contents,
            claims: measurement.claims(before: tile.path, claimedFirst: claimedFirst)
        )
        #expect(level.bytes == tile.bytes)
        #expect(level.items.map(\.id) == ["/Users/tester/Documents/App/src", "smaller.documents"])
        #expect(level.items.map(\.bytes) == [50 * Self.gb, 20 * Self.gb])
        #expect(level.items.allSatisfy { $0.group == .documents })
    }

    /// A Steam game counts under Other Apps, so opening Steam's App Data
    /// folder shows only the rest of it.
    @Test func whatAnEarlierGroupCountedStaysOutToo() throws {
        let support = "/Users/tester/Library/Application Support"
        let common = Self.root(.otherApps, "\(support)/Steam/steamapps/common")
        let appSupport = Self.root(.appData, support)
        var measurement = EverythingElseMeasurement(access: .full)
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: common, folders: [
            Self.item("\(support)/Steam/steamapps/common/Game", 40 * Self.gb)
        ], looseFileBytes: 0)))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: appSupport, folders: [
            Self.item("\(support)/Steam", 50 * Self.gb),
            Self.item("\(support)/Other", 2 * Self.gb)
        ], looseFileBytes: 0)))
        measurement.isComplete = true
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 500 * Self.gb)
        let steam = try #require(breakdown[.appData]?.folders.first { $0.path.hasSuffix("/Steam") })
        #expect(steam.bytes == 10 * Self.gb)

        let contents = EverythingElseFolderContents(
            path: steam.path,
            folders: [
                Self.item("\(support)/Steam/steamapps", 45 * Self.gb),
                Self.item("\(support)/Steam/config", 5 * Self.gb)
            ],
            openablePaths: ["\(support)/Steam/steamapps", "\(support)/Steam/config"],
            looseFileBytes: 0
        )
        let claims = measurement.claims(before: steam.path, claimedFirst: [])
        let level = EverythingElseFolderLevel(folder: steam, contents: contents, claims: claims)
        #expect(level.bytes == steam.bytes)
        #expect(level.items.map(\.bytes) == [5 * Self.gb, 5 * Self.gb])

        // One level further down, the same claims still take the game out.
        let steamapps = try #require(level.items.compactMap { item -> EverythingElseFolder? in
            if case .folder(let folder) = item.kind, folder.path.hasSuffix("/steamapps") { return folder }
            return nil
        }.first)
        let inner = EverythingElseFolderContents(
            path: steamapps.path,
            folders: [Self.item("\(support)/Steam/steamapps/common", 44 * Self.gb)],
            openablePaths: [],
            looseFileBytes: 1 * Self.gb
        )
        let innerLevel = EverythingElseFolderLevel(folder: steamapps, contents: inner, claims: claims)
        #expect(innerLevel.bytes == steamapps.bytes)
    }

    @Test func theFolderAboveTheOpenedOneIsNeverClaimed() {
        // The rest-of-Library root's loose files claim `~/Library` itself; a
        // folder inside it must still have its own tiles.
        let library = Self.root(.appData, "/Users/tester/Library", kind: .children)
        var measurement = EverythingElseMeasurement(access: .full)
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: library, folders: [
            Self.item("/Users/tester/Library/Fonts", 3 * Self.gb)
        ], looseFileBytes: 1 * Self.gb)))
        measurement.isComplete = true
        let claims = measurement.claims(before: "/Users/tester/Library/Fonts", claimedFirst: [])
        let folder = EverythingElseFolder(path: "/Users/tester/Library/Fonts", bytes: 3 * Self.gb, measuredBytes: 3 * Self.gb, group: .appData)
        let level = EverythingElseFolderLevel(
            folder: folder,
            contents: EverythingElseFolderContents(
                path: folder.path,
                folders: [Self.item("/Users/tester/Library/Fonts/Big", 3 * Self.gb)],
                openablePaths: [],
                looseFileBytes: 0
            ),
            claims: claims
        )
        #expect(level.bytes == 3 * Self.gb)
    }

    // MARK: The sizer

    @Test func theSizerListsHiddenFoldersAndNeverFollowsALink() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-ee-folder-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-ee-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: outside)
        }
        let src = base.appendingPathComponent("src", isDirectory: true)
        let git = base.appendingPathComponent(".git", isDirectory: true)
        let library = base.appendingPathComponent("Old.photoslibrary", isDirectory: true)
        for folder in [src, git, library, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data(count: 200_000).write(to: src.appendingPathComponent("a.bin"))
        try Data(count: 300_000).write(to: git.appendingPathComponent("pack"))
        try Data(count: 50_000).write(to: base.appendingPathComponent("notes.txt"))
        try Data(count: 5_000_000).write(to: outside.appendingPathComponent("big.bin"))
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: outside)

        let contents = try #require(EverythingElseFolderSizer.contents(
            of: base,
            group: .documents,
            access: .full,
            home: FileManager.default.homeDirectoryForCurrentUser,
            progress: { _ in }
        ))
        let byName = Dictionary(uniqueKeysWithValues: contents.folders.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.bytes) })
        #expect(Set(byName.keys) == ["src", ".git", "Old.photoslibrary"])
        #expect((byName["src"] ?? 0) >= 200_000)
        #expect((byName[".git"] ?? 0) >= 300_000)
        // The link is its own few bytes; the folder it points at is not counted.
        #expect(contents.looseFileBytes >= 50_000)
        #expect(contents.looseFileBytes < 1_000_000)
        #expect(contents.totalBytes < 5_000_000)
        // A media library is a tile but never opens.
        let openable = Set(contents.openablePaths.map { URL(fileURLWithPath: $0).lastPathComponent })
        #expect(openable == ["src", ".git"])
    }

    @Test func theSizerReturnsNothingForAFolderItCannotList() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("purge-ee-missing-\(UUID().uuidString)")
        #expect(EverythingElseFolderSizer.contents(of: missing, group: .documents, access: .full, home: Self.home, progress: { _ in }) == nil)
    }
}

/// The store's path down into folders and back up (#437).
@MainActor
@Suite("Everything else folders in the store")
struct EverythingElseFolderStoreTests {
    private let gb: Int64 = 1_000_000_000
    private let base = "/Users/tester/Documents"

    /// A store with one walk done: Documents holds Work (60 GB) and Photos (20 GB).
    private func measuredStore(_ fake: FakeScans) async -> PurgeStore {
        fake.hasAccess = true
        let root = EverythingElseMeasureRoot(group: .documents, url: URL(fileURLWithPath: base, isDirectory: true), kind: .children, isLockedWithoutAccess: false)
        fake.everythingElseEvents = [
            .planned([root]),
            .measured(EverythingElseMeasuredRoot(root: root, folders: [
                OverviewSizedItem(path: "\(base)/Work", bytes: 60 * gb),
                OverviewSizedItem(path: "\(base)/Photos", bytes: 20 * gb)
            ], looseFileBytes: 0)),
            .macOS(14 * gb)
        ]
        fake.everythingElseFolders = [
            "\(base)/Work": EverythingElseFolderContents(
                path: "\(base)/Work",
                folders: [
                    OverviewSizedItem(path: "\(base)/Work/Renders", bytes: 50 * gb),
                    OverviewSizedItem(path: "\(base)/Work/Source", bytes: 8 * gb)
                ],
                openablePaths: ["\(base)/Work/Renders"],
                looseFileBytes: 2 * gb
            ),
            "\(base)/Work/Renders": EverythingElseFolderContents(
                path: "\(base)/Work/Renders",
                folders: [OverviewSizedItem(path: "\(base)/Work/Renders/2023", bytes: 50 * gb)],
                openablePaths: [],
                looseFileBytes: 0
            )
        ]
        let store = fake.makeStore()
        store.showEverythingElsePage()
        _ = await eventually { store.everythingElsePhase == .ready }
        return store
    }

    private func tile(_ store: PurgeStore, _ name: String) throws -> EverythingElseFolder {
        let breakdown = try #require(store.everythingElseBreakdown(totalBytes: 1_000 * gb, freeBytes: 100 * gb, trashBytes: 0))
        return try #require(breakdown[.documents]?.folders.first { $0.path.hasSuffix("/\(name)") })
    }

    private func child(_ level: EverythingElseFolderLevel?, _ name: String) throws -> EverythingElseFolder {
        let level = try #require(level)
        return try #require(level.items.compactMap { item -> EverythingElseFolder? in
            if case .folder(let folder) = item.kind, folder.path.hasSuffix("/\(name)") { return folder }
            return nil
        }.first)
    }

    @Test func openingAFolderSizesItThenGoingBackUpKeepsWhatWasSized() async throws {
        let fake = FakeScans()
        let store = await measuredStore(fake)
        #expect(store.everythingElsePhase == .ready)
        let work = try tile(store, "Work")
        #expect(store.everythingElseCanOpen(work))

        store.openEverythingElseFolder(work)
        // A quick sizing puts the folder on the map with its tiles, never
        // without them.
        #expect(await eventually { !store.everythingElseOpenFolders.isEmpty })
        #expect(store.everythingElseOpenFolders.map(\.path) == ["\(base)/Work"])
        #expect(store.everythingElseOpenLevel() != nil)
        #expect(store.everythingElseFolderSizing == nil)
        #expect(fake.everythingElseFolderRequests.map(\.path) == ["\(base)/Work"])
        #expect(fake.everythingElseFolderRequests.map(\.access) == [.full])
        let level = try #require(store.everythingElseOpenLevel())
        #expect(level.bytes == work.bytes)

        // Only a folder the sizing found it could open goes further.
        let renders = try child(level, "Renders")
        let source = try child(level, "Source")
        #expect(store.everythingElseCanOpen(renders))
        #expect(!store.everythingElseCanOpen(source))
        store.openEverythingElseFolder(source)
        #expect(store.everythingElseOpenFolders.count == 1)

        // Renders holds one folder, but it can't open, so the path stops here.
        store.openEverythingElseFolder(renders)
        #expect(await eventually { store.everythingElseOpenLevel()?.folder.path == "\(base)/Work/Renders" })
        #expect(store.everythingElseOpenFolders.count == 2)
        #expect(store.everythingElseOpenLevel()?.items.count == 1)

        // Back up one, then into Renders again: no second sizing.
        store.closeEverythingElseFolders(keeping: 1)
        #expect(store.everythingElseOpenLevel()?.folder.path == "\(base)/Work")
        store.openEverythingElseFolder(renders)
        #expect(store.everythingElseOpenLevel()?.folder.path == "\(base)/Work/Renders")
        #expect(fake.everythingElseFolderRequests.count == 2)

        store.closeEverythingElseFolders(keeping: 0)
        #expect(store.everythingElseOpenFolders.isEmpty)
        #expect(store.everythingElseOpenLevel() == nil)
        fake.cleanUp()
    }

    /// A slow sizing leaves the map alone for a moment, then opens the folder
    /// as one tile under the glass until its tiles land.
    @Test func aSlowSizingOpensTheFolderAfterAMoment() async throws {
        let fake = FakeScans()
        let store = await measuredStore(fake)
        fake.holdsEverythingElseFolders = true
        store.openEverythingElseFolder(try tile(store, "Work"))
        #expect(store.everythingElseOpenFolders.isEmpty)
        #expect(store.everythingElseFolderSizing?.path == "\(base)/Work")
        #expect(await eventually { !store.everythingElseOpenFolders.isEmpty })
        #expect(store.everythingElseOpenLevel() == nil)
        fake.finishHeldEverythingElseFolders()
        #expect(await eventually { store.everythingElseOpenLevel() != nil })
        #expect(store.everythingElseOpenFolders.map(\.path) == ["\(base)/Work"])
        fake.cleanUp()
    }

    /// A folder whose content is nearly all one folder that opens is passed
    /// through, so `Metadata/CoreSpotlight` is one click. Going back up never
    /// stops at the folder passed through: its level is one tile filling the
    /// map, with nothing to zoom back out to.
    @Test func aFolderHoldingOneFolderOpensThroughToIt() async throws {
        let fake = FakeScans()
        let store = await measuredStore(fake)
        fake.everythingElseFolders["\(base)/Photos"] = EverythingElseFolderContents(
            path: "\(base)/Photos",
            folders: [OverviewSizedItem(path: "\(base)/Photos/Library", bytes: 20 * gb)],
            openablePaths: ["\(base)/Photos/Library"],
            // A `.DS_Store`'s worth of loose files doesn't stop it.
            looseFileBytes: 8_192
        )
        fake.everythingElseFolders["\(base)/Photos/Library"] = EverythingElseFolderContents(
            path: "\(base)/Photos/Library",
            folders: [
                OverviewSizedItem(path: "\(base)/Photos/Library/2024", bytes: 12 * gb),
                OverviewSizedItem(path: "\(base)/Photos/Library/2025", bytes: 8 * gb)
            ],
            openablePaths: [],
            looseFileBytes: 0
        )
        store.openEverythingElseFolder(try tile(store, "Photos"))
        #expect(await eventually { !store.everythingElseOpenFolders.isEmpty })
        #expect(store.everythingElseOpenFolders.map(\.path) == ["\(base)/Photos", "\(base)/Photos/Library"])
        #expect(store.everythingElseOpenLevel()?.items.count == 2)
        #expect(fake.everythingElseFolderRequests.map(\.path) == ["\(base)/Photos", "\(base)/Photos/Library"])

        #expect(store.everythingElsePassedThroughFolders() == ["\(base)/Photos"])

        store.closeEverythingElseFolders(keeping: 1)
        #expect(store.everythingElseOpenFolders.isEmpty)

        // Opening it again passes through again, from what was sized.
        store.openEverythingElseFolder(try tile(store, "Photos"))
        #expect(await eventually { store.everythingElseOpenFolders.count == 2 })
        #expect(fake.everythingElseFolderRequests.count == 2)

        // A new walk forgets it with the sizes.
        store.measureEverythingElseAgain()
        #expect(await eventually { store.everythingElsePhase == .ready })
        #expect(store.everythingElsePassedThroughFolders().isEmpty)
        fake.cleanUp()
    }

    /// Excluding the one folder a folder held stops it passing through, and
    /// the excluded folder's space stays in the level, in its loose files, so
    /// the level still adds up to the tile that was opened.
    @Test func excludingTheFolderPassedThroughToKeepsTheLevelWhole() async throws {
        let fake = FakeScans()
        let store = await measuredStore(fake)
        fake.everythingElseFolders["\(base)/Photos"] = EverythingElseFolderContents(
            path: "\(base)/Photos",
            folders: [OverviewSizedItem(path: "\(base)/Photos/Library", bytes: 20 * gb)],
            openablePaths: ["\(base)/Photos/Library"],
            looseFileBytes: 0
        )
        fake.everythingElseFolders["\(base)/Photos/Library"] = EverythingElseFolderContents(
            path: "\(base)/Photos/Library",
            folders: [OverviewSizedItem(path: "\(base)/Photos/Library/2024", bytes: 20 * gb)],
            openablePaths: [],
            looseFileBytes: 0
        )
        let photos = try tile(store, "Photos")
        store.openEverythingElseFolder(photos)
        #expect(await eventually { store.everythingElseOpenFolders.count == 2 })
        #expect(store.everythingElsePassedThroughFolders() == ["\(base)/Photos"])

        // Photos was passed through, so going up from Library goes past it.
        let library = try #require(store.everythingElseOpenFolders.last)
        store.hideFromEverythingElse(library)
        #expect(store.everythingElseOpenFolders.isEmpty)

        // Opened again, it no longer passes through: Library has no tile.
        store.openEverythingElseFolder(try tile(store, "Photos"))
        #expect(await eventually { !store.everythingElseOpenFolders.isEmpty })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(store.everythingElseOpenFolders.map(\.path) == ["\(base)/Photos"])
        #expect(store.everythingElsePassedThroughFolders().isEmpty)
        let level = try #require(store.everythingElseOpenLevel())
        #expect(level.bytes == photos.bytes)
        #expect(level.excludedFolderCount == 1)
        #expect(level.items.count == 1)
        if case .smaller(let count, _) = level.items.first?.kind {
            #expect(count == 0)
        } else {
            Issue.record("the excluded folder's space should be in the loose files row")
        }
        fake.cleanUp()
    }

    /// A folder with folders inside that a limited scan could not read is
    /// never passed through, so its note that they need Full Disk Access shows.
    @Test func aFolderWithLockedFoldersIsNeverPassedThrough() async throws {
        let fake = FakeScans()
        let store = await measuredStore(fake)
        fake.everythingElseFolders["\(base)/Photos"] = EverythingElseFolderContents(
            path: "\(base)/Photos",
            folders: [OverviewSizedItem(path: "\(base)/Photos/Library", bytes: 20 * gb)],
            openablePaths: ["\(base)/Photos/Library"],
            looseFileBytes: 0,
            lockedFolderCount: 2
        )
        store.openEverythingElseFolder(try tile(store, "Photos"))
        #expect(await eventually { !store.everythingElseOpenFolders.isEmpty })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(store.everythingElseOpenFolders.map(\.path) == ["\(base)/Photos"])
        #expect(store.everythingElseOpenLevel()?.lockedFolderCount == 2)
        #expect(fake.everythingElseFolderRequests.map(\.path) == ["\(base)/Photos"])
        fake.cleanUp()
    }

    @Test func goingBackUpStopsASizingThatIsStillRunning() async throws {
        let fake = FakeScans()
        let store = await measuredStore(fake)
        fake.holdsEverythingElseFolders = true
        store.openEverythingElseFolder(try tile(store, "Work"))
        #expect(store.everythingElseFolderSizing?.path == "\(base)/Work")
        #expect(await eventually { store.everythingElseFolderSizing?.fraction == 0.5 })

        store.closeEverythingElseFolders(keeping: 0)
        #expect(store.everythingElseFolderSizing == nil)
        fake.finishHeldEverythingElseFolders()
        try await Task.sleep(nanoseconds: 100_000_000)
        // The stopped sizing's answer is dropped, so opening again sizes again.
        #expect(store.everythingElseFolderContents.isEmpty)
        #expect(store.everythingElseOpenFolders.isEmpty)
        fake.cleanUp()
    }

    @Test func aFolderThatCannotBeReadClosesAgain() async throws {
        let fake = FakeScans()
        let store = await measuredStore(fake)
        store.openEverythingElseFolder(try tile(store, "Photos"))
        #expect(await eventually { fake.everythingElseFolderRequests.count == 1 && store.everythingElseFolderSizing == nil })
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(store.everythingElseOpenFolders.isEmpty)
        #expect(fake.everythingElseFolderRequests.map(\.path) == ["\(base)/Photos"])
        fake.cleanUp()
    }

    @Test func aNewWalkClosesEveryFolderAndForgetsTheirSizes() async throws {
        let fake = FakeScans()
        let store = await measuredStore(fake)
        store.openEverythingElseFolder(try tile(store, "Work"))
        #expect(await eventually { store.everythingElseOpenLevel() != nil })

        store.measureEverythingElseAgain()
        #expect(await eventually { store.everythingElsePhase == .ready })
        #expect(store.everythingElseOpenFolders.isEmpty)
        #expect(store.everythingElseFolderContents.isEmpty)

        // Leaving the page and coming back also starts at the whole map.
        store.openEverythingElseFolder(try tile(store, "Work"))
        #expect(await eventually { store.everythingElseOpenLevel() != nil })
        store.showOverviewSummary()
        store.showEverythingElsePage()
        #expect(store.everythingElseOpenFolders.isEmpty)
        fake.cleanUp()
    }

    @Test func nothingOpensWhileTheWalkRuns() async throws {
        let fake = FakeScans()
        let store = await measuredStore(fake)
        let work = try tile(store, "Work")
        fake.holdsEverythingElse = true
        store.measureEverythingElseAgain()
        #expect(await eventually { store.everythingElsePhase == .measuring })
        store.openEverythingElseFolder(work)
        #expect(store.everythingElseOpenFolders.isEmpty)
        #expect(fake.everythingElseFolderRequests.isEmpty)
        fake.cleanUp()
    }
}

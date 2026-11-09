import Foundation
import Testing
@testable import Purge

/// The named Everything else groups: Chat Apps, Cloud Drives, Virtual Machines
/// and the rest that were split out of App Data, Documents, Developer and
/// System Data. What must hold: a folder goes to one group only, a named group
/// only ever takes bytes out of a catch-all and adds none, and what an Overview
/// category already counted never shows up in any of them. Pure functions over
/// made-up paths, apart from the last suite, which walks a temporary folder.
@Suite("Everything else named groups")
struct EverythingElseFolderCatalogTests {
    private let gb: Int64 = 1_000_000_000
    private let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
    private let users = URL(fileURLWithPath: "/Users", isDirectory: true)

    /// The real plan for a made-up home. `disk` adds the folders outside it.
    private func plan(access: ScanAccess = .full, disk: Bool = false) -> [EverythingElseMeasureRoot] {
        EverythingElseRootPlan.roots(
            home: home,
            access: access,
            steamLibraries: [],
            otherUserHomes: [],
            homeFolderNames: [],
            usersFolder: users,
            diskRoot: disk ? URL(fileURLWithPath: "/", isDirectory: true) : nil,
            userTemporaryFolder: disk ? URL(fileURLWithPath: "/private/var/folders/ab/xyz", isDirectory: true) : nil
        )
    }

    /// The planned root that is `host`. Home is two roots, so `group` picks one.
    private func hostRoot(_ host: EverythingElseHost, group: EverythingElseGroup? = nil) throws -> EverythingElseMeasureRoot {
        try #require(plan(disk: true).first { $0.host == host && (group == nil || $0.group == group) })
    }

    private func group(_ name: String, in root: EverythingElseMeasureRoot) -> EverythingElseGroup {
        EverythingElseFolderCatalog.group(forFolderAt: "\(root.path)/\(name)", in: root)
    }

    private func measured(_ root: EverythingElseMeasureRoot, _ folders: [(String, Int64)], loose: Int64 = 0) -> EverythingElseMeasureEvent {
        .measured(EverythingElseMeasuredRoot(
            root: root,
            folders: folders.map { OverviewSizedItem(path: "\(root.path)/\($0.0)", bytes: $0.1) },
            looseFileBytes: loose
        ))
    }

    // MARK: Which group a folder goes to

    @Test func aFolderInLibraryGoesToTheGroupThatNamesIt() throws {
        let containers = try hostRoot(.containers)
        // The disk spells names as the app did; the catalog ignores case.
        #expect(group("com.tencent.xinWeChat", in: containers) == .chatApps)
        #expect(group("com.docker.docker", in: containers) == .virtualMachines)
        #expect(group("com.apple.mail", in: containers) == .mailAndMessages)
        // A named folder comes before the prefix that would also match it.
        #expect(group("com.apple.Safari", in: containers) == .browsers)
        #expect(group("com.apple.dt.Xcode", in: containers) == .developer)
        #expect(group("com.apple.Notes", in: containers) == .systemAppData)
        #expect(group("com.example.Editor", in: containers) == .appData)

        let groupContainers = try hostRoot(.groupContainers)
        #expect(group("HUAQ24HBR6.dev.orbstack", in: groupContainers) == .virtualMachines)
        #expect(group("243LU875E5.groups.com.apple.podcasts", in: groupContainers) == .mediaLibraries)
        #expect(group("group.com.apple.notes", in: groupContainers) == .systemAppData)
        #expect(group("UBF8T346G9.Office", in: groupContainers) == .appData)

        let support = try hostRoot(.applicationSupport)
        #expect(group("MobileSync", in: support) == .deviceBackups)
        #expect(group("Signal", in: support) == .chatApps)
        #expect(group("Firefox", in: support) == .browsers)
        #expect(group("Code", in: support) == .developer)
        #expect(group("CrossOver", in: support) == .otherApps)
        // Steam's own data stays; its games are Other Apps by their own root.
        #expect(group("Steam", in: support) == .appData)

        let library = try hostRoot(.library)
        #expect(group("Mobile Documents", in: library) == .cloudDrives)
        #expect(group("CloudStorage", in: library) == .cloudDrives)
        #expect(group("iTunes", in: library) == .deviceBackups)
        #expect(group("Android", in: library) == .developer)
        #expect(group("Biome", in: library) == .systemAppData)
        #expect(group("Fonts", in: library) == .appData)
    }

    @Test func aFolderInTheHomeFolderGoesToTheGroupThatNamesIt() throws {
        // Home is walked twice: its hidden folders for Developer, the rest for Documents.
        let hidden = try hostRoot(.home, group: .developer)
        let rest = try hostRoot(.home, group: .documents)
        #expect(group(".docker", in: hidden) == .virtualMachines)
        #expect(group(".ollama", in: hidden) == .aiModels)
        #expect(group(".cargo", in: hidden) == .developer)
        #expect(group("Dropbox", in: rest) == .cloudDrives)
        #expect(group("OneDrive - Contoso", in: rest) == .cloudDrives)
        #expect(group("Parallels", in: rest) == .virtualMachines)
        #expect(group("go", in: rest) == .developer)
        #expect(group("Tabletop", in: rest) == .documents)

        let movies = try hostRoot(.movies)
        #expect(group("Wedding.fcpbundle", in: movies) == .mediaLibraries)
        #expect(group("Trips", in: movies) == .documents)
        let documents = try hostRoot(.documents)
        let pictures = try hostRoot(.pictures)
        let music = try hostRoot(.music)
        #expect(group("GitHub", in: documents) == .developer)
        #expect(group("Notes", in: documents) == .documents)
        #expect(group("Lightroom", in: pictures) == .mediaLibraries)
        #expect(group("Audio Music Apps", in: music) == .mediaLibraries)

        let systemLibrary = try hostRoot(.systemLibrary)
        #expect(group("Audio", in: systemLibrary) == .mediaLibraries)
        #expect(group("Fonts", in: systemLibrary) == .sharedAppData)
    }

    @Test func aRootThatIsNoHostKeepsEveryFolder() throws {
        var plain = try hostRoot(.containers)
        plain.host = nil
        #expect(group("com.tencent.xinWeChat", in: plain) == .appData)
        #expect(!EverythingElseFolderCatalog.feeds(plain, .chatApps))
        #expect(EverythingElseFolderCatalog.feeds(plain, .appData))
    }

    /// A host's loose-file claim covers the whole host. A rule that moved a
    /// folder to a group claiming later would lose it to that claim, so every
    /// rule must point at a group that claims first.
    @Test func everyRuleMovesAFolderToAGroupThatClaimsFirst() {
        let hosted = plan(disk: true).filter { $0.host != nil }
        #expect(Set(hosted.compactMap(\.host)) == Set(EverythingElseHost.allCases))
        for root in hosted {
            guard let host = root.host else { continue }
            for rule in EverythingElseFolderCatalog.rules[host] ?? [] {
                #expect(rule.group == root.group || rule.group.claimsBefore(root.group), "\(rule.match) in \(root.path)")
            }
        }
        // A folder walked on its own sits inside one a catch-all walks.
        for nested in EverythingElseFolderCatalog.nestedFolders {
            #expect(nested.group.claimsBefore(.developer), "\(nested.relative)")
        }
        // Only measured groups take folders.
        let named = EverythingElseFolderCatalog.rules.values.flatMap { $0 }.map(\.group)
        #expect(named.allSatisfy(\.isMeasured))
    }

    // MARK: Each byte once

    @Test func aNamedGroupTakesItsFoldersOutOfTheCatchAllAndAddsNothing() throws {
        let containers = try hostRoot(.containers)
        let folders: [(String, Int64)] = [
            ("com.tencent.xinWeChat", 40 * gb), ("com.apple.Notes", 2 * gb), ("com.example.Editor", 5 * gb)
        ]
        var measurement = EverythingElseMeasurement(access: .full)
        measurement.apply(measured(containers, folders, loose: 1 * gb))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 200 * gb)
        #expect(breakdown[.chatApps]?.bytes == 40 * gb)
        #expect(breakdown[.chatApps]?.folders.map(\.name) == ["com.tencent.xinWeChat"])
        #expect(breakdown[.chatApps]?.folders.first?.group == .chatApps)
        #expect(breakdown[.systemAppData]?.bytes == 2 * gb)
        // App Data keeps the rest, and the loose files beside the folders.
        #expect(breakdown[.appData]?.bytes == 6 * gb)
        #expect(breakdown[.appData]?.folders.map(\.name) == ["com.example.Editor"])
        #expect(breakdown[.appData]?.smallerBytes == 1 * gb)

        // The same walk with no catalog: one group, and the same total.
        var plain = containers
        plain.host = nil
        var unsorted = EverythingElseMeasurement(access: .full)
        unsorted.apply(measured(plain, folders, loose: 1 * gb))
        let before = EverythingElseBreakdown(measurement: unsorted, claimedFirst: [], everythingElseBytes: 200 * gb)
        #expect(before[.appData]?.bytes == 48 * gb)
        #expect(before.measuredBytes == breakdown.measuredBytes)
        #expect(before.systemDataBytes == breakdown.systemDataBytes)
    }

    /// The Overview's five categories claim first. A named group shows only
    /// what they left: nothing of a folder Installed Apps counted whole, and
    /// the rest of a folder App Caches counted part of.
    @Test func whatACategoryCountedNeverShowsUpInANamedGroup() throws {
        let containers = try hostRoot(.containers)
        let support = try hostRoot(.applicationSupport)
        var measurement = EverythingElseMeasurement(access: .full)
        measurement.apply(measured(containers, [("com.tencent.xinWeChat", 40 * gb), ("ru.keepcoder.Telegram", 6 * gb)]))
        measurement.apply(measured(support, [("Firefox", 5 * gb), ("MobileSync", 30 * gb)]))
        let breakdown = EverythingElseBreakdown(
            measurement: measurement,
            claimedFirst: [
                // Installed Apps: WeChat is installed, and its container is part of the app.
                OverviewSizedItem(path: "\(containers.path)/com.tencent.xinWeChat", bytes: 40 * gb),
                // App Caches: Firefox's cache folder.
                OverviewSizedItem(path: "\(support.path)/Firefox/Profiles/default/cache2", bytes: 3 * gb)
            ],
            everythingElseBytes: 200 * gb
        )
        #expect(breakdown[.chatApps]?.bytes == 6 * gb)
        #expect(breakdown[.chatApps]?.folders.map(\.name) == ["ru.keepcoder.Telegram"])
        #expect(breakdown[.browsers]?.bytes == 2 * gb)
        #expect(breakdown[.browsers]?.folders.first?.measuredBytes == 5 * gb)
        #expect(breakdown[.deviceBackups]?.bytes == 30 * gb)
        #expect(breakdown[.appData]?.bytes == 0)
        // The walk found 81 GB and the categories had 43 GB of it.
        #expect(breakdown.measuredBytes == 38 * gb)
        #expect(!breakdown.isApproximate)
    }

    @Test func aFolderWalkedOnItsOwnComesOutOfTheFolderAroundIt() throws {
        // Chrome's profile is two levels into Application Support, so it is a
        // root of its own; the `Google` folder around it keeps the rest.
        let chrome = try #require(plan().first { $0.group == .browsers })
        let support = try hostRoot(.applicationSupport)
        var measurement = EverythingElseMeasurement(access: .full)
        measurement.apply(measured(support, [("Google", 12 * gb)]))
        measurement.apply(.measured(EverythingElseMeasuredRoot(root: chrome, totalBytes: 9 * gb)))
        let breakdown = EverythingElseBreakdown(measurement: measurement, claimedFirst: [], everythingElseBytes: 200 * gb)
        #expect(breakdown[.browsers]?.bytes == 9 * gb)
        #expect(breakdown[.appData]?.bytes == 3 * gb)
        #expect(breakdown.measuredBytes == 12 * gb)
    }

    // MARK: Progress and access

    @Test func aGroupIsMeasuredOnceEveryRootThatFeedsItIs() throws {
        let containers = try hostRoot(.containers)
        let support = try hostRoot(.applicationSupport)
        let caches = try #require(plan().first { $0.group == .protectedCaches })
        var measurement = EverythingElseMeasurement(access: .limited)
        measurement.apply(.planned([caches, support, containers]))
        #expect(measurement.plannedGroups.contains(.chatApps))
        #expect(measurement.plannedGroups.contains(.browsers))
        #expect(!measurement.plannedGroups.contains(.otherUsers))
        #expect(!measurement.hasFinished(.chatApps))

        // Application Support is in, but chat apps keep data in Containers too.
        measurement.apply(measured(support, []))
        #expect(!measurement.hasFinished(.chatApps))
        #expect(!measurement.isLocked(.chatApps))

        measurement.apply(.skipped(containers, locked: true))
        #expect(measurement.hasFinished(.chatApps))
        #expect(measurement.isLocked(.chatApps))
        // Protected Caches is fed by its own root alone.
        #expect(!measurement.hasFinished(.protectedCaches))
        #expect(!measurement.isLocked(.protectedCaches))
    }

    @Test func theFoldersOutsideHomeAreWalkedOnlyWithADiskRoot() {
        let outside: Set<EverythingElseGroup> = [.systemTools, .sharedAppData, .virtualMemory, .temporaryFiles]
        #expect(!plan().contains { outside.contains($0.group) })

        let withDisk = plan(disk: true)
        func paths(_ group: EverythingElseGroup) -> [String] {
            withDisk.filter { $0.group == group }.map(\.path)
        }
        #expect(paths(.systemTools) == ["/opt/homebrew", "/usr/local", "/Library/Developer", "/opt"])
        #expect(paths(.sharedAppData) == ["/Library/Application Support", "/Library"])
        #expect(paths(.virtualMemory) == ["/private/var/vm"])
        #expect(paths(.temporaryFiles) == ["/private/var/folders/ab/xyz"])
        // The swap files are one figure; the rest are listed by folder.
        for root in withDisk where outside.contains(root.group) {
            #expect((root.kind == .whole) == (root.group == .virtualMemory), "\(root.path)")
        }
    }

    @Test func aLimitedScanReadsTheToolFoldersAndLeavesTheSharedLibraryAlone() {
        let locked = Set(plan(access: .limited, disk: true).filter(\.isLockedWithoutAccess).map(\.path))
        for path in ["/Library/Application Support", "/Library", "/private/var/folders/ab/xyz"] {
            #expect(locked.contains(path), Comment(rawValue: path))
        }
        for path in ["/opt/homebrew", "/usr/local", "/Library/Developer", "/opt", "/private/var/vm"] {
            #expect(!locked.contains(path), Comment(rawValue: path))
        }
        #expect(plan(access: .full, disk: true).allSatisfy { !$0.isLockedWithoutAccess })
    }

    @Test func theTemporaryFolderIsTheParentOfTheProcessTemporaryDirectory() {
        #expect(EverythingElseMeasurer.userTemporaryFolder(temporaryDirectory: "/var/folders/ab/xyz123/T/")?.path
            == "/private/var/folders/ab/xyz123")
        #expect(EverythingElseMeasurer.userTemporaryFolder(temporaryDirectory: "/private/var/folders/ab/xyz123/T")?.path
            == "/private/var/folders/ab/xyz123")
        // Anything else is not that folder: a sandbox's, `/tmp`, the caches beside it.
        #expect(EverythingElseMeasurer.userTemporaryFolder(temporaryDirectory: "/tmp/") == nil)
        #expect(EverythingElseMeasurer.userTemporaryFolder(temporaryDirectory: "/var/folders/ab/xyz123/C/") == nil)
        #expect(EverythingElseMeasurer.userTemporaryFolder(
            temporaryDirectory: "/Users/alice/Library/Containers/com.example.app/Data/tmp/"
        ) == nil)
    }

    // MARK: Names and hints

    @Test func theSystemFoldersGetNamesAPersonCanRead() {
        func folder(_ path: String, _ group: EverythingElseGroup) -> EverythingElseFolder {
            EverythingElseFolder(path: path, bytes: gb, measuredBytes: gb, group: group)
        }
        #expect(folder("/private/var/folders/ab/xyz/T", .temporaryFiles).displayName == "Temporary Items")
        #expect(folder("/private/var/folders/ab/xyz/C", .temporaryFiles).displayName == "Per-User Caches")
        #expect(folder("/private/var/folders/ab/xyz/0", .temporaryFiles).displayName == "0")
        #expect(folder("/private/var/vm", .virtualMemory).displayName == "Swap Files & Sleep Image")
        // Only there: a folder named T anywhere else keeps its name.
        #expect(folder("/Users/alice/Documents/T", .documents).displayName == "T")
    }

    @Test func theNamedGroupsSayHowToFreeTheirSpace() throws {
        func hint(_ path: String, _ group: EverythingElseGroup) -> EverythingElseFolderHint? {
            EverythingElseFolderHint.hint(for: path, group: group, home: home, steamGames: [:])
        }
        #expect(hint("/Users/alice/Library/Mobile Documents", .cloudDrives)?.action == .showInLargeFiles)
        let backups = try #require(hint("/Users/alice/Library/Application Support/MobileSync", .deviceBackups))
        #expect(backups.action == nil)
        #expect(backups.steps.contains("Manage Backups"))

        guard case .openApp(let bundleID, _)? = hint("/Users/alice/Library/Containers/com.tencent.xinWeChat", .chatApps)?.action else {
            Issue.record("WeChat's container opens WeChat")
            return
        }
        #expect(bundleID == "com.tencent.xinWeChat")
        // Any other chat app gets the steps and no button.
        let signal = try #require(hint("/Users/alice/Library/Application Support/Signal", .chatApps))
        #expect(signal.action == nil)

        #expect(hint("/Users/alice/.ollama", .aiModels)?.action == .showInLargeFiles)
        #expect(hint("/Users/alice/Library/Application Support/Jan", .aiModels)?.action == .showInLargeFiles)
        #expect(hint("/opt/homebrew/Cellar", .systemTools) != nil)
        #expect(hint("/Library/Developer/CoreSimulator", .systemTools)?.action == .showInDevTools)
        #expect(hint("/usr/local/bin", .systemTools) == nil)
        #expect(hint("/Users/alice/Dropbox", .cloudDrives) != nil)
        // A sync service's own data in Library is not a synced folder.
        #expect(hint("/Users/alice/Library/Application Support/FileProvider", .cloudDrives) == nil)
        #expect(hint("/Library/Fonts", .sharedAppData) == nil)
    }
}

/// The walk over a temporary home and a temporary disk root: the folders
/// outside home are read only where the test put them, and every folder the
/// walk sizes lands in one group.
@Suite("Everything else named groups walk")
struct EverythingElseNamedGroupsWalkTests {
    @Test func walksAHomeAndADiskRootAndSortsEveryFolderOnce() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("purge-ee-named-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let users = base.appendingPathComponent("Users", isDirectory: true)
        let disk = base.appendingPathComponent("disk", isDirectory: true)
        let temporary = base.appendingPathComponent("temporary", isDirectory: true)
        try fm.createDirectory(at: users, withIntermediateDirectories: true)
        let files: [(URL, String)] = [
            (home, "Library/Containers/com.tencent.xinWeChat/chat.db"),
            (home, "Library/Containers/com.example.Editor/data.bin"),
            (home, "Dropbox/report.pdf"),
            (home, ".docker/disk.raw"),
            (disk, "opt/homebrew/Cellar/tool.bin"),
            (disk, "Library/Application Support/Vendor/support.bin"),
            (disk, "Library/Fonts/font.ttf"),
            (disk, "private/var/vm/swapfile0"),
            (temporary, "T/work.tmp")
        ]
        for (root, relative) in files {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 100_000).write(to: url)
        }

        var measurement = EverythingElseMeasurement(access: .full)
        let stream = EverythingElseMeasurer().measureStream(
            access: .full,
            home: home,
            steamLibraries: [],
            otherUserHomes: [],
            usersFolder: users,
            diskRoot: disk,
            userTemporaryFolder: temporary,
            readsSystemVolume: false
        )
        for await event in stream {
            measurement.apply(event)
        }
        measurement.isComplete = true

        // A floor of one byte, so every folder keeps a row of its own.
        let breakdown = EverythingElseBreakdown(
            measurement: measurement,
            claimedFirst: [],
            everythingElseBytes: 1_000_000_000,
            floorBytes: 1
        )
        func names(_ group: EverythingElseGroup) -> Set<String> {
            Set((breakdown[group]?.folders ?? []).map(\.name))
        }
        #expect(names(.chatApps) == ["com.tencent.xinWeChat"])
        #expect(names(.appData) == ["com.example.Editor"])
        #expect(names(.cloudDrives) == ["Dropbox"])
        #expect(names(.virtualMachines) == [".docker"])
        #expect(names(.systemTools) == ["Cellar"])
        #expect(names(.sharedAppData) == ["Vendor", "Fonts"])
        #expect(names(.virtualMemory) == ["vm"])
        #expect(names(.temporaryFiles) == ["T"])
        #expect(names(.documents).isEmpty)
        #expect(names(.developer).isEmpty)

        // One group per folder, and no group counts more than the walk found.
        let listed = EverythingElseGroup.measured.flatMap { breakdown[$0]?.folders ?? [] }
        #expect(listed.count == 9)
        #expect(Set(listed.map(\.path)).count == listed.count)
        #expect(breakdown.measuredBytes <= measurement.measuredRoots.reduce(Int64(0)) { $0 + $1.totalBytes })
    }

    /// A walk given a home of its own, which is how every other test runs it,
    /// plans nothing outside that home.
    @Test func aWalkGivenItsOwnHomeReadsNothingOutsideIt() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("purge-ee-named-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let users = base.appendingPathComponent("Users", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: users, withIntermediateDirectories: true)

        var planned: [EverythingElseMeasureRoot] = []
        let stream = EverythingElseMeasurer().measureStream(
            access: .full, home: home, steamLibraries: [], otherUserHomes: [],
            usersFolder: users, readsSystemVolume: false
        )
        for await event in stream {
            if case .planned(let roots) = event { planned = roots }
        }
        #expect(!planned.isEmpty)
        let homePath = OverviewSizedItem.normalized(home.path)
        for root in planned {
            #expect(PathContainment.isSameOrInside(root.path, homePath) || root.path.hasSuffix("/Shared/Epic Games"), "\(root.path)")
        }
    }
}

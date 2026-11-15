import Foundation
import Testing
@testable import Purge

/// The scans got faster by doing the same reads side by side, and by not doing
/// some of them twice. These pin that the answers did not change: sizes,
/// nested code, the order Everything else reports in, and the leftover rows.
/// Everything runs on temporary folders, never the user's own (#171).
@Suite("Faster scans give the same answers")
struct ScanSpeedTests {
    private let fm = FileManager.default

    private func makeTemporaryDirectory() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("purge-speed-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `count` folders of different sizes, some with a subfolder.
    private func makeFolders(_ count: Int, in root: URL) throws -> [URL] {
        try (0..<count).map { index in
            let folder = root.appendingPathComponent("folder-\(index)", isDirectory: true)
            try fm.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
            try Data(count: 4_096 * (index % 7 + 1)).write(to: folder.appendingPathComponent("file.bin"))
            if index % 3 == 0 {
                try Data(count: 10_000).write(to: folder.appendingPathComponent("inner/more.bin"))
            }
            return folder
        }
    }

    // MARK: Folder sizing

    @Test(arguments: [0, 1, 5, 12, 13, 64, 65, 500])
    func chunksKeepEveryFolderOnceAndInOrder(count: Int) {
        let items = Array(0..<count)
        for split in [FolderSizing.Split.fewest, .spread] {
            let chunks = FolderSizing.chunks(of: items, split: split)
            #expect(chunks.flatMap { $0 } == items)
            #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= FolderSizing.duChunkSize })
        }
        // A short list gets one `du` per folder when spread, so one big folder
        // never holds up the others.
        if count <= FolderSizing.duChunkSize {
            #expect(FolderSizing.chunks(of: items, split: .spread).allSatisfy { $0.count == 1 })
        }
    }

    @Test
    func spreadSizingMeasuresTheSameAsFewestProcesses() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let folders = try makeFolders(30, in: root)

        let fewest = FolderSizing.directorySizes(at: folders, split: .fewest)
        let spread = FolderSizing.directorySizes(at: folders, split: .spread)
        #expect(fewest.count == folders.count)
        #expect(spread == fewest)
    }

    @Test
    func stayingOnTheVolumeMeasuresAnOrdinaryFolderTheSame() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let folders = try makeFolders(6, in: root)

        #expect(
            FolderSizing.directorySizes(at: folders, split: .spread, staysOnVolume: true)
                == FolderSizing.directorySizes(at: folders)
        )
        #expect(
            FolderSizing.directoryByteSizeIfMeasurable(at: root, staysOnVolume: true)
                == FolderSizing.directoryByteSizeIfMeasurable(at: root)
        )
    }

    @Test
    func chunkSizesReportEveryFolderOnce() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let folders = try makeFolders(20, in: root)
        let collected = Collected()

        let total = FolderSizing.directorySizes(at: folders, split: .spread, onChunkSizes: { collected.add($0) })
        #expect(collected.merged == total)
        #expect(collected.reports == FolderSizing.chunks(of: folders, split: .spread).count)
    }

    // MARK: Concurrent reads

    @Test(arguments: [1, 3, 64])
    func concurrentMapKeepsTheItemsOrder(width: Int) {
        let items = Array(0..<500)
        #expect(ConcurrentMap.values(items, width: width) { $0 * 2 } == items.map { $0 * 2 })
        #expect(ConcurrentMap.values([Int](), width: width) { $0 }.isEmpty)
    }

    // MARK: Nested code

    /// Walking several apps together finds what walking each alone finds, in
    /// the same order.
    @Test
    func jointNestedWalkMatchesOneWalkPerBundle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let apps = try (0..<4).map { index -> URL in
            let app = root.appendingPathComponent("App\(index).app", isDirectory: true)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            for folder in [
                "PlugIns/Share\(index).appex/Contents",
                "XPCServices/Fetch.xpc/Contents",
                "Library/LoginItems/Helper.app/Contents",
                "Frameworks/Kit.framework/Versions/A/XPCServices/Deep.xpc",
                "Resources/en.lproj/Hidden.appex",
                "Resources/node_modules/Fake.app",
            ] {
                try fm.createDirectory(at: contents.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            for extra in 0..<(index * 40) {
                try fm.createDirectory(
                    at: contents.appendingPathComponent("Resources/Pile/\(extra)"),
                    withIntermediateDirectories: true
                )
            }
            return app
        }

        let joint = InstalledCodeEvidence.nestedCodeBundleURLs(inEach: apps)
        #expect(joint.count == apps.count)
        for (app, found) in zip(apps, joint) {
            #expect(found == Self.walkOneFolderAtATime(app))
            #expect(found == InstalledCodeEvidence.nestedCodeBundleURLs(in: app))
            #expect(Set(found.map(\.lastPathComponent)).isSuperset(of: ["Fetch.xpc", "Helper.app", "Deep.xpc"]))
            #expect(!found.contains { $0.lastPathComponent == "Hidden.appex" || $0.lastPathComponent == "Fake.app" })
        }
    }

    /// A walk that runs out of budget part way stops at the same entry, and
    /// finds the same code, as the walk that read one folder at a time.
    @Test
    func jointNestedWalkRunsOutOfBudgetWhereTheOldWalkDid() throws {
        let root = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Big.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let pile = contents.appendingPathComponent("Pile", isDirectory: true)
        try fm.createDirectory(at: pile, withIntermediateDirectories: true)
        for index in 0..<(InstalledCodeEvidence.nestedWalkEntryBudget + 100) {
            fm.createFile(atPath: pile.appendingPathComponent("f\(index)").path, contents: nil)
        }
        for folder in ["PlugIns/Early.appex", "Pile2/Deep/Late.xpc", "XPCServices/Fetch.xpc"] {
            try fm.createDirectory(at: contents.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let small = root.appendingPathComponent("Small.app/Contents/PlugIns/Share.appex", isDirectory: true)
        try fm.createDirectory(at: small, withIntermediateDirectories: true)
        let smallApp = root.appendingPathComponent("Small.app", isDirectory: true)

        let joint = InstalledCodeEvidence.nestedCodeBundleURLs(inEach: [app, smallApp])
        #expect(joint[0] == Self.walkOneFolderAtATime(app))
        #expect(joint[1] == Self.walkOneFolderAtATime(smallApp))
        #expect(joint[1].map(\.lastPathComponent) == ["Share.appex"])
    }

    /// The walk as it was before it read folders side by side.
    private static func walkOneFolderAtATime(_ bundle: URL) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var result: [URL] = []
        var queue: [URL] = [bundle]
        var budget = InstalledCodeEvidence.nestedWalkEntryBudget
        var index = 0
        while index < queue.count, budget > 0 {
            let folder = queue[index]
            index += 1
            guard let entries = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                budget -= 1
                if budget <= 0 { break }
                let values = try? entry.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                let name = entry.lastPathComponent
                let ext = entry.pathExtension.lowercased()
                guard !InstalledCodeEvidence.skippedFolderNames.contains(name),
                      !InstalledCodeEvidence.skippedFolderExtensions.contains(ext) else { continue }
                if InstalledCodeEvidence.ownerCodeExtensions.contains(ext) {
                    result.append(entry)
                }
                queue.append(entry)
            }
        }
        return result
    }

    // MARK: Everything else

    /// Roots are measured a few at a time, but the page counts them off in
    /// plan order, so they must be reported in it.
    @Test
    func everythingElseReportsRootsInPlanOrder() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let users = base.appendingPathComponent("Users", isDirectory: true)
        try fm.createDirectory(at: users, withIntermediateDirectories: true)
        for folder in [
            "Library/Application Support/App", "Library/Caches/Cache", "Library/Containers/Box",
            "Library/Group Containers/Group", "Library/Developer/Xcode", "Library/Unity",
            "Developer/engine", "Documents/Notes", "Desktop/Shots", "Downloads/Files",
            ".tool", "Tabletop",
        ] {
            let url = home.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(count: 20_000).write(to: url.appendingPathComponent("data.bin"))
        }

        var planned: [EverythingElseMeasureRoot] = []
        var reported: [EverythingElseMeasureRoot] = []
        let stream = EverythingElseMeasurer().measureStream(
            access: .full, home: home, steamLibraries: [], otherUserHomes: [],
            usersFolder: users, readsSystemVolume: false
        )
        for await event in stream {
            switch event {
            case .planned(let roots): planned = roots
            case .measured(let measured): reported.append(measured.root)
            case .skipped(let root, _): reported.append(root)
            case .progress, .macOS, .steamGames, .commandLineTools: break
            }
        }
        #expect(reported.count == planned.count)
        #expect(reported == planned)
    }

    // MARK: Leftovers

    /// The Apps totals pass lists the Library roots once for every app and hands
    /// in each bundle's size; the rows must be what a scan of its own finds.
    @Test
    func sharedListingsAndAKnownBundleSizeGiveTheSameRows() async throws {
        let token = UUID().uuidString.prefix(8).lowercased()
        let bundleID = "com.purgetest.\(token)"
        let appName = "PurgeSpeed\(token)"
        let base = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        for folder in ["Preferences", "Application Support/\(bundleID)", "Application Support/\(appName)", "Caches/\(bundleID)"] {
            try fm.createDirectory(at: library.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data(count: 8_192).write(to: library.appendingPathComponent("Preferences/\(bundleID).plist"))
        try Data(count: 50_000).write(to: library.appendingPathComponent("Caches/\(bundleID)/cache.db"))
        let bundle = base.appendingPathComponent("\(appName).app", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data(count: 30_000).write(to: bundle.appendingPathComponent("Contents/binary"))
        let app = InstalledApp(name: appName, bundleURL: bundle, bundleID: bundleID, bundleSizeBytes: 0, isRunning: false)
        let scanner = AppUninstallScanner(home: home)

        func rows(_ stream: AsyncStream<UninstallItem>) async -> [String] {
            var rows: [String] = []
            for await item in stream {
                rows.append("\(item.path.standardizedFileURL.path)|\(item.sizeBytes)|\(item.category)|\(item.matchReason)|\(item.isSelected)")
            }
            return rows
        }
        let ownScan = await rows(scanner.leftoverStream(for: app))
        let listings = await scanner.listLeftoverRoots()
        let bundleBytes = try #require(FolderSizing.directoryByteSizeIfMeasurable(at: bundle))
        let shared = await rows(scanner.leftoverStream(for: app, knownBundleBytes: bundleBytes, rootListings: listings))

        #expect(ownScan.count >= 4)
        #expect(shared == ownScan)

        // A bundle size handed in is used as it is, without walking the bundle.
        let handedIn = await rows(scanner.leftoverStream(for: app, knownBundleBytes: 7, rootListings: listings))
        #expect(handedIn.first?.hasPrefix("\(bundle.standardizedFileURL.path)|7|") == true)
        #expect(Array(handedIn.dropFirst()) == Array(ownScan.dropFirst()))
    }
}

/// A full scan starts project discovery with its App Caches half, so
/// discovery's git check can still be running when a half of the scan starts.
/// Neither half may reset the git session then, or the check's answers are
/// thrown away and its rows stay unknown for the rest of the session.
@MainActor
@Suite("Project discovery beside a full scan")
struct DiscoveryBesideFullScanTests {
    @Test
    func discoveryGitCheckSurvivesTheDevToolsHalf() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-discovery-git-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let projectRoot = base.appendingPathComponent("app", isDirectory: true)
        // A name off the cache allowlist, so the checker asks `git` rather than
        // calling the folder clean by its name.
        let artifactPath = projectRoot.appendingPathComponent("purge-test-output", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let gate = HeldGitStatus()
        let checker = GitStatusChecker { _ in await gate.answer() }
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.gitStatusChecker = checker
        fake.holdsGeneral = true
        let group = ProjectGroup(
            displayName: "app",
            rootPath: projectRoot,
            inferredTypes: [.node],
            artifacts: [ProjectCacheArtifact(
                kind: .nodeModules,
                path: artifactPath,
                projectRoot: projectRoot,
                sizeBytes: 1_000_000,
                lastModified: .distantPast,
                isSelected: false,
                safetyInfo: SafetyInfo(level: .safe, headline: "output", explanation: "", recoverySteps: "", reinstallCommand: nil),
                reinstallSafety: .notApplicable,
                gitStatus: .unknown,
                checkFirstReason: nil
            )]
        )
        fake.holdsProjects = true
        let store = fake.makeStore(gitChecker: checker)

        let scan = Task { await store.scanAll() }
        // Discovery finds the project and starts its git check while App Caches
        // is still held open.
        #expect(await eventually { fake.projectScanCount == 1 })
        store.projectGroups = [group]
        fake.finishHeldProjects()
        #expect(await eventually { gate.isWaiting })
        // The Dev Tools half starts while the check still waits for `git`.
        fake.finishHeldGeneral()
        #expect(await eventually { fake.developerAccesses.count == 1 })
        gate.release()
        await scan.value

        #expect(await eventually { !store.isScanningProjects })
        #expect(store.projectGroups.flatMap(\.artifacts).map(\.gitStatus) == [.clean])
    }
}

/// A `git status` that waits until the test lets it answer clean.
private final class HeldGitStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !waiting.isEmpty
    }

    func answer() async -> GitWorktreeStatus {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
        return .clean
    }

    func release() {
        lock.lock()
        released = true
        let held = waiting
        waiting = []
        lock.unlock()
        held.forEach { $0.resume() }
    }
}

/// Chunk sizes as `directorySizes` reports them, from its sizing threads.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [String: Int64] = [:]
    private var count = 0

    func add(_ chunk: [String: Int64]) {
        lock.lock()
        sizes.merge(chunk) { _, new in new }
        count += 1
        lock.unlock()
    }

    var merged: [String: Int64] {
        lock.lock()
        defer { lock.unlock() }
        return sizes
    }

    var reports: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

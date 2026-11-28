import Foundation
import Testing
@testable import Purge

/// Each runtime has a dyld shared cache that `simctl` leaves out of its size
/// (#473). Purge measures it and shows it beside the size. Only the folder named
/// exactly after the runtime, under this macOS build, counts. It is never a
/// delete candidate or part of a size. Whether `simctl runtime delete` removes it
/// is not yet confirmed by a live delete.
@MainActor
@Suite("Simulator runtime dyld cache")
struct SimulatorRuntimeDyldCacheTests {
    private static let osBuild = "26A428"
    private static let runtimeIdentifier = "com.apple.CoreSimulator.SimRuntime.iOS-26-3"
    private static let build = "23D8133"
    private static let folderName = "\(runtimeIdentifier).\(build)"

    /// A stand-in for `/Library/Developer/CoreSimulator/Caches/dyld` in a temporary folder.
    private struct FakeDyldRoot {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PurgeDyldCache-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        /// A cache folder holding `bytes` of data, or empty when `bytes` is 0.
        @discardableResult
        func addFolder(_ name: String, osBuild: String = SimulatorRuntimeDyldCacheTests.osBuild, bytes: Int = 256 * 1024) throws -> URL {
            let folder = root.appendingPathComponent(osBuild, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if bytes > 0 {
                try Data(repeating: 7, count: bytes).write(to: folder.appendingPathComponent("dyld_sim_shared_cache_arm64"))
            }
            return folder
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func runtime(
        id: String = "7AE1D6B6-5524-4FAD-B793-1D1C911E5269",
        runtimeIdentifier: String = SimulatorRuntimeDyldCacheTests.runtimeIdentifier,
        build: String = SimulatorRuntimeDyldCacheTests.build,
        dyldCacheBytes: Int64? = nil
    ) -> SimulatorRuntime {
        let safety = SimulatorRuntime.safetyInfo(
            platformName: "iOS", version: "26.3.1", state: "Ready", sizeBytes: 8_393_503_393,
            lastUsedAt: nil, deviceCount: 0, isXcodeDefault: false
        )
        return SimulatorRuntime(
            id: id,
            runtimeIdentifier: runtimeIdentifier,
            platformName: "iOS",
            version: "26.3.1",
            build: build,
            kind: "Patchable Cryptex Disk Image",
            state: "Ready",
            sizeBytes: 8_393_503_393,
            lastUsedAt: nil,
            deviceCount: 0,
            locationURL: URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes/iOS_\(build)", isDirectory: true),
            safetyInfo: safety,
            dyldCacheBytes: dyldCacheBytes
        )
    }

    // MARK: - Finding and measuring the folder

    @Test func theFolderNamedAfterTheRuntimeIsMeasured() throws {
        let fake = try FakeDyldRoot()
        defer { fake.cleanUp() }
        try fake.addFolder(Self.folderName)
        let row = runtime()

        let sizes = SimulatorRuntime.dyldCacheSizes(for: [row], root: fake.root, osBuild: Self.osBuild)

        let bytes = try #require(sizes[row.id])
        #expect(bytes >= 256 * 1024)
    }

    @Test func eachRuntimeGetsOnlyItsOwnFolder() throws {
        let fake = try FakeDyldRoot()
        defer { fake.cleanUp() }
        try fake.addFolder(Self.folderName, bytes: 256 * 1024)
        try fake.addFolder("com.apple.CoreSimulator.SimRuntime.watchOS-26-2.23S303", bytes: 1024 * 1024)
        let iOS = runtime()
        let watchOS = runtime(id: "W", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-26-2", build: "23S303")
        let noFolder = runtime(id: "T", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.tvOS-26-2", build: "23K50")

        let sizes = SimulatorRuntime.dyldCacheSizes(for: [iOS, watchOS, noFolder], root: fake.root, osBuild: Self.osBuild)

        #expect(Set(sizes.keys) == [iOS.id, watchOS.id])
        #expect(try #require(sizes[watchOS.id]) > (try #require(sizes[iOS.id])))
    }

    /// A folder left from an older macOS build is not this runtime's cache today.
    @Test func aFolderUnderAnotherMacOSBuildIsNotCounted() throws {
        let fake = try FakeDyldRoot()
        defer { fake.cleanUp() }
        try fake.addFolder(Self.folderName, osBuild: "25E253")

        #expect(SimulatorRuntime.dyldCacheSizes(for: [runtime()], root: fake.root, osBuild: Self.osBuild).isEmpty)
    }

    @Test func aFolderForAnotherRuntimeBuildIsNotCounted() throws {
        let fake = try FakeDyldRoot()
        defer { fake.cleanUp() }
        try fake.addFolder("\(Self.runtimeIdentifier).23D5103d")
        try fake.addFolder("\(Self.runtimeIdentifier).\(Self.build)x")

        #expect(SimulatorRuntime.dyldCacheSizes(for: [runtime()], root: fake.root, osBuild: Self.osBuild).isEmpty)
    }

    /// The volume ignores case, so only the listing can tell another spelling apart.
    @Test func aFolderSpelledInAnotherCaseIsNotCounted() throws {
        let fake = try FakeDyldRoot()
        defer { fake.cleanUp() }
        try fake.addFolder(Self.folderName.lowercased())

        #expect(SimulatorRuntime.dyldCacheSizes(for: [runtime()], root: fake.root, osBuild: Self.osBuild).isEmpty)
    }

    @Test func aLinkWithTheRightNameIsNotCounted() throws {
        let fake = try FakeDyldRoot()
        defer { fake.cleanUp() }
        let elsewhere = try fake.addFolder("elsewhere", osBuild: "other")
        let buildFolder = fake.root.appendingPathComponent(Self.osBuild, isDirectory: true)
        try FileManager.default.createDirectory(at: buildFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: buildFolder.appendingPathComponent(Self.folderName),
            withDestinationURL: elsewhere
        )

        #expect(SimulatorRuntime.dyldCacheSizes(for: [runtime()], root: fake.root, osBuild: Self.osBuild).isEmpty)
    }

    @Test func aFileWithTheRightNameIsNotCounted() throws {
        let fake = try FakeDyldRoot()
        defer { fake.cleanUp() }
        let buildFolder = fake.root.appendingPathComponent(Self.osBuild, isDirectory: true)
        try FileManager.default.createDirectory(at: buildFolder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: buildFolder.appendingPathComponent(Self.folderName))

        #expect(SimulatorRuntime.dyldCacheSizes(for: [runtime()], root: fake.root, osBuild: Self.osBuild).isEmpty)
    }

    @Test func anEmptyFolderShowsNothing() throws {
        let fake = try FakeDyldRoot()
        defer { fake.cleanUp() }
        try fake.addFolder(Self.folderName, bytes: 0)

        #expect(SimulatorRuntime.dyldCacheSizes(for: [runtime()], root: fake.root, osBuild: Self.osBuild).isEmpty)
    }

    @Test func noRootOrNoMacOSBuildShowsNothing() throws {
        let fake = try FakeDyldRoot()
        defer { fake.cleanUp() }
        try fake.addFolder(Self.folderName)
        let missing = fake.root.appendingPathComponent("missing", isDirectory: true)

        #expect(SimulatorRuntime.dyldCacheSizes(for: [runtime()], root: missing, osBuild: Self.osBuild).isEmpty)
        #expect(SimulatorRuntime.dyldCacheSizes(for: [runtime()], root: fake.root, osBuild: nil).isEmpty)
        #expect(SimulatorRuntime.dyldCacheSizes(for: [runtime()], root: fake.root, osBuild: "").isEmpty)
    }

    @Test func theMacOSBuildIsRead() throws {
        let build = try #require(SimulatorRuntime.currentOSBuild())
        #expect(!build.isEmpty)
        #expect(!build.contains("/"))
    }

    // MARK: - What the row and the sheet show

    @Test func theCaptionAddsTheCacheOnlyWhenThereIsOne() {
        #expect(runtime().detailCaption == "Build 23D8133")
        #expect(runtime(dyldCacheBytes: 0).detailCaption == "Build 23D8133")
        let bytes: Int64 = 3_778_000_000
        #expect(runtime(dyldCacheBytes: bytes).detailCaption == "Build 23D8133. The size leaves out \(formatBytes(bytes)) of cache.")
    }

    /// The cache shows on the sheet's line, but the candidate is still the runtime
    /// alone at its mount path, with `simctl`'s size. Nothing points at the folder.
    @Test func theCandidateStaysTheRuntimeAlone() async throws {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = runtime(dyldCacheBytes: 3_778_000_000)
        scans.developerEvents = [.simulatorRuntimeFound(row)]
        let store = scans.makeStore()
        await store.scanDeveloper()

        store.setSimulatorRuntimeSelected(id: row.id, isSelected: true)

        let candidate = try #require(store.deletionCandidates.first)
        #expect(store.deletionCandidates.count == 1)
        #expect(candidate.path == row.locationURL.standardizedFileURL)
        #expect(candidate.sizeBytes == row.sizeBytes)
        #expect(candidate.subtitle == row.detailCaption)
        #expect(store.selectedTotalBytes == row.sizeBytes)
        #expect(!candidate.path.path.hasPrefix(SimulatorRuntime.dyldCacheRoot.path))
    }

    /// The cache allowlist never takes the folder, so no cache clean can reach it.
    @Test func theCachePolicyRefusesTheDyldFolders() {
        let root = SimulatorRuntime.dyldCacheRoot
        let runtimeFolder = root.appendingPathComponent(Self.osBuild, isDirectory: true)
            .appendingPathComponent(Self.folderName, isDirectory: true)
        #expect(DeletionSafetyPolicy.evaluate(root) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(root.appendingPathComponent(Self.osBuild, isDirectory: true)) != .allow)
        #expect(DeletionSafetyPolicy.evaluate(runtimeFolder) != .allow)
    }

    // MARK: - Saved last scan

    @Test func theSavedRowKeepsTheCache() throws {
        let row = runtime(dyldCacheBytes: 3_778_000_000)
        let data = try JSONEncoder().encode(SavedSimulatorRuntime(row))
        let restored = try #require(try JSONDecoder().decode(SavedSimulatorRuntime.self, from: data).restored)
        #expect(restored.dyldCacheBytes == 3_778_000_000)
        #expect(restored.detailCaption == row.detailCaption)
    }

    /// A snapshot saved before #473 has no cache field and still decodes.
    @Test func aSavedRowWithoutTheCacheStillDecodes() throws {
        let data = try JSONEncoder().encode(SavedSimulatorRuntime(runtime(dyldCacheBytes: 5)))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "dyldCacheBytes")
        let older = try JSONSerialization.data(withJSONObject: object)

        let restored = try #require(try JSONDecoder().decode(SavedSimulatorRuntime.self, from: older).restored)
        #expect(restored.dyldCacheBytes == nil)
        #expect(restored.detailCaption == "Build 23D8133")
    }
}

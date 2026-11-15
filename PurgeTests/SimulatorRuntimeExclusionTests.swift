import Foundation
import Testing
@testable import Purge

/// A runtime exclusion has to hold wherever `simctl` says the runtime is: the
/// mounted volume one scan, the image file the next (#178). Each test uses its own
/// image ids and builds, because the lists are shared by every test in the run.
@Suite("Simulator runtime exclusions")
struct SimulatorRuntimeExclusionTests {
    private static let volumes = ExcludedSimulatorRuntimesStore.volumesRoot

    private func runtime(id: String, build: String, at path: String? = nil) -> SimulatorRuntime {
        SimulatorRuntime(
            id: id,
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-4",
            platformName: "iOS",
            version: "18.4",
            build: build,
            kind: "Patchable Cryptex Disk Image",
            state: "Ready",
            sizeBytes: 9_000_000_000,
            lastUsedAt: nil,
            deviceCount: 0,
            locationURL: URL(fileURLWithPath: path ?? "\(Self.volumes)/iOS_\(build)", isDirectory: true),
            safetyInfo: SimulatorRuntime.safetyInfo(
                platformName: "iOS", version: "18.4", state: "Ready", sizeBytes: 9_000_000_000,
                lastUsedAt: nil, deviceCount: 0, isXcodeDefault: false
            )
        )
    }

    private func imagePath(_ id: String) -> String {
        "/Library/Developer/CoreSimulator/Cryptex/Images/bundle/SimRuntimeBundle-\(id)/Restore/090-44334-323.dmg"
    }

    @Test func excludedAtItsVolumeStaysExcludedAtItsImage() {
        let mounted = runtime(id: "178E0001-0000-4000-8000-000000000001", build: "178EXCL1")
        defer { ExcludedSimulatorRuntimesStore.remove(imageID: mounted.id) }
        ExcludedSimulatorRuntimesStore.write(mounted)

        let unmounted = runtime(id: mounted.id, build: mounted.build, at: imagePath(mounted.id))

        #expect(ExcludedSimulatorRuntimesStore.isExcluded(mounted))
        #expect(ExcludedSimulatorRuntimesStore.isExcluded(unmounted))
    }

    /// Downloaded again, the runtime gets a new image id but keeps its build.
    @Test func theSameBuildUnderANewImageIDStaysExcluded() {
        let first = runtime(id: "178E0002-0000-4000-8000-000000000002", build: "178EXCL2")
        defer { ExcludedSimulatorRuntimesStore.remove(imageID: first.id) }
        ExcludedSimulatorRuntimesStore.write(first)

        let again = runtime(id: "178E0003-0000-4000-8000-000000000003", build: "178excl2 ")

        #expect(ExcludedSimulatorRuntimesStore.isExcluded(again))
    }

    @Test func anotherBuildIsNotExcluded() {
        let excluded = runtime(id: "178E0004-0000-4000-8000-000000000004", build: "178EXCL4")
        defer { ExcludedSimulatorRuntimesStore.remove(imageID: excluded.id) }
        ExcludedSimulatorRuntimesStore.write(excluded)

        let other = runtime(id: "178E0005-0000-4000-8000-000000000005", build: "178EXCL5")

        #expect(!ExcludedSimulatorRuntimesStore.isExcluded(other))
    }

    /// An exclusion saved by path before #178 still holds, and moves to the
    /// runtime list so it keeps holding once the image is unmounted.
    @Test func aPathExclusionFromBeforeMovesToTheRuntimeList() {
        let row = runtime(id: "178E0006-0000-4000-8000-000000000006", build: "178EXCL6")
        defer {
            ExcludedSimulatorRuntimesStore.remove(imageID: row.id)
            ExcludedPathsStore.remove(path: row.locationURL)
        }
        ExcludedPathsStore.write(path: row.locationURL, displayName: "iOS 18.4 Runtime")

        #expect(ExcludedSimulatorRuntimesStore.isExcluded(row))
        #expect(!ExcludedPathsStore.contains(path: row.locationURL))
        #expect(ExcludedSimulatorRuntimesStore.allEntries().contains { $0.imageID == row.id })

        let unmounted = runtime(id: row.id, build: row.build, at: imagePath(row.id))
        #expect(ExcludedSimulatorRuntimesStore.isExcluded(unmounted))
    }

    /// Excluded by its volume before #178, now listed at its image: the build in
    /// the volume's name still finds it.
    @Test func anOldVolumeExclusionFindsTheUnmountedRuntimeByBuild() {
        let row = runtime(
            id: "178E0007-0000-4000-8000-000000000007",
            build: "178EXCL7",
            at: imagePath("178E0007-0000-4000-8000-000000000007")
        )
        let oldVolume = URL(fileURLWithPath: "\(Self.volumes)/iOS_178EXCL7", isDirectory: true)
        defer {
            ExcludedSimulatorRuntimesStore.remove(imageID: row.id)
            ExcludedPathsStore.remove(path: oldVolume)
        }
        ExcludedPathsStore.write(path: oldVolume, displayName: "iOS 18.4 Runtime")

        #expect(ExcludedSimulatorRuntimesStore.isExcluded(row))
        #expect(!ExcludedPathsStore.contains(path: oldVolume))
    }

    /// A folder the user excluded above a runtime still covers it, and is kept:
    /// it covers more than the runtime.
    @Test func anExcludedParentFolderStillCoversTheRuntimeAndStays() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-178-\(UUID().uuidString)", isDirectory: true)
        defer { ExcludedPathsStore.remove(path: parent) }
        ExcludedPathsStore.write(path: parent, displayName: "Runtimes")
        let row = runtime(
            id: "178E0008-0000-4000-8000-000000000008",
            build: "178EXCL8",
            at: parent.appendingPathComponent("iOS_178EXCL8").path
        )
        defer { ExcludedSimulatorRuntimesStore.remove(imageID: row.id) }

        #expect(ExcludedSimulatorRuntimesStore.isExcluded(row))
        #expect(ExcludedPathsStore.contains(path: parent))
        #expect(!ExcludedSimulatorRuntimesStore.allEntries().contains { $0.imageID == row.id })
    }

    /// A saved row from the last scan is dropped at launch once its runtime is
    /// excluded, wherever it was listed.
    @Test func anExcludedRuntimeLeavesTheSavedLastScan() {
        let row = runtime(id: "178E0009-0000-4000-8000-000000000009", build: "178EXCL9")
        defer { ExcludedSimulatorRuntimesStore.remove(imageID: row.id) }
        let kept = runtime(id: "178E0010-0000-4000-8000-000000000010", build: "178EXCL10")
        var snapshot = LastScanSnapshot(appBuild: "1")
        snapshot.runtimes = LastScanSnapshot.Section(
            savedAt: Date(), rows: [SavedSimulatorRuntime(row), SavedSimulatorRuntime(kept)]
        )
        ExcludedSimulatorRuntimesStore.write(runtime(id: row.id, build: row.build, at: imagePath(row.id)))

        let readable = PurgeStore.readableLastScan(snapshot, access: .full)

        #expect(readable?.runtimes?.rows.map(\.id) == [kept.id])
    }
}

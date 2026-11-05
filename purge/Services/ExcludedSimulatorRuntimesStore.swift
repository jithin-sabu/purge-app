import Foundation

nonisolated struct ExcludedSimulatorRuntimeEntry: Codable, Sendable, Equatable {
    /// The disk image identifier `simctl runtime list` gave the runtime.
    let imageID: String
    let build: String
    let displayName: String
    /// What `simctl` reported when the runtime was excluded. Settings shows this
    /// rather than measuring: the image may not be mounted.
    let sizeBytes: Int64
    let dateAdded: Date
}

/// What the clean needs to check a runtime row against the exclusion list once
/// the row itself may be gone.
nonisolated struct SimulatorRuntimeHandle: Hashable, Sendable {
    let imageID: String
    let build: String

    var isExcluded: Bool {
        ExcludedSimulatorRuntimesStore.isExcluded(imageID: imageID, build: build)
    }
}

/// Simulator runtimes the user excluded from scans, kept apart from the path list
/// because a runtime has no fixed path. `simctl` reports the mounted volume while
/// macOS has the image mounted and the image file when it hasn't, so an exclusion
/// saved by path let the runtime come back (#178).
///
/// Keyed by image identifier. The build matches too, so a runtime downloaded again
/// under a new identifier stays excluded. Not the runtime identifier
/// (`SimRuntime.iOS-26-3`), which a beta and a release build can share.
///
/// Purely subtractive, like `ExcludedPathsStore`: the scan drops these after the
/// `deletable` filter, so nothing new is ever offered.
enum ExcludedSimulatorRuntimesStore {
    nonisolated private static let store = JSONPathStore<ExcludedSimulatorRuntimeEntry>(
        fileName: "excluded_simulator_runtimes.json"
    )

    /// Where macOS mounts runtime images, each volume named `<platform>_<build>`.
    nonisolated static let volumesRoot = "/Library/Developer/CoreSimulator/Volumes"

    nonisolated static func isExcluded(imageID: String, build: String) -> Bool {
        store.read { entries in
            entries[imageID] != nil
                || entries.values.contains { SimulatorRuntime.isSameBuild($0.build, build) }
        }
    }

    /// The check the scan makes: this list, then the path list, which still holds
    /// runtimes excluded before #178 and any folder the user excluded above one.
    /// A runtime the path list names outright is moved over to this list, so it
    /// keeps matching once the runtime is mounted somewhere else.
    nonisolated static func isExcluded(_ runtime: SimulatorRuntime) -> Bool {
        if isExcluded(imageID: runtime.id, build: runtime.build) { return true }
        if let legacyKey = legacyPathKey(for: runtime) {
            if write(runtime) {
                ExcludedPathsStore.remove(path: URL(fileURLWithPath: legacyKey))
            }
            return true
        }
        return ExcludedPathsStore.isExcluded(runtime.locationURL)
    }

    /// A path-list entry saved for this runtime by an earlier version: its current
    /// location, or the volume it is mounted at, found by the build in the volume's
    /// name while the image is not mounted.
    nonisolated static func legacyPathKey(for runtime: SimulatorRuntime) -> String? {
        if ExcludedPathsStore.contains(path: runtime.locationURL) {
            return runtime.locationURL.standardizedFileURL.resolvingSymlinksInPath().path
        }
        return ExcludedPathsStore.allExcludedPaths().first { key in
            let url = URL(fileURLWithPath: key)
            guard url.deletingLastPathComponent().path == volumesRoot,
                  let separator = url.lastPathComponent.lastIndex(of: "_") else { return false }
            let build = url.lastPathComponent[url.lastPathComponent.index(after: separator)...]
            return SimulatorRuntime.isSameBuild(String(build), runtime.build)
        }
    }

    /// Returns false when the list could not be saved. The exclusion still holds
    /// until Purge quits.
    @discardableResult
    nonisolated static func write(_ runtime: SimulatorRuntime, date: Date = Date()) -> Bool {
        store.update { entries in
            entries[runtime.id] = ExcludedSimulatorRuntimeEntry(
                imageID: runtime.id,
                build: runtime.build,
                displayName: runtime.safetyInfo.headline,
                sizeBytes: runtime.sizeBytes,
                dateAdded: date
            )
            return true
        }
    }

    /// Returns false when the list could not be saved.
    @discardableResult
    nonisolated static func remove(imageID: String) -> Bool {
        store.update { $0.removeValue(forKey: imageID) != nil }
    }

    nonisolated static func allEntries() -> [ExcludedSimulatorRuntimeEntry] {
        store.read { entries in
            entries.values.sorted { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }
}

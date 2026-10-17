import Foundation

/// Which page the Overview tab shows.
nonisolated enum OverviewPage: Equatable, Sendable {
    case summary
    /// Everything else opened as its own page, with its List and Map.
    case everythingElse
}

/// List or Map on the drill-in.
nonisolated enum EverythingElseViewMode: String, CaseIterable, Identifiable, Sendable {
    case list
    case map

    var id: String { rawValue }
}

/// Where the Everything else walk stands right now.
nonisolated enum EverythingElsePhase: Equatable, Sendable {
    case notMeasured
    /// Waiting in the scan queue behind another step.
    case waiting
    case measuring
    case ready
}

/// Everything the Everything else breakdown is computed from, so it is rebuilt
/// only when one of these changes rather than on every render.
struct EverythingElseBreakdownKey: Equatable {
    let inputsRevision: Int
    let measurementRevision: Int
    let everythingElseBytes: Int64
    let excludedPaths: Set<String>
}

/// The Everything else walk (#220): measuring on demand, and the read-only
/// breakdown the Overview row and the drill-in show. There is no delete path in
/// this file, and the views built on it have none either; the only way out of these
/// screens is Show in Finder, Copy Path, opening the app, or hiding a folder, which
/// adds it to the Excluded Paths list.
extension PurgeStore {
    var everythingElsePhase: EverythingElsePhase {
        if scanQueue.active == .everythingElse || isMeasuringEverythingElse {
            return .measuring
        }
        if scanQueue.isQueued(.everythingElse) {
            return .waiting
        }
        return everythingElseMeasurement?.isComplete == true ? .ready : .notMeasured
    }

    /// The Overview row was opened: unfold it and measure if this session has not.
    func openEverythingElse() {
        isEverythingElseExpanded = true
        requestScanIfNeeded(.everythingElse)
    }

    /// The row's chevron, or the Map toggle: Everything else as its own page.
    func showEverythingElsePage() {
        overviewPage = .everythingElse
        selectedTab = .overview
        requestScanIfNeeded(.everythingElse)
    }

    func showOverviewSummary() {
        overviewPage = .summary
    }

    /// Measure again, ahead of anything waiting in the queue.
    func measureEverythingElseAgain() {
        requestScan(.everythingElse)
    }

    /// The scan queue's Everything else step. Groups fill in as their roots
    /// finish; the figure the Overview row shows is the old one until the walk
    /// completes, because a half-measured breakdown would read as the whole.
    func measureEverythingElse() async {
        refreshPermission()
        everythingElseMeasureGeneration += 1
        let generation = everythingElseMeasureGeneration
        isMeasuringEverythingElse = true
        let access: ScanAccess = hasFullDiskAccess ? .full : .limited
        var measurement = EverythingElseMeasurement(access: access)
        everythingElseMeasurement = measurement
        everythingElseMeasurementRevision &+= 1
        defer {
            if everythingElseMeasureGeneration == generation {
                isMeasuringEverythingElse = false
            }
        }

        for await event in scanSources.everythingElse(access) {
            guard everythingElseMeasureGeneration == generation, !Task.isCancelled else { return }
            measurement.apply(event)
            everythingElseMeasurement = measurement
            everythingElseMeasurementRevision &+= 1
        }
        guard everythingElseMeasureGeneration == generation, !Task.isCancelled else { return }
        measurement.isComplete = true
        measurement.completedAt = Date()
        everythingElseMeasurement = measurement
        everythingElseMeasurementRevision &+= 1
    }

    /// The unsorted space split into groups, or nil before the first measure.
    /// Claims against the five categories as they stand now, so a rescan of App
    /// Caches moves bytes between App data and App Caches without a new walk.
    func everythingElseBreakdown(totalBytes: Int64, freeBytes: Int64) -> EverythingElseBreakdown? {
        guard let measurement = everythingElseMeasurement else { return nil }
        let overview = overviewBreakdown(totalBytes: totalBytes, freeBytes: freeBytes)
        let key = EverythingElseBreakdownKey(
            inputsRevision: categoryInputsRevision,
            measurementRevision: everythingElseMeasurementRevision,
            everythingElseBytes: overview.everythingElseBytes,
            excludedPaths: excludedPaths
        )
        if let cached = everythingElseBreakdownCache, cached.key == key {
            return cached.breakdown
        }
        // Keys are symlink-resolved, which spells `/var` where the walk says
        // `/private/var`; both go through the same normalization first.
        let exclusions = ScanExclusions(keys: Set(excludedPaths.map(OverviewSizedItem.normalized)))
        let breakdown = EverythingElseBreakdown(
            measurement: measurement.droppingFolders { exclusions.covers(path: $0) },
            claimedFirst: overviewLiveItemsInClaimOrder(),
            everythingElseBytes: overview.everythingElseBytes
        )
        everythingElseBreakdownCache = (key, breakdown)
        return breakdown
    }

    /// "Hide from Everything else": the folder joins the Excluded Paths list in
    /// Settings, where it can be put back. Nothing is deleted; the remainder
    /// absorbs its bytes.
    func hideFromEverythingElse(_ folder: EverythingElseFolder) {
        ExcludedPathsStore.write(path: folder.url, displayName: folder.name)
        refreshExcludedPaths()
    }
}

extension EverythingElseMeasurement {
    /// The measurement with every folder the user hid taken out. A hidden root
    /// loses its whole figure; a hidden folder inside a root leaves the root's
    /// other folders alone.
    func droppingFolders(where isHidden: (String) -> Bool) -> EverythingElseMeasurement {
        var copy = self
        copy.measuredRoots = measuredRoots.compactMap { measured in
            if isHidden(measured.root.path) { return nil }
            let kept = measured.folders.filter { !isHidden($0.path) }
            guard kept.count != measured.folders.count else { return measured }
            return EverythingElseMeasuredRoot(root: measured.root, folders: kept, looseFileBytes: measured.looseFileBytes)
        }
        return copy
    }
}

import Foundation

/// Where an Overview category stands right now.
nonisolated enum OverviewCategoryPhase: Equatable, Sendable {
    /// Large Files and the app scans read places a limited scan never touches.
    case needsAccess
    case scanning
    /// Waiting in the queue, or for the other half of the App Caches and Dev Tools step.
    case waiting
    /// This session has results.
    case ready
    case notScanned
}

/// Everything the Overview breakdown is computed from, so it is rebuilt only when
/// one of these changes rather than on every scan flush.
struct OverviewBreakdownKey: Equatable {
    let inputsRevision: Int
    let totalBytes: Int64
    let freeBytes: Int64
    let phases: [OverviewCategoryPhase]
    let records: [OverviewCategory: ScanRecord]
    /// A saved Large Files figure counts only while these still match its own.
    let largeFileFilter: LargeFileFilterSnapshot
}

extension PurgeStore {
    func overviewPhase(for category: OverviewCategory) -> OverviewCategoryPhase {
        if category.step.needsFullDiskAccess, !hasFullDiskAccess {
            return .needsAccess
        }
        if isScanning(category) {
            return .scanning
        }
        if isWaitingToScan(category) {
            return .waiting
        }
        return hasResults(for: category) ? .ready : .notScanned
    }

    /// Which Uninstaller view the Leftovers row opens. Installed Apps only when this
    /// session's scan finished and found nothing; while it waits, scans or shows a
    /// saved figure, the row opens Leftovers, which fills in as the scan lands.
    var overviewLeftoversSection: UninstallSection {
        overviewPhase(for: .leftovers) == .ready && orphanLeftovers.isEmpty ? .installedApps : .leftovers
    }

    /// Whether leftovers are still to come: their scan is queued or running.
    var isLeftoversScanPending: Bool {
        scanQueue.active == .leftovers || scanQueue.isQueued(.leftovers) || isScanningOrphans
    }

    var isCommandLineToolsScanPending: Bool {
        scanQueue.active == .commandLineTools || scanQueue.isQueued(.commandLineTools) || isScanningCommandLineTools
    }

    /// The safe-to-clean share of App Caches or Dev Tools. Nil for the categories
    /// Purge never cleans on its own.
    func safeCleanupBytes(for category: OverviewCategory) -> Int64? {
        let summary = safeCleanupSummary
        switch category {
        case .appCaches: return summary.appCacheBytes
        case .devTools: return summary.devToolBytes + summary.projectArtifactBytes
        case .largeFiles, .apps, .leftovers: return nil
        }
    }

    /// The whole disk split into Purge's categories and everything else.
    func overviewBreakdown(totalBytes: Int64, freeBytes: Int64) -> OverviewBreakdown {
        let phases = OverviewCategory.allCases.map(overviewPhase(for:))
        let key = OverviewBreakdownKey(
            inputsRevision: categoryInputsRevision,
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            phases: phases,
            records: scanRecords,
            largeFileFilter: largeFileFilter
        )
        if let cached = overviewBreakdownCache, cached.key == key {
            return cached.breakdown
        }
        var sources: [OverviewCategory: OverviewCategorySource] = [:]
        for (category, phase) in zip(OverviewCategory.allCases, phases) {
            sources[category] = overviewSource(for: category, phase: phase)
        }
        let breakdown = OverviewBreakdown(totalBytes: totalBytes, freeBytes: freeBytes, sources: sources)
        overviewBreakdownCache = (key, breakdown)
        return breakdown
    }

    /// True when the figure on screen is a saved one from an earlier scan. Mirrors
    /// `overviewSource` without building the item lists, since rows and the sidebar ask
    /// on every render.
    func isShowingRecordedFigure(for category: OverviewCategory) -> Bool {
        guard applicableRecord(for: category) != nil else { return false }
        switch overviewPhase(for: category) {
        case .notScanned, .waiting, .scanning: return true
        case .needsAccess, .ready: return false
        }
    }

    /// The saved record the Overview may show for the category. A Large Files
    /// record counted under other filters than today's is left out: its figure
    /// would be read against a filter it never used (#279). A record saved before
    /// filters were stored is shown as it was.
    func applicableRecord(for category: OverviewCategory) -> ScanRecord? {
        guard let record = scanRecords[category] else { return nil }
        if category == .largeFiles, let filter = record.largeFileFilter, filter != largeFileFilter {
            return nil
        }
        return record
    }

    /// The five categories' live items in claim order, for the Everything else
    /// breakdown to claim after. Recorded figures have no items, so they are left
    /// out; their totals are capped by the live ones already.
    func overviewLiveItemsInClaimOrder() -> [OverviewSizedItem] {
        var items: [OverviewSizedItem] = []
        for category in OverviewCategory.allCases {
            guard case .live(let categoryItems) = overviewSource(for: category, phase: overviewPhase(for: category)) else { continue }
            items.append(contentsOf: categoryItems)
        }
        return items
    }

    /// True when any category shows a total saved by an earlier session. Its
    /// paths are unknown, so the Everything else groups can't take it out.
    func overviewShowsRecordedFigures() -> Bool {
        OverviewCategory.allCases.contains { category in
            if case .recorded = overviewSource(for: category, phase: overviewPhase(for: category)) { return true }
            return false
        }
    }

    /// Until a category's scan finishes this session, it shows its saved figure from
    /// the last one, dimmed and dated, while it waits and while it scans (#283). The
    /// live figure takes over when the scan is done, so a reopen never shows a page of
    /// blanks or a total that climbs from zero. A category with no saved figure shows
    /// what its scan has found so far.
    private func overviewSource(
        for category: OverviewCategory,
        phase: OverviewCategoryPhase
    ) -> OverviewCategorySource {
        let record = applicableRecord(for: category)
        switch phase {
        case .needsAccess:
            return .none
        case .ready:
            return .live(overviewItems(for: category))
        case .scanning:
            if let record { return .recorded(record.bytes) }
            return .live(overviewItems(for: category))
        case .waiting, .notScanned:
            if let record { return .recorded(record.bytes) }
            return .none
        }
    }

    /// A step the queue is running counts as scanning from start to finish, even in
    /// the gaps between its passes, so a row never drops back to "Up next" mid-scan.
    private func isScanning(_ category: OverviewCategory) -> Bool {
        switch category {
        case .appCaches:
            return cacheScanStage == .appCaches || isScanningGeneral || isEnrichingGeneral
        case .devTools:
            return cacheScanStage == .devTools || isScanningDeveloper || isScanningProjects || isEnrichingDeveloper
        case .largeFiles:
            return scanQueue.active == .largeFiles || isScanningLargeFiles
        case .apps:
            return scanQueue.active == .apps || isScanningInstalledApps || isMeasuringRemovableTotals
        case .leftovers:
            return scanQueue.active == .leftovers || isScanningOrphans
        }
    }

    private func isWaitingToScan(_ category: OverviewCategory) -> Bool {
        if scanQueue.isQueued(category.step) {
            return true
        }
        // Dev Tools scans after App Caches inside the same step.
        return category == .devTools && cacheScanStage == .appCaches
    }

    private func hasResults(for category: OverviewCategory) -> Bool {
        switch category {
        case .appCaches: return hasSessionCacheScan || hasSessionGeneralScan || !cacheItems.isEmpty
        case .devTools: return hasSessionCacheScan || !devTools.isEmpty || !projectGroups.isEmpty
        case .largeFiles, .apps, .leftovers: return hasSessionResults(for: category.step)
        }
    }

    private func overviewItems(for category: OverviewCategory) -> [OverviewSizedItem] {
        switch category {
        case .appCaches:
            return cacheItems
                .filter { SafetyFilter.all.matches($0.safetyInfo) }
                .flatMap { item in
                    item.locations.map { OverviewSizedItem(path: $0.path.path, bytes: $0.sizeBytes) }
                }
        case .devTools:
            var items: [OverviewSizedItem] = []
            for tool in devTools where tool.isDetected && tool.safetyInfo.level != .unknown {
                items.append(contentsOf: devToolItems(tool))
            }
            for device in simulatorDevices where device.safetyInfo.level != .unknown {
                items.append(OverviewSizedItem(path: device.folderURL.path, bytes: device.sizeOnDisk ?? 0))
            }
            for runtime in simulatorRuntimes where runtime.safetyInfo.level != .unknown {
                items.append(OverviewSizedItem(path: runtime.locationURL.path, bytes: runtime.sizeBytes))
            }
            for artifact in projectGroups.flatMap(\.artifacts) where artifact.safetyInfo.level != .unknown {
                items.append(OverviewSizedItem(path: artifact.path.path, bytes: artifact.sizeBytes))
            }
            return items
        case .largeFiles:
            return Self.overviewItems(forLargeFiles: largeFiles)
        case .apps:
            return installedApps.flatMap { app in
                appFootprintItemsByAppID[app.id]
                    ?? [OverviewSizedItem(path: app.bundleURL.path, bytes: app.bundleSizeBytes)]
            }
        case .leftovers:
            return orphanLeftovers.map { OverviewSizedItem(path: $0.path.path, bytes: $0.sizeBytes) }
        }
    }

    /// The Large Files rows on this disk, which is all the bar shows. A home
    /// folder linked to another drive lists its files there by their
    /// `/Volumes/…` path (#273), and counted they would push the bar past the
    /// used space. String work only, like `OverviewSizedItem.normalized`.
    nonisolated static func overviewItems(forLargeFiles files: [LargeFile]) -> [OverviewSizedItem] {
        files
            .filter { !$0.path.path.hasPrefix("/Volumes/") }
            .map { OverviewSizedItem(path: $0.path.path, bytes: $0.sizeBytes) }
    }

    /// A tool can span several folders. Each gets its own measured size where known;
    /// otherwise the first carries the whole total and the rest are claimed at zero,
    /// so nothing inside them is counted again by a later category.
    private func devToolItems(_ tool: DevTool) -> [OverviewSizedItem] {
        let pairs = Array(zip(tool.paths, tool.standardizedPaths))
        let measured = pairs.map { tool.pathSizeBytesByPath[$0.1] }
        if measured.allSatisfy({ $0 != nil }) {
            return zip(pairs, measured).map { OverviewSizedItem(path: $0.0.0.path, bytes: $0.1 ?? 0) }
        }
        return pairs.enumerated().map { index, pair in
            OverviewSizedItem(path: pair.0.path, bytes: index == 0 ? tool.sizeBytes : 0)
        }
    }
}

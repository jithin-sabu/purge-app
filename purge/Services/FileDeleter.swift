import Foundation
import os

nonisolated struct DeletedItem: Identifiable {
    let id: UUID
    let path: String
    let sizeBytes: Int64
    /// Friendly label from the main list (e.g. explanation headline); nil if unknown.
    let displayName: String?
    /// `false` for items removed directly (e.g. simulators via `simctl delete`).
    let movedToTrash: Bool

    init(path: String, sizeBytes: Int64, displayName: String? = nil, movedToTrash: Bool = true) {
        self.id = UUID()
        self.path = path
        self.sizeBytes = sizeBytes
        self.displayName = displayName
        self.movedToTrash = movedToTrash
    }
}

nonisolated struct FailedDeletionItem: Identifiable {
    let id = UUID()
    let path: String
    let displayName: String
    let reason: CleanFailureReason
    let sizeBytes: Int64
    /// The route that tried it, so Retry tries the same one (#174).
    let route: DeletionRoute

    init(
        path: String,
        displayName: String?,
        reason: CleanFailureReason,
        sizeBytes: Int64 = 0,
        route: DeletionRoute = .cache
    ) {
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.reason = reason
        self.sizeBytes = sizeBytes
        self.route = route
    }
}

nonisolated struct SkippedDeletionItem: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let displayName: String
    let reason: String
    /// `true` when the user should see a "skipped for safety" notice.
    /// `false` for silent never-delete blocks.
    let isUserVisible: Bool
    /// The route that refused it.
    let route: DeletionRoute

    init(
        path: String,
        displayName: String?,
        reason: String,
        isUserVisible: Bool,
        route: DeletionRoute = .cache
    ) {
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.reason = reason
        self.isUserVisible = isUserVisible
        self.route = route
    }
}

nonisolated struct DeletionReport: Identifiable {
    let id = UUID()
    /// Sum of the sizes of items moved to the trash. This is what was *moved*, not
    /// what was reclaimed: the files still occupy the volume until the trash is
    /// emptied. Never present this as freed space.
    let bytesMovedToTrash: Int64
    /// Sum of the sizes of items removed outright rather than trashed (simulators,
    /// via `simctl delete`). These bytes really are gone, so they are not pending.
    let bytesRemovedDirectly: Int64
    let deletedItems: [DeletedItem]
    let failedItems: [FailedDeletionItem]
    let skippedItems: [SkippedDeletionItem]
    /// Volume readings taken immediately before and after the run. `nil` when the
    /// volume could not be read, which stays distinct from a reading of zero.
    let capacityBefore: VolumeCapacity?
    let capacityAfter: VolumeCapacity?
    let timestamp: Date
    /// Paths the privileged helper moved to the Trash but could not fully hand back
    /// to the user. They are gone from their source, but emptying the Trash may ask
    /// for a password. Empty for every ordinary, non-escalated removal.
    var ownershipWarningPaths: [String] = []

    /// The measured volume delta, the only number that may be called reclaimed.
    /// `nil` when it was never measured. May be negative or near zero: a trash move
    /// frees nothing, and other processes write while we measure.
    var bytesReclaimedOnVolume: Int64? {
        guard let capacityBefore, let capacityAfter else { return nil }
        return capacityAfter.availableBytes - capacityBefore.availableBytes
    }

    /// The measured delta, but only when it clears measurement noise. `nil` means
    /// "we cannot claim anything", which is not the same as "zero was reclaimed",
    /// and must never be filled in with `bytesMovedToTrash`.
    var reportableBytesReclaimedOnVolume: Int64? {
        guard let measured = bytesReclaimedOnVolume,
              measured >= VolumeCapacityReader.noiseFloorBytes
        else { return nil }
        return measured
    }

    var movedToTrashCount: Int {
        deletedItems.lazy.filter(\.movedToTrash).count
    }

    /// True when nothing was deleted and at least one item failed: the run did
    /// not do its job, and a scheduled clean stays due. A run that moved some
    /// items, one that only skipped items for safety, and one that removed items
    /// permanently all count as done (#173).
    var movedNothingAndFailed: Bool {
        deletedItems.isEmpty && !failedItems.isEmpty
    }
}

/// What one retry from the completion screen came to (#174).
nonisolated enum RetryOutcome: Sendable, Equatable {
    /// The item went: to the Trash, or outright for a simulator or runtime, which
    /// `movedToTrash` tells apart so the record and the Trash line stay honest.
    case deleted(bytes: Int64, movedToTrash: Bool)
    /// Nothing was at the path any more. Something else removed it since the clean.
    case alreadyGone
    /// Still there, with the reason the route gave this time. A gate's refusal
    /// comes back as `.safetySkipped`, which offers no Retry.
    case failed(CleanFailureReason)
}

/// Outcome of asking CoreSimulator to remove a runtime image.
nonisolated enum SimulatorRuntimeRemoval: Sendable, Equatable {
    case removed
    case failed(String)
}

/// Outcome of asking CoreSimulator to delete one simulator device.
nonisolated enum SimulatorDeviceRemoval: Sendable, Equatable {
    case removed
    /// `detail` is simctl's own text and exit status, for the log only.
    case failed(CleanFailureReason, detail: String)
}

/// Deletion engine. Runs off the main actor (`@concurrent`) so large removals
/// never block the UI; progress reaches the UI via the `onProgress` buffer.
nonisolated final class FileDeleter: Sendable {
    typealias SimulatorRuntimeRemover = @Sendable (_ identifier: String) -> SimulatorRuntimeRemoval
    typealias SimulatorDeviceRemover = @Sendable (_ udid: String, _ folder: URL) -> SimulatorDeviceRemoval
    typealias PrivilegedMover = @Sendable (_ urls: [URL]) async -> PrivilegedMoveResult
    typealias Trasher = @Sendable (_ url: URL) throws -> Void

    /// How one item moves to the Trash. Tests hand in a fake so nothing they make
    /// reaches the user's own Trash (#171).
    private let trash: Trasher

    /// The home folder the user-selected gates check against. Tests hand in a
    /// temporary one. The cache route never uses it: `DeletionSafetyPolicy`
    /// knows only the real home, so its checks keep that one.
    private let home: URL

    /// How a simulator runtime row is removed. The live one calls `simctl`; tests
    /// hand in a fake so the dispatch can be checked without CoreSimulator.
    private let simulatorRuntimeRemover: SimulatorRuntimeRemover

    /// How a simulator device row is removed. Same reason as the runtime remover.
    private let simulatorDeviceRemover: SimulatorDeviceRemover

    /// Moves root-owned paths to the Trash through the helper. Tests hand in a fake
    /// so the routing can be checked without a registered helper.
    private let privilegedMover: PrivilegedMover

    /// Whether `macOS Install Data` still holds only leftovers from a finished update.
    private let installLeftoverRule: @Sendable () -> Bool

    init(
        simulatorRuntimeRemover: @escaping SimulatorRuntimeRemover = FileDeleter.removeSimulatorRuntime,
        simulatorDeviceRemover: @escaping SimulatorDeviceRemover = { FileDeleter.removeSimulatorDevice(udid: $0, folder: $1) },
        privilegedMover: @escaping PrivilegedMover = { await PrivilegedUninstall.moveToTrash($0) },
        installLeftoverRule: @escaping @Sendable () -> Bool = { MacOSInstallLeftovers.isLeftover() },
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        trash: @escaping Trasher = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.simulatorRuntimeRemover = simulatorRuntimeRemover
        self.simulatorDeviceRemover = simulatorDeviceRemover
        self.privilegedMover = privilegedMover
        self.installLeftoverRule = installLeftoverRule
        self.home = home
        self.trash = trash
    }

    /// - Parameter pathToDisplayName: Keys should be standardized file paths (`URL.standardizedFileURL.path`).
    /// - Parameter pathToExpectedSizeBytes: Pre-scan sizes from deletion candidates; avoids re-measuring folders at delete time.
    /// - Parameter simulatorRuntimeIDsByPath: Rows that are simulator runtimes, keyed by
    ///   standardized path, with the image identifier `simctl runtime delete` takes. These
    ///   never go near the filesystem policy: the path is a root-owned mount that only
    ///   CoreSimulator may remove.
    /// - Parameter onProgress: Called on the engine's executor after each item starts / successfully
    ///   deletes. Must be cheap; UI publishing is buffered elsewhere.
    @concurrent func deleteItems(
        at urls: [URL],
        pathToDisplayName: [String: String] = [:],
        pathToExpectedSizeBytes: [String: Int64] = [:],
        simulatorRuntimeIDsByPath: [String: String] = [:],
        onProgress: (@Sendable (DeletionProgressEvent) -> Void)? = nil
    ) async throws -> DeletionReport {
        var bytesMovedToTrash: Int64 = 0
        var bytesRemovedDirectly: Int64 = 0
        var deletedItems: [DeletedItem] = []
        var failedItems: [FailedDeletionItem] = []
        var fullDiskAccess: Bool?
        var skippedItems: [SkippedDeletionItem] = []
        var ownershipWarningPaths: [String] = []
        var installLeftovers: [URL] = []
        let volumeURL = FileManager.default.homeDirectoryForCurrentUser
        let capacityBefore = VolumeCapacityReader.read(for: volumeURL)

        for url in urls {
            let standardizedPath = url.standardizedFileURL.path
            let friendlyTitle = pathToDisplayName[standardizedPath]

            // Root-owned, so a plain Trash move can only fail. The helper moves them
            // after this loop, all in one request (#127).
            if MacOSInstallLeftovers.isEntryPath(standardizedPath) {
                if DeletionSafetyPolicy.isOfferedForCleanup(url),
                   DeletionSafetyPolicy.evaluate(url) == .allow {
                    installLeftovers.append(url)
                } else {
                    skippedItems.append(SkippedDeletionItem(
                        path: url.path,
                        displayName: friendlyTitle,
                        reason: "This file was skipped for safety",
                        isUserVisible: true
                    ))
                }
                continue
            }

            if let runtimeID = simulatorRuntimeIDsByPath[standardizedPath] {
                onProgress?(.itemStarted(name: friendlyTitle ?? url.lastPathComponent))
                // Never measured here: the location is an 8 GB mounted image, and
                // the scan already carries what `simctl` reported.
                let size = pathToExpectedSizeBytes[standardizedPath] ?? 0
                switch simulatorRuntimeRemover(runtimeID) {
                case .removed:
                    bytesRemovedDirectly += size
                    deletedItems.append(DeletedItem(
                        path: url.path,
                        sizeBytes: size,
                        displayName: friendlyTitle,
                        movedToTrash: false
                    ))
                    onProgress?(.itemDeleted(sizeBytes: size))
                case .failed(let reason):
                    NSLog("Purge: failed to delete simulator runtime %@ — %@", runtimeID, reason)
                    failedItems.append(FailedDeletionItem(
                        path: url.path,
                        displayName: friendlyTitle,
                        reason: .unknown,
                        sizeBytes: size
                    ))
                }
                continue
            }

            // The scan offered every row here, so a refusal now means the answer
            // changed since: Mail opened, Spotify downloaded music, a project
            // started holding state. The row says so instead of vanishing (#174).
            guard DeletionSafetyPolicy.isOfferedForCleanup(url) else {
                skippedItems.append(SkippedDeletionItem(
                    path: url.path,
                    displayName: friendlyTitle,
                    reason: "This file was skipped for safety",
                    isUserVisible: true
                ))
                continue
            }

            let decision = DeletionSafetyPolicy.evaluate(url)
            switch decision {
            case .allow:
                // The real home, the one `evaluate` just allowed this path under.
                let allowlistHome = FileManager.default.homeDirectoryForCurrentUser
                let failsCursorBoundary = CursorAgentLeftoverScanPolicy.looksLikeCursorLeftoverPath(url, home: allowlistHome)
                    && !CursorAgentLeftoverScanPolicy.passesImmediateTrashBoundary(url)
                let failsWorktreeBoundary = AgentWorktreeScanPolicy.looksLikeAgentWorktreePath(url, home: allowlistHome)
                    && !AgentWorktreeScanPolicy.passesImmediateTrashBoundary(url)
                if failsCursorBoundary || failsWorktreeBoundary {
                    skippedItems.append(SkippedDeletionItem(
                        path: url.path,
                        displayName: friendlyTitle,
                        reason: "This file was skipped for safety",
                        isUserVisible: true
                    ))
                    continue
                }

                onProgress?(.itemStarted(name: friendlyTitle ?? url.lastPathComponent))
                // A folder emptied entry by entry sums its entries below, so it is
                // never measured whole here.
                let deletesContentsOnly = DeletionSafetyPolicy.shouldDeleteContentsOnly(url)
                let size = deletesContentsOnly
                    ? 0
                    : (pathToExpectedSizeBytes[standardizedPath] ?? FolderSizing.directoryByteSize(at: url))

                if deletesContentsOnly {
                    var didDeleteAnyContent = false
                    var movedBytes: Int64 = 0

                    do {
                        let contents = try FileManager.default.contentsOfDirectory(
                            at: url,
                            includingPropertiesForKeys: Self.contentsEntryKeys,
                            options: [.skipsHiddenFiles]
                        )
                        // Entries move one at a time, and a Telegram media folder can
                        // hold tens of thousands. Each one reports its own size as it
                        // moves, so the progress screen keeps moving, and the total
                        // leaves out entries the policy refuses, failed moves and
                        // hidden files instead of claiming the folder's scanned size
                        // (#59). Measuring here also stops Crash Reports being counted
                        // twice when it is emptied before Application Logs.
                        let offered = contents.filter { DeletionSafetyPolicy.isOfferedForCleanup($0) }
                        let entrySizes = Self.contentsEntrySizes(offered)
                        for contentURL in offered {
                            let entryBytes = entrySizes[contentURL] ?? 0
                            do {
                                try trash(contentURL)
                                didDeleteAnyContent = true
                                movedBytes += entryBytes
                                onProgress?(.itemPartlyDeleted(sizeBytes: entryBytes))
                            } catch {
                                recordDeletionFailure(
                                    path: contentURL.path,
                                    error: error,
                                    displayName: contentURL.lastPathComponent,
                                    sizeBytes: entryBytes,
                                    route: .cache,
                                    failedItems: &failedItems,
                                    fullDiskAccess: &fullDiskAccess
                                )
                            }
                        }
                    } catch {
                        // A folder that cannot even be listed is a failure with a
                        // reason, usually Full Disk Access, not a folder that was
                        // never there (#174).
                        recordDeletionFailure(
                            path: url.path,
                            error: error,
                            displayName: friendlyTitle,
                            sizeBytes: pathToExpectedSizeBytes[standardizedPath] ?? 0,
                            route: .cache,
                            failedItems: &failedItems,
                            fullDiskAccess: &fullDiskAccess
                        )
                    }

                    if didDeleteAnyContent {
                        bytesMovedToTrash += movedBytes
                        deletedItems.append(DeletedItem(
                            path: url.path,
                            sizeBytes: movedBytes,
                            displayName: friendlyTitle
                        ))
                        onProgress?(.itemDeleted(sizeBytes: 0))
                    }
                } else if let udid = Self.coreSimulatorDeviceUDID(from: url) {
                    switch simulatorDeviceRemover(udid, url) {
                    case .removed:
                        bytesRemovedDirectly += size
                        deletedItems.append(DeletedItem(
                            path: url.path,
                            sizeBytes: size,
                            displayName: friendlyTitle,
                            movedToTrash: false
                        ))
                        onProgress?(.itemDeleted(sizeBytes: size))
                    case .failed(let reason, let detail):
                        Self.simulatorLog.error(
                            "simctl could not delete simulator \(udid, privacy: .public): \(detail, privacy: .public)"
                        )
                        failedItems.append(FailedDeletionItem(
                            path: url.path,
                            displayName: friendlyTitle,
                            reason: reason,
                            sizeBytes: size
                        ))
                    }
                } else {
                    // Re-check after sizing. A browser can start using a framework
                    // folder, or retarget Current onto it, during that wait.
                    guard DeletionSafetyPolicy.isOfferedForCleanup(url) else {
                        skippedItems.append(SkippedDeletionItem(
                            path: url.path,
                            displayName: friendlyTitle,
                            reason: "This file was skipped for safety",
                            isUserVisible: true
                        ))
                        continue
                    }
                    do {
                        try trash(url)
                        bytesMovedToTrash += size
                        deletedItems.append(DeletedItem(path: url.path, sizeBytes: size, displayName: friendlyTitle))
                        onProgress?(.itemDeleted(sizeBytes: size))
                    } catch {
                        recordDeletionFailure(
                            path: url.path,
                            error: error,
                            displayName: friendlyTitle,
                            sizeBytes: size,
                            route: .cache,
                            failedItems: &failedItems,
                            fullDiskAccess: &fullDiskAccess
                        )
                    }
                }

            case .blockedNeverDelete, .blockedNotWhitelisted:
                let reason = decision.skipReason ?? "Skipped for safety"
                skippedItems.append(
                    SkippedDeletionItem(
                        path: url.path,
                        displayName: friendlyTitle,
                        reason: reason,
                        isUserVisible: decision.isUserVisibleSkip
                    )
                )
            }
        }

        if !installLeftovers.isEmpty {
            await moveInstallLeftovers(
                installLeftovers,
                pathToDisplayName: pathToDisplayName,
                pathToExpectedSizeBytes: pathToExpectedSizeBytes,
                bytesMovedToTrash: &bytesMovedToTrash,
                deletedItems: &deletedItems,
                failedItems: &failedItems,
                skippedItems: &skippedItems,
                ownershipWarningPaths: &ownershipWarningPaths,
                onProgress: onProgress
            )
        }

        let capacityAfter = VolumeCapacityReader.read(for: volumeURL)
        let report = DeletionReport(
            bytesMovedToTrash: bytesMovedToTrash,
            bytesRemovedDirectly: bytesRemovedDirectly,
            deletedItems: deletedItems,
            failedItems: failedItems,
            skippedItems: skippedItems,
            capacityBefore: capacityBefore,
            capacityAfter: capacityAfter,
            timestamp: Date(),
            ownershipWarningPaths: ownershipWarningPaths
        )
        return report
    }

    /// Hands the selected `macOS Install Data` entries to the helper in one request.
    /// One request matters: every move changes the folder's date, so the helper
    /// decides the date rule once, before the first move. The rule is checked here
    /// too, so a waiting update is never even sent. There is no other route: with
    /// the helper off, the entries come back as one-time setup.
    private func moveInstallLeftovers(
        _ urls: [URL],
        pathToDisplayName: [String: String],
        pathToExpectedSizeBytes: [String: Int64],
        bytesMovedToTrash: inout Int64,
        deletedItems: inout [DeletedItem],
        failedItems: inout [FailedDeletionItem],
        skippedItems: inout [SkippedDeletionItem],
        ownershipWarningPaths: inout [String],
        onProgress: (@Sendable (DeletionProgressEvent) -> Void)?
    ) async {
        guard installLeftoverRule() else {
            for url in urls {
                skippedItems.append(SkippedDeletionItem(
                    path: url.path,
                    displayName: pathToDisplayName[url.standardizedFileURL.path],
                    reason: "This file was skipped for safety",
                    isUserVisible: true
                ))
            }
            return
        }

        let first = urls[0].standardizedFileURL.path
        onProgress?(.itemStarted(name: pathToDisplayName[first] ?? urls[0].lastPathComponent))
        // Each starts as a failure, so the shared folding below credits only what the
        // helper reports moved.
        let pending = urls.map { url in
            let key = url.standardizedFileURL.path
            return FailedDeletionItem(
                path: url.path,
                displayName: pathToDisplayName[key],
                reason: .unknown,
                sizeBytes: pathToExpectedSizeBytes[key] ?? FolderSizing.directoryByteSize(at: url)
            )
        }
        failedItems.append(contentsOf: pending)
        let result = await privilegedMover(urls)
        foldPrivilegedResult(
            result,
            candidateIDs: Set(pending.map(\.id)),
            bytesMovedToTrash: &bytesMovedToTrash,
            deletedItems: &deletedItems,
            failedItems: &failedItems,
            ownershipWarningPaths: &ownershipWarningPaths,
            pathToDisplayName: pathToDisplayName,
            onProgress: onProgress
        )
    }

    /// The route for items the user picks one by one: Large Files rows (single
    /// files, and whole VM and Safari download bundles), AI models, and the
    /// uninstaller's apps, leftovers and command-line tools. Each path must
    /// pass one of the four policy gates below; this route never consults the cache allowlist,
    /// which refuses the user's own files by design. Items always move to Trash.
    ///
    /// `aiModelPaths` are the components of AI model rows. They answer to
    /// `AIModelScanPolicy` alone: several stores sit under `~/Library`, where
    /// the uninstall gate admits any path, so the model gate's refusals (a
    /// store root, GPT4All's local-documents database) would never hold if
    /// another gate could still say yes (#157).
    @concurrent func deleteUserSelectedFiles(
        at urls: [URL],
        pathToDisplayName: [String: String] = [:],
        pathToExpectedSizeBytes: [String: Int64] = [:],
        aiModelPaths: Set<String> = [],
        privilegedEligiblePaths: Set<String> = [],
        onProgress: (@Sendable (DeletionProgressEvent) -> Void)? = nil
    ) async throws -> DeletionReport {
        var bytesMovedToTrash: Int64 = 0
        var deletedItems: [DeletedItem] = []
        var failedItems: [FailedDeletionItem] = []
        var fullDiskAccess: Bool?
        var skippedItems: [SkippedDeletionItem] = []
        var ownershipWarningPaths: [String] = []
        let volumeURL = home
        let capacityBefore = VolumeCapacityReader.read(for: volumeURL)
        // A command-line tool's shims are eligible only while they point into
        // its folder, so the pairs are read once, before anything moves (#225).
        let commandLineToolPaths = CommandLineToolScanPolicy.eligiblePaths(home: home)

        for url in urls {
            let standardizedPath = url.standardizedFileURL.path
            let friendlyTitle = pathToDisplayName[standardizedPath]

            // AI model components live in hidden runtime directories that the
            // large-file policy deliberately refuses, so they carry their own
            // equally narrow gate. The uninstaller adds a third: an app bundle in
            // an app root, or a leftover inside a known Library location. The
            // fourth is a command-line tool's folder, shims and job plists.
            let isAIModel = aiModelPaths.contains(standardizedPath)
            let isEligible = isAIModel
                ? AIModelScanPolicy.isEligibleForDeletion(url, home: home)
                : LargeFileScanPolicy.isEligibleForDeletion(url, home: home)
                    || AIModelScanPolicy.isEligibleForDeletion(url, home: home)
                    || AppUninstallScanPolicy.isEligibleForUninstallDeletion(url, home: home)
                    || commandLineToolPaths.contains(standardizedPath)
            // Stamped here, from the flags this call was given, so a retry asks the
            // same gate with the same flags (#174).
            let route = DeletionRoute.userSelected(
                isAIModel: isAIModel,
                privilegedEligible: privilegedEligiblePaths.contains(standardizedPath)
            )
            guard isEligible else {
                skippedItems.append(SkippedDeletionItem(
                    path: url.path,
                    displayName: friendlyTitle,
                    reason: "This file was skipped for safety",
                    isUserVisible: true,
                    route: route
                ))
                continue
            }

            onProgress?(.itemStarted(name: friendlyTitle ?? url.lastPathComponent))
            let size = pathToExpectedSizeBytes[standardizedPath] ?? FolderSizing.singleFileSize(at: url)
            do {
                try trash(url)
                bytesMovedToTrash += size
                deletedItems.append(DeletedItem(path: url.path, sizeBytes: size, displayName: friendlyTitle))
                onProgress?(.itemDeleted(sizeBytes: size))
            } catch {
                recordDeletionFailure(
                    path: url.path,
                    error: error,
                    displayName: friendlyTitle,
                    sizeBytes: size,
                    route: route,
                    failedItems: &failedItems,
                    fullDiskAccess: &fullDiskAccess
                )
            }
        }

        // Only paths the uninstall planner proved have a non-writable parent may use
        // the administrator helper. Other deletion routes pass an empty set.
        if !privilegedEligiblePaths.isEmpty {
            await applyPrivilegedFallback(
                bytesMovedToTrash: &bytesMovedToTrash,
                deletedItems: &deletedItems,
                failedItems: &failedItems,
                ownershipWarningPaths: &ownershipWarningPaths,
                privilegedEligiblePaths: privilegedEligiblePaths,
                pathToDisplayName: pathToDisplayName,
                onProgress: onProgress
            )
        }

        let capacityAfter = VolumeCapacityReader.read(for: volumeURL)
        let report = DeletionReport(
            bytesMovedToTrash: bytesMovedToTrash,
            bytesRemovedDirectly: 0,
            deletedItems: deletedItems,
            failedItems: failedItems,
            skippedItems: skippedItems,
            capacityBefore: capacityBefore,
            capacityAfter: capacityAfter,
            timestamp: Date(),
            ownershipWarningPaths: ownershipWarningPaths
        )
        return report
    }

    /// Escalates only explicit uninstall paths whose ordinary move failed and whose
    /// parent folder is not writable. When the helper is enabled, successful moves
    /// fold into `deletedItems`; otherwise the result screen can offer one-time setup.
    /// Nothing here shows a system prompt on its own.
    private func applyPrivilegedFallback(
        bytesMovedToTrash: inout Int64,
        deletedItems: inout [DeletedItem],
        failedItems: inout [FailedDeletionItem],
        ownershipWarningPaths: inout [String],
        privilegedEligiblePaths: Set<String>,
        pathToDisplayName: [String: String],
        onProgress: (@Sendable (DeletionProgressEvent) -> Void)?
    ) async {
        // With Full Disk Access granted, an ownership denial resolves to `.unknown`.
        // Busy, system-protected, and privacy-protected failures keep their original
        // handling and are never silently retried as root.
        let candidates = failedItems.filter {
            $0.reason == .unknown
                && privilegedEligiblePaths.contains(URL(fileURLWithPath: $0.path).standardizedFileURL.path)
                && FileManager.default.fileExists(atPath: $0.path)
        }
        guard !candidates.isEmpty else { return }

        let result = await privilegedMover(candidates.map { URL(fileURLWithPath: $0.path) })
        foldPrivilegedResult(
            result,
            candidateIDs: Set(candidates.map(\.id)),
            bytesMovedToTrash: &bytesMovedToTrash,
            deletedItems: &deletedItems,
            failedItems: &failedItems,
            ownershipWarningPaths: &ownershipWarningPaths,
            pathToDisplayName: pathToDisplayName,
            onProgress: onProgress
        )
    }

    /// Folds a helper result back into the run. Moved items are credited; an item
    /// the helper may still be finishing counts only if it is gone from disk. A
    /// candidate still present is a real failure when the helper tried, and one-time
    /// setup (`.needsAdministrator`) when it isn't on. Other failures pass through.
    private func foldPrivilegedResult(
        _ result: PrivilegedMoveResult,
        candidateIDs: Set<UUID>,
        bytesMovedToTrash: inout Int64,
        deletedItems: inout [DeletedItem],
        failedItems: inout [FailedDeletionItem],
        ownershipWarningPaths: inout [String],
        pathToDisplayName: [String: String],
        onProgress: (@Sendable (DeletionProgressEvent) -> Void)?
    ) {
        let movedPaths = Set(result.moved.map { $0.standardizedFileURL.path })
        let indeterminatePaths = Set(result.indeterminate.map { $0.standardizedFileURL.path })
        let ownershipIncompletePaths = Set(result.ownershipIncomplete.map { $0.standardizedFileURL.path })

        // Records a moved item: credits its bytes, lists it as deleted, advances
        // progress, and carries forward any "emptying may ask for a password" note.
        func recordMoved(_ item: FailedDeletionItem, standardized: String) {
            bytesMovedToTrash += item.sizeBytes
            deletedItems.append(DeletedItem(
                path: item.path,
                sizeBytes: item.sizeBytes,
                displayName: pathToDisplayName[standardized] ?? item.displayName
            ))
            if ownershipIncompletePaths.contains(standardized) {
                ownershipWarningPaths.append(item.path)
            }
            onProgress?(.itemDeleted(sizeBytes: item.sizeBytes))
        }

        var stillFailed: [FailedDeletionItem] = []
        for item in failedItems {
            let standardized = URL(fileURLWithPath: item.path).standardizedFileURL.path
            if movedPaths.contains(standardized) {
                recordMoved(item, standardized: standardized)
            } else if indeterminatePaths.contains(standardized) {
                // The helper timed out and may still be finishing. If the source is
                // already gone, the move did land — credit it rather than leaving a
                // removal button stuck forever. If it is still on disk, keep the
                // honest original error and let the uncertainty stand.
                if FileManager.default.fileExists(atPath: item.path) {
                    stillFailed.append(item)
                } else {
                    recordMoved(item, standardized: standardized)
                }
            } else if candidateIDs.contains(item.id) {
                if result.helperAvailable {
                    // An enabled helper attempted the move and the item is still here:
                    // that is a real failure, not a missing permission. Keep the honest
                    // original reason so the user sees "Retry", not "Set Up" again.
                    stillFailed.append(item)
                } else {
                    // Helper isn't enabled yet: present it as one-time setup.
                    stillFailed.append(FailedDeletionItem(
                        path: item.path,
                        displayName: item.displayName,
                        reason: .needsAdministrator,
                        sizeBytes: item.sizeBytes,
                        route: item.route
                    ))
                }
            } else {
                stillFailed.append(item)
            }
        }
        failedItems = stillFailed
    }

    /// True when `deleteItems` removes this URL for good instead of moving it to the
    /// Trash: a simulator runtime whose path is in `simulatorRuntimePaths`, or a
    /// simulator device folder. Confirmations use the same rule as the engine.
    static func removesDirectly(_ url: URL, simulatorRuntimePaths: Set<String>) -> Bool {
        if simulatorRuntimePaths.contains(url.standardizedFileURL.path) { return true }
        return coreSimulatorDeviceUDID(from: url) != nil
    }

    /// Returns the simulator UDID when `url` is exactly `…/CoreSimulator/Devices/{UUID}`.
    private static func coreSimulatorDeviceUDID(from url: URL) -> String? {
        let std = url.standardizedFileURL
        let name = std.lastPathComponent
        guard UUID(uuidString: name) != nil else { return nil }
        guard std.deletingLastPathComponent().lastPathComponent == "Devices" else { return nil }
        guard std.path.contains("CoreSimulator/Devices") else { return nil }
        return name
    }

    /// Deleting a large device is real disk work, so this is generous — but still bounded, so a
    /// wedged CoreSimulator cannot leave the delete run hanging forever.
    private static let simctlDeleteTimeout: TimeInterval = 120
    private static let simctlDeviceListTimeout: TimeInterval = 30

    /// `simctl delete` removes the folder and the list entry before it exits: 0.07 s
    /// for a new device on the dev Mac. The few extra checks only cover a slow disk.
    private static let simctlDeviceGoneChecks = 4

    /// Public on purpose: simctl's text is the only way to read a failed device
    /// delete from someone's log (#161).
    private static let simulatorLog = Logger(subsystem: "io.getpurge.app", category: "simulators")

    /// Prefetched with a contents-only listing, so sizing a file costs no extra stat.
    private static let contentsEntryKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey
    ]

    /// On-disk size of each entry about to be moved: the allocated size for files and
    /// links, and one batched `du` pass (the scanner's own measure) for folders.
    static func contentsEntrySizes(_ entries: [URL]) -> [URL: Int64] {
        var sizes: [URL: Int64] = [:]
        var folders: [URL] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(contentsEntryKeys))
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                folders.append(entry)
            } else {
                sizes[entry] = Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        if !folders.isEmpty {
            let measured = FolderSizing.directorySizes(at: folders)
            for folder in folders {
                sizes[folder] = measured[folder.standardizedFileURL.path] ?? 0
            }
        }
        return sizes
    }

    /// Asks CoreSimulator to delete one device. It counts as removed only when the
    /// UDID is gone from `simctl list devices` and its folder is gone, whatever
    /// simctl's exit code said.
    static func removeSimulatorDevice(
        udid: String,
        folder: URL,
        runSimctl: Simctl.Runner = Simctl.run,
        folderExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        pollInterval: TimeInterval = 0.5
    ) -> SimulatorDeviceRemoval {
        guard let result = runSimctl(["delete", udid], simctlDeleteTimeout) else {
            return .failed(.fromSimctl(nil), detail: "could not launch simctl")
        }

        let checks = result.succeeded ? simctlDeviceGoneChecks : 1
        for check in 0..<checks {
            if check > 0 { Thread.sleep(forTimeInterval: pollInterval) }
            if isSimulatorDeviceListed(udid, runSimctl: runSimctl) == false, !folderExists(folder) {
                return .removed
            }
        }

        let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail: String
        if result.timedOut {
            detail = "timed out after \(Int(simctlDeleteTimeout))s"
        } else if result.status == 0 {
            detail = "exit 0, but the device is still listed or its folder is still there"
        } else {
            detail = "exit \(result.status): \(stderr.isEmpty ? "no error text" : stderr)"
        }
        // simctl said yes and the device is still there: nothing in its text names
        // a cause, so this stays unknown and a retry stays on offer.
        let reason: CleanFailureReason = result.succeeded ? .unknown : .fromSimctl(result)
        return .failed(reason, detail: detail)
    }

    /// `nil` when the list could not be read, which never counts as gone.
    private static func isSimulatorDeviceListed(_ udid: String, runSimctl: Simctl.Runner) -> Bool? {
        guard let listing = runSimctl(["list", "devices", "--json"], simctlDeviceListTimeout),
              listing.succeeded,
              let root = try? JSONSerialization.jsonObject(with: listing.stdout) as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: Any]
        else { return nil }
        return devicesByRuntime.values.contains { runtimeDevices in
            (runtimeDevices as? [[String: Any]])?.contains {
                ($0["udid"] as? String)?.caseInsensitiveCompare(udid) == .orderedSame
            } == true
        }
    }

    /// `simctl runtime delete` hands the work to simdiskimaged and returns at once
    /// with exit 0. The image is unmounted and dropped from the list a few seconds
    /// later, so success is the identifier vanishing from `runtime list`, not the
    /// exit code. Measured at 5 s for an 8 GB image; the budget leaves room for a
    /// slow disk and the unmount retries the daemon makes when the volume is busy.
    private static let simctlRuntimeDeleteTimeout: TimeInterval = 180
    private static let simctlRuntimeListTimeout: TimeInterval = 30
    private static let simctlRuntimePollInterval: TimeInterval = 1

    /// Asks CoreSimulator to remove one runtime image, then waits for it to be gone.
    static func removeSimulatorRuntime(identifier: String) -> SimulatorRuntimeRemoval {
        guard let result = Simctl.run(["runtime", "delete", identifier], timeout: simctlRuntimeDeleteTimeout) else {
            return .failed("Could not launch simctl")
        }
        if result.timedOut {
            return .failed("simctl runtime delete timed out after \(Int(simctlRuntimeDeleteTimeout))s")
        }
        if result.status != 0 {
            let errText = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(errText.isEmpty ? "simctl runtime delete failed (exit \(result.status))" : errText)
        }

        let deadline = Date().addingTimeInterval(simctlRuntimeDeleteTimeout)
        while Date() < deadline {
            switch isSimulatorRuntimeListed(identifier) {
            case .some(false):
                return .removed
            case .some(true), .none:
                Thread.sleep(forTimeInterval: simctlRuntimePollInterval)
            }
        }
        return .failed("runtime still listed after \(Int(simctlRuntimeDeleteTimeout))s")
    }

    /// `nil` when the list could not be read.
    private static func isSimulatorRuntimeListed(_ identifier: String) -> Bool? {
        guard let listing = Simctl.run(["runtime", "list", "-j"], timeout: simctlRuntimeListTimeout),
              listing.succeeded,
              let root = try? JSONSerialization.jsonObject(with: listing.stdout) as? [String: Any]
        else { return nil }
        return root[identifier] != nil
    }

    /// Retries one failed item through the route that tried it the first time, so
    /// the same gate decides again with the same flags (#174). A Large Files row
    /// retried through the cache route used to be refused there every time and
    /// vanish from the report, which left Retry on the screen for good.
    func retryDeleteItem(
        at url: URL,
        displayName: String?,
        expectedSizeBytes: Int64,
        route: DeletionRoute,
        simulatorRuntimeID: String? = nil
    ) async -> RetryOutcome {
        let key = url.standardizedFileURL.path
        // A runtime or device row's path is only a handle for `simctl`, so only a
        // file row can be seen to be gone.
        let isSimulatorHandle = simulatorRuntimeID != nil || Self.coreSimulatorDeviceUDID(from: url) != nil
        if !isSimulatorHandle, !Self.stillOnDisk(url) { return .alreadyGone }

        let names = [key: displayName ?? url.lastPathComponent]
        let sizes = [key: expectedSizeBytes]
        let report: DeletionReport
        do {
            switch route {
            case .cache:
                report = try await deleteItems(
                    at: [url],
                    pathToDisplayName: names,
                    pathToExpectedSizeBytes: sizes,
                    simulatorRuntimeIDsByPath: simulatorRuntimeID.map { [key: $0] } ?? [:]
                )
            case .userSelected(let isAIModel, let privilegedEligible):
                report = try await deleteUserSelectedFiles(
                    at: [url],
                    pathToDisplayName: names,
                    pathToExpectedSizeBytes: sizes,
                    aiModelPaths: isAIModel ? [key] : [],
                    privilegedEligiblePaths: privilegedEligible ? [key] : []
                )
            case .lockedUninstall:
                // A held app is finished bundle first by the store, never one path
                // at a time here. The row stays as it is.
                return .failed(.needsAdministrator)
            }
        } catch {
            return .failed(.unknown)
        }

        if !report.deletedItems.isEmpty {
            return .deleted(
                bytes: report.bytesMovedToTrash + report.bytesRemovedDirectly,
                movedToTrash: report.deletedItems.allSatisfy(\.movedToTrash)
            )
        }
        if let failed = report.failedItems.first { return .failed(failed.reason) }
        if !report.skippedItems.isEmpty { return .failed(.safetySkipped) }
        // The move found nothing there: it went some other way since the clean.
        return .alreadyGone
    }

    /// Whether something is still at `url`, the link itself for a symlink. Only a
    /// clear "no such file" counts as gone: a path that cannot be read at all is
    /// still a failure to show, not a row to drop.
    private static func stillOnDisk(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        return !(errno == ENOENT || errno == ENOTDIR)
    }

    /// Probes Full Disk Access the first time a run needs to know, then reuses the
    /// answer. A folder whose contents all fail used to probe once per entry (#190).
    private static func fullDiskAccess(cachedIn cached: inout Bool?) -> Bool {
        if let cached { return cached }
        let granted = PermissionChecker().hasFullDiskAccess()
        cached = granted
        return granted
    }

    private func recordDeletionFailure(
        path: String,
        error: Error,
        displayName: String?,
        sizeBytes: Int64,
        route: DeletionRoute,
        failedItems: inout [FailedDeletionItem],
        fullDiskAccess: inout Bool?
    ) {
        guard let reason = CleanFailureReason.resolved(
            from: error,
            path: path,
            fullDiskAccessGranted: Self.fullDiskAccess(cachedIn: &fullDiskAccess)
        ) else {
            NSLog("Purge: item already gone, skipping %@", path)
            return
        }
        NSLog("Purge: failed to delete %@ — %@", path, error.localizedDescription)
        failedItems.append(FailedDeletionItem(
            path: path,
            displayName: displayName,
            reason: reason,
            sizeBytes: sizeBytes,
            route: route
        ))
    }
}

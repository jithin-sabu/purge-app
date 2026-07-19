import Foundation

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

    init(path: String, displayName: String?, reason: CleanFailureReason, sizeBytes: Int64 = 0) {
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.reason = reason
        self.sizeBytes = sizeBytes
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

    init(path: String, displayName: String?, reason: String, isUserVisible: Bool) {
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.reason = reason
        self.isUserVisible = isUserVisible
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
}

/// Deletion engine. Runs off the main actor (`@concurrent`) so large removals
/// never block the UI; progress reaches the UI via the `onProgress` buffer.
nonisolated final class FileDeleter: Sendable {
    /// - Parameter pathToDisplayName: Keys should be standardized file paths (`URL.standardizedFileURL.path`).
    /// - Parameter pathToExpectedSizeBytes: Pre-scan sizes from deletion candidates; avoids re-measuring folders at delete time.
    /// - Parameter onProgress: Called on the engine's executor after each item starts / successfully
    ///   deletes. Must be cheap; UI publishing is buffered elsewhere.
    @concurrent func deleteItems(
        at urls: [URL],
        pathToDisplayName: [String: String] = [:],
        pathToExpectedSizeBytes: [String: Int64] = [:],
        onProgress: (@Sendable (DeletionProgressEvent) -> Void)? = nil
    ) async throws -> DeletionReport {
        var bytesMovedToTrash: Int64 = 0
        var bytesRemovedDirectly: Int64 = 0
        var deletedItems: [DeletedItem] = []
        var failedItems: [FailedDeletionItem] = []
        var skippedItems: [SkippedDeletionItem] = []
        let volumeURL = FileManager.default.homeDirectoryForCurrentUser
        let capacityBefore = VolumeCapacityReader.read(for: volumeURL)

        for url in urls {
            let standardizedPath = url.standardizedFileURL.path
            let friendlyTitle = pathToDisplayName[standardizedPath]

            guard DeletionSafetyPolicy.isOfferedForCleanup(url) else { continue }

            let decision = DeletionSafetyPolicy.evaluate(url)
            switch decision {
            case .allow:
                onProgress?(.itemStarted(name: friendlyTitle ?? url.lastPathComponent))
                let size = pathToExpectedSizeBytes[standardizedPath] ?? FolderSizing.directoryByteSize(at: url)

                if DeletionSafetyPolicy.shouldDeleteContentsOnly(url) {
                    var didDeleteAnyContent = false

                    if let contents = try? FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) {
                        for contentURL in contents {
                            guard DeletionSafetyPolicy.isOfferedForCleanup(contentURL) else { continue }
                            do {
                                try FileManager.default.trashItem(at: contentURL, resultingItemURL: nil)
                                didDeleteAnyContent = true
                            } catch {
                                recordDeletionFailure(
                                    path: contentURL.path,
                                    error: error,
                                    displayName: contentURL.lastPathComponent,
                                    sizeBytes: 0,
                                    failedItems: &failedItems
                                )
                            }
                        }
                    }

                    if didDeleteAnyContent {
                        bytesMovedToTrash += size
                        deletedItems.append(DeletedItem(
                            path: url.path,
                            sizeBytes: size,
                            displayName: friendlyTitle
                        ))
                        onProgress?(.itemDeleted(sizeBytes: size))
                    }
                } else if let udid = Self.coreSimulatorDeviceUDID(from: url) {
                    switch Self.deleteCoreSimulatorDevice(udid: udid) {
                    case .success:
                        bytesRemovedDirectly += size
                        deletedItems.append(DeletedItem(
                            path: url.path,
                            sizeBytes: size,
                            displayName: friendlyTitle,
                            movedToTrash: false
                        ))
                        onProgress?(.itemDeleted(sizeBytes: size))
                    case .failure:
                        NSLog("Purge: failed to delete simulator %@ — %@", url.path, udid)
                        failedItems.append(FailedDeletionItem(
                            path: url.path,
                            displayName: friendlyTitle,
                            reason: .unknown,
                            sizeBytes: size
                        ))
                    }
                } else {
                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        bytesMovedToTrash += size
                        deletedItems.append(DeletedItem(path: url.path, sizeBytes: size, displayName: friendlyTitle))
                        onProgress?(.itemDeleted(sizeBytes: size))
                    } catch {
                        recordDeletionFailure(
                            path: url.path,
                            error: error,
                            displayName: friendlyTitle,
                            sizeBytes: size,
                            failedItems: &failedItems
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

        let capacityAfter = VolumeCapacityReader.read(for: volumeURL)
        let report = DeletionReport(
            bytesMovedToTrash: bytesMovedToTrash,
            bytesRemovedDirectly: bytesRemovedDirectly,
            deletedItems: deletedItems,
            failedItems: failedItems,
            skippedItems: skippedItems,
            capacityBefore: capacityBefore,
            capacityAfter: capacityAfter,
            timestamp: Date()
        )
        return report
    }

    /// Dedicated route for the Large & Old Files feature. It only handles
    /// individually selected regular files and always moves them to Trash.
    @concurrent func deleteUserSelectedFiles(
        at urls: [URL],
        pathToDisplayName: [String: String] = [:],
        pathToExpectedSizeBytes: [String: Int64] = [:],
        onProgress: (@Sendable (DeletionProgressEvent) -> Void)? = nil
    ) async throws -> DeletionReport {
        var bytesMovedToTrash: Int64 = 0
        var deletedItems: [DeletedItem] = []
        var failedItems: [FailedDeletionItem] = []
        var skippedItems: [SkippedDeletionItem] = []
        let volumeURL = FileManager.default.homeDirectoryForCurrentUser
        let capacityBefore = VolumeCapacityReader.read(for: volumeURL)

        for url in urls {
            let standardizedPath = url.standardizedFileURL.path
            let friendlyTitle = pathToDisplayName[standardizedPath]

            guard LargeFileScanPolicy.isEligibleForDeletion(url) else {
                skippedItems.append(SkippedDeletionItem(
                    path: url.path,
                    displayName: friendlyTitle,
                    reason: "This file was skipped for safety",
                    isUserVisible: true
                ))
                continue
            }

            onProgress?(.itemStarted(name: friendlyTitle ?? url.lastPathComponent))
            let size = pathToExpectedSizeBytes[standardizedPath] ?? FolderSizing.singleFileSize(at: url)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                bytesMovedToTrash += size
                deletedItems.append(DeletedItem(path: url.path, sizeBytes: size, displayName: friendlyTitle))
                onProgress?(.itemDeleted(sizeBytes: size))
            } catch {
                recordDeletionFailure(
                    path: url.path,
                    error: error,
                    displayName: friendlyTitle,
                    sizeBytes: size,
                    failedItems: &failedItems
                )
            }
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
            timestamp: Date()
        )
        return report
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

    private enum SimctlDeleteResult {
        case success
        case failure(String)
    }

    private static func deleteCoreSimulatorDevice(udid: String) -> SimctlDeleteResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "delete", udid]

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return .failure(error.localizedDescription)
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return .success
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let errText, !errText.isEmpty {
            return .failure(errText)
        }
        return .failure("simctl delete failed (exit \(process.terminationStatus))")
    }

    /// Retries deletion for a single previously failed item.
    func retryDeleteItem(
        at url: URL,
        displayName: String?,
        expectedSizeBytes: Int64
    ) async -> Result<Int64, CleanFailureReason> {
        let report: DeletionReport
        do {
            let key = url.standardizedFileURL.path
            report = try await deleteItems(
                at: [url],
                pathToDisplayName: [key: displayName ?? url.lastPathComponent],
                pathToExpectedSizeBytes: [key: expectedSizeBytes]
            )
        } catch {
            return .failure(.unknown)
        }

        if report.deletedItems.isEmpty {
            if let failed = report.failedItems.first {
                return .failure(failed.reason)
            }
            return .failure(.unknown)
        }
        return .success(report.bytesMovedToTrash + report.bytesRemovedDirectly)
    }

    private func recordDeletionFailure(
        path: String,
        error: Error,
        displayName: String?,
        sizeBytes: Int64,
        failedItems: inout [FailedDeletionItem]
    ) {
        guard let reason = CleanFailureReason.resolved(
            from: error,
            fullDiskAccessGranted: PermissionChecker().hasFullDiskAccess()
        ) else {
            NSLog("Purge: item already gone, skipping %@", path)
            return
        }
        NSLog("Purge: failed to delete %@ — %@", path, error.localizedDescription)
        failedItems.append(FailedDeletionItem(
            path: path,
            displayName: displayName,
            reason: reason,
            sizeBytes: sizeBytes
        ))
    }
}

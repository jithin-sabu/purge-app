import Foundation

struct DeletedItem: Identifiable {
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

struct FailedDeletionItem: Identifiable {
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

struct SkippedDeletionItem: Identifiable, Hashable {
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

struct DeletionReport: Identifiable {
    let id = UUID()
    let totalDeleted: Int64
    let deletedItems: [DeletedItem]
    let failedItems: [FailedDeletionItem]
    let skippedItems: [SkippedDeletionItem]
    let volumeCapacity: Int64
    let availableCapacityBefore: Int64
    let availableCapacityAfter: Int64
    let timestamp: Date

    var actualFreedBytes: Int64 {
        max(0, availableCapacityAfter - availableCapacityBefore)
    }

    var hasUserVisibleSkips: Bool {
        skippedItems.contains { $0.isUserVisible }
    }

    var movedToTrashCount: Int {
        deletedItems.lazy.filter(\.movedToTrash).count
    }

    /// Selected items that did not get cleaned and the user should hear about.
    var userVisibleFailureCount: Int {
        failedItems.count + skippedItems.lazy.filter(\.isUserVisible).count
    }
}

final class FileDeleter {
    private let scanner = CacheScanner()
    private(set) var deletionLog: [DeletionReport] = []

    /// - Parameter pathToDisplayName: Keys should be standardized file paths (`URL.standardizedFileURL.path`).
    /// - Parameter pathToExpectedSizeBytes: Pre-scan sizes from deletion candidates; avoids re-measuring folders at delete time.
    /// - Parameter onProgress: Called on the engine's executor after each item starts / successfully
    ///   deletes. Must be cheap; UI publishing is buffered elsewhere.
    func deleteItems(
        at urls: [URL],
        pathToDisplayName: [String: String] = [:],
        pathToExpectedSizeBytes: [String: Int64] = [:],
        onProgress: (@Sendable (DeletionProgressEvent) -> Void)? = nil
    ) async throws -> DeletionReport {
        var totalDeleted: Int64 = 0
        var deletedItems: [DeletedItem] = []
        var failedItems: [FailedDeletionItem] = []
        var skippedItems: [SkippedDeletionItem] = []
        let volumeURL = FileManager.default.homeDirectoryForCurrentUser
        let capacityBefore = volumeCapacitySnapshot(for: volumeURL)

        for url in urls {
            let standardizedPath = url.standardizedFileURL.path
            let friendlyTitle = pathToDisplayName[standardizedPath]

            guard DeletionSafetyPolicy.isOfferedForCleanup(url) else { continue }

            let decision = DeletionSafetyPolicy.evaluate(url)
            switch decision {
            case .allow:
                onProgress?(.itemStarted(name: friendlyTitle ?? url.lastPathComponent))
                let size = pathToExpectedSizeBytes[standardizedPath] ?? scanner.calculateFolderSize(at: url)

                if DeletionSafetyPolicy.shouldDeleteContentsOnly(url) {
                    var didDeleteAnyContent = false

                    if let contents = try? FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) {
                        for contentURL in contents {
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
                        totalDeleted += size
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
                        totalDeleted += size
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
                        totalDeleted += size
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

        let capacityAfter = volumeCapacitySnapshot(for: volumeURL)
        let report = DeletionReport(
            totalDeleted: totalDeleted,
            deletedItems: deletedItems,
            failedItems: failedItems,
            skippedItems: skippedItems,
            volumeCapacity: capacityAfter.total,
            availableCapacityBefore: capacityBefore.available,
            availableCapacityAfter: capacityAfter.available,
            timestamp: Date()
        )
        deletionLog.append(report)
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
        return .success(report.totalDeleted)
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

    private func volumeCapacitySnapshot(for url: URL) -> (total: Int64, available: Int64) {
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (
            Int64(values?.volumeTotalCapacity ?? 0),
            Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        )
    }
}

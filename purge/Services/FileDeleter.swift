import Foundation

struct DeletedItem: Identifiable {
    let id: UUID
    let path: String
    let sizeBytes: Int64
    /// Friendly label from the main list (e.g. explanation headline); nil if unknown.
    let displayName: String?

    init(path: String, sizeBytes: Int64, displayName: String? = nil) {
        self.id = UUID()
        self.path = path
        self.sizeBytes = sizeBytes
        self.displayName = displayName
    }
}

struct FailedDeletionItem: Identifiable {
    let id = UUID()
    let path: String
    let reason: String
}

struct SkippedDeletionItem: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let reason: String
    /// `true` when the user should see a "skipped for safety" notice.
    /// `false` for silent never-delete blocks.
    let isUserVisible: Bool
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
}

final class FileDeleter {
    private let scanner = CacheScanner()
    private(set) var deletionLog: [DeletionReport] = []

    /// - Parameter pathToDisplayName: Keys should be standardized file paths (`URL.standardizedFileURL.path`).
    /// - Parameter pathToExpectedSizeBytes: Pre-scan sizes from deletion candidates; avoids re-measuring folders at delete time.
    func deleteItems(
        at urls: [URL],
        pathToDisplayName: [String: String] = [:],
        pathToExpectedSizeBytes: [String: Int64] = [:]
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
            let decision = DeletionSafetyPolicy.evaluate(url)
            switch decision {
            case .allow:
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
                                try FileManager.default.removeItem(at: contentURL)
                                didDeleteAnyContent = true
                            } catch {
                                recordDeletionFailure(
                                    path: contentURL.path,
                                    error: error,
                                    failedItems: &failedItems,
                                    skippedItems: &skippedItems
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
                    }
                } else if let udid = Self.coreSimulatorDeviceUDID(from: url) {
                    switch Self.deleteCoreSimulatorDevice(udid: udid) {
                    case .success:
                        totalDeleted += size
                        deletedItems.append(DeletedItem(path: url.path, sizeBytes: size, displayName: friendlyTitle))
                    case .failure(let message):
                        failedItems.append(FailedDeletionItem(path: url.path, reason: message))
                    }
                } else {
                    do {
                        try FileManager.default.removeItem(at: url)
                        totalDeleted += size
                        deletedItems.append(DeletedItem(path: url.path, sizeBytes: size, displayName: friendlyTitle))
                    } catch {
                        recordDeletionFailure(
                            path: url.path,
                            error: error,
                            failedItems: &failedItems,
                            skippedItems: &skippedItems
                        )
                    }
                }

            case .blockedNeverDelete, .blockedNotWhitelisted:
                let reason = decision.skipReason ?? "Skipped for safety"
                skippedItems.append(
                    SkippedDeletionItem(
                        path: url.path,
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

    private func recordDeletionFailure(
        path: String,
        error: Error,
        failedItems: inout [FailedDeletionItem],
        skippedItems: inout [SkippedDeletionItem]
    ) {
        if Self.isPermissionDenied(error) {
            skippedItems.append(
                SkippedDeletionItem(
                    path: path,
                    reason: "Protected by macOS — cannot be removed.",
                    isUserVisible: true
                )
            )
        } else {
            failedItems.append(FailedDeletionItem(path: path, reason: error.localizedDescription))
        }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            return ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError
        }
        if ns.domain == NSPOSIXErrorDomain {
            return ns.code == Int(EACCES) || ns.code == Int(EPERM)
        }
        return false
    }

    private func volumeCapacitySnapshot(for url: URL) -> (total: Int64, available: Int64) {
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (
            Int64(values?.volumeTotalCapacity ?? 0),
            Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        )
    }
}

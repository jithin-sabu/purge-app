import Foundation
import Testing
@testable import Purge

/// Confirms the uninstall gate is actually wired into the delete engine: a
/// leftover under a Library root goes through, while a path no policy vouches for
/// is skipped for safety even when handed to the same call.
@Suite("FileDeleter honours the uninstall eligibility gate")
struct FileDeleterUninstallEligibilityTests {
    @MainActor
    @Test func uninstallLeftoverIsDeletedAndRandomPathIsSkipped() async throws {
        let fm = FileManager.default
        let token = UUID().uuidString.prefix(8)

        // Eligible: a preferences-style leftover under ~/Library/Preferences.
        let prefs = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        try #require(fm.fileExists(atPath: prefs.path))
        let leftover = prefs.appendingPathComponent("com.purgetest.\(token).plist")
        try Data(repeating: 0x00, count: 512).write(to: leftover)
        defer { try? fm.removeItem(at: leftover) }

        // Ineligible: a path in the temp dir, which no scan policy covers.
        let stray = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("purgetest-stray-\(token).bin")
        try Data(repeating: 0x00, count: 512).write(to: stray)
        defer { try? fm.removeItem(at: stray) }

        let report = try await FileDeleter().deleteUserSelectedFiles(
            at: [leftover, stray],
            pathToDisplayName: [
                leftover.standardizedFileURL.path: "PurgeTest",
                stray.standardizedFileURL.path: "PurgeTest stray"
            ]
        )

        let deletedPaths = Set(report.deletedItems.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let skippedPaths = Set(report.skippedItems.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })

        #expect(deletedPaths.contains(leftover.standardizedFileURL.path))
        #expect(!fm.fileExists(atPath: leftover.path))

        #expect(skippedPaths.contains(stray.standardizedFileURL.path))
        #expect(fm.fileExists(atPath: stray.path))
    }
}

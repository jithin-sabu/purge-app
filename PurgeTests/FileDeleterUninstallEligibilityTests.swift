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
        let base = fm.temporaryDirectory.appendingPathComponent("purgetest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        // Eligible: a preferences-style leftover under the home's Library/Preferences.
        // The home is a temporary one, so nothing goes near the user's Library (#171).
        let home = base.appendingPathComponent("home", isDirectory: true)
        let prefs = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        try fm.createDirectory(at: prefs, withIntermediateDirectories: true)
        let leftover = prefs.appendingPathComponent("com.purgetest.leftover.plist")
        try Data(repeating: 0x00, count: 512).write(to: leftover)

        // Ineligible: a path beside that home, which no scan policy covers.
        let stray = base.appendingPathComponent("purgetest-stray.bin")
        try Data(repeating: 0x00, count: 512).write(to: stray)

        let trash = FakeTrash()
        let report = try await FileDeleter(home: home, trash: trash.trash).deleteUserSelectedFiles(
            at: [leftover, stray],
            pathToDisplayName: [
                leftover.standardizedFileURL.path: "PurgeTest",
                stray.standardizedFileURL.path: "PurgeTest stray"
            ]
        )

        let deletedPaths = Set(report.deletedItems.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let skippedPaths = Set(report.skippedItems.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })

        #expect(deletedPaths.contains(leftover.standardizedFileURL.path))
        #expect(skippedPaths.contains(stray.standardizedFileURL.path))
        #expect(trash.trashedPaths == [leftover.standardizedFileURL.path])
    }

    /// A catalog dot folder goes through; its shared parent and a sibling the
    /// catalog does not name are skipped for safety (#224).
    @MainActor
    @Test func catalogDotFolderIsDeletedAndItsParentIsSkipped() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("purgetest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
        let antigravity = gemini.appendingPathComponent("antigravity", isDirectory: true)
        let other = home.appendingPathComponent(".other-tool", isDirectory: true)
        try fm.createDirectory(at: antigravity, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(repeating: 0x00, count: 64).write(to: antigravity.appendingPathComponent("state"))
        try Data(repeating: 0x00, count: 64).write(to: gemini.appendingPathComponent("settings.json"))

        let trash = FakeTrash()
        let report = try await FileDeleter(home: home, trash: trash.trash).deleteUserSelectedFiles(
            at: [antigravity, gemini, other]
        )

        #expect(trash.trashedPaths == [antigravity.standardizedFileURL.path])
        #expect(Set(report.skippedItems.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
            == [gemini.standardizedFileURL.path, other.standardizedFileURL.path])
    }

    /// The app builds its deleter with no `home`, so the gate checks the real home.
    /// A Library somewhere else is not a leftover root, and nothing is trashed.
    @MainActor
    @Test func defaultHomeRefusesALeftoverInAnotherHome() async throws {
        let fm = FileManager.default
        let otherHome = fm.temporaryDirectory.appendingPathComponent("purgetest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: otherHome) }
        let prefs = otherHome.appendingPathComponent("Library/Preferences", isDirectory: true)
        try fm.createDirectory(at: prefs, withIntermediateDirectories: true)
        let leftover = prefs.appendingPathComponent("com.purgetest.leftover.plist")
        try Data(repeating: 0x00, count: 512).write(to: leftover)

        let trash = FakeTrash()
        let report = try await FileDeleter(trash: trash.trash).deleteUserSelectedFiles(at: [leftover])

        #expect(report.deletedItems.isEmpty)
        #expect(report.skippedItems.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
            == [leftover.standardizedFileURL.path])
        #expect(trash.trashedPaths.isEmpty)
    }
}

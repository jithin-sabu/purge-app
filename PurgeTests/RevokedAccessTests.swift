import Foundation
import Testing
@testable import Purge

@MainActor
@Suite("Turning Full Disk Access off drops what it had unlocked")
struct RevokedAccessTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// Rows from a full scan must not outlive the access that found them: they
    /// would sit next to the "Limited scan" notice, count toward the Clean button,
    /// and then be skipped by the clean.
    @Test
    func revokingAccessDropsRowsInLockedPlaces() {
        // Pruning persists the new total when a scan has completed before. Put the
        // real value back so the test leaves this Mac's defaults as it found them.
        let totalKey = "lastScanSafeRecoverableBytes"
        let savedTotal = UserDefaults.standard.object(forKey: totalKey)
        defer {
            if let savedTotal {
                UserDefaults.standard.set(savedTotal, forKey: totalKey)
            } else {
                UserDefaults.standard.removeObject(forKey: totalKey)
            }
        }

        // Paths that do not exist: the check reads links only, and stops at the
        // Documents root without touching it.
        let unique = "purge-test-\(UUID().uuidString)"
        let locked = artifact(at: home.appendingPathComponent("Documents/\(unique)/node_modules"))
        let open = artifact(at: home.appendingPathComponent("\(unique)/node_modules"))

        let store = PurgeStore()
        store.hasFullDiskAccess = true
        store.projectGroups = [group(for: locked), group(for: open)]
        store.scanSelection.artifactIDs = [locked.id, open.id]

        store.hasFullDiskAccess = false

        #expect(store.projectGroups.flatMap(\.artifacts).map(\.path) == [open.path])
        #expect(store.scanSelection.artifactIDs == [open.id])
        #expect(store.manualSafeCleanupCandidates().map(\.path) == [open.path])
    }

    /// A row that reached the store while access was already off. Its path looks
    /// fine and its project folder links into Documents, so a path-only check
    /// would count it on the Clean button and the clean would then skip it.
    @Test
    func cleanButtonSkipsARowLinkedIntoALockedPlace() throws {
        let unique = "purge-test-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(unique, isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // The target does not exist: the check reads the link and stops at Documents.
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("client").path,
            withDestinationPath: home.appendingPathComponent("Documents/\(unique)").path
        )
        let linked = artifact(at: folder.appendingPathComponent("client/node_modules"))
        let open = artifact(at: folder.appendingPathComponent("other/node_modules"))

        let store = PurgeStore()
        store.hasFullDiskAccess = false
        store.projectGroups = [group(for: linked), group(for: open)]

        #expect(store.manualSafeCleanupCandidates().map(\.path) == [open.path])
    }

    private func artifact(at path: URL) -> ProjectCacheArtifact {
        ProjectCacheArtifact(
            kind: .nodeModules,
            path: path,
            projectRoot: path.deletingLastPathComponent(),
            sizeBytes: 1024,
            lastModified: .distantPast,
            isSelected: false,
            safetyInfo: SafetyInfo(level: .safe, headline: "node_modules", explanation: "", recoverySteps: "", reinstallCommand: nil),
            reinstallSafety: .notApplicable,
            gitStatus: .clean
        )
    }

    private func group(for artifact: ProjectCacheArtifact) -> ProjectGroup {
        ProjectGroup(
            displayName: artifact.projectRoot.lastPathComponent,
            rootPath: artifact.projectRoot,
            inferredTypes: [.node],
            artifacts: [artifact]
        )
    }
}

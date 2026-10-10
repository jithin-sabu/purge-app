import Foundation
import Testing
@testable import Purge

@Suite("Large Files labels files that sync with iCloud (#25)")
struct LargeFileICloudSyncTests {
    @Test
    func warningCopyFollowsTheSyncedCount() {
        #expect(LargeFile.iCloudDeletionWarning(syncedCount: 0, totalCount: 4) == nil)
        #expect(
            LargeFile.iCloudDeletionWarning(syncedCount: 1, totalCount: 1)
                == "The file you're trashing syncs with iCloud, so it also disappears from your other devices. You can restore it from the Trash."
        )
        #expect(
            LargeFile.iCloudDeletionWarning(syncedCount: 3, totalCount: 3)
                == "All 3 files you're trashing sync with iCloud, so they also disappear from your other devices. You can restore them from the Trash."
        )
        #expect(
            LargeFile.iCloudDeletionWarning(syncedCount: 1, totalCount: 4)
                == "1 of the files you're trashing syncs with iCloud, so it also disappears from your other devices. You can restore it from the Trash."
        )
        #expect(
            LargeFile.iCloudDeletionWarning(syncedCount: 3, totalCount: 5)
                == "3 of the files you're trashing sync with iCloud, so they also disappear from your other devices. You can restore them from the Trash."
        )
    }

    /// AI-model rows and existing fixtures never pass the flag, so they stay unbadged.
    @Test
    func fileBuiltWithoutTheFlagDoesNotSync() {
        let file = LargeFile(
            path: URL(fileURLWithPath: "/Users/someone/Movies/clip.mov"),
            sizeBytes: 1024,
            lastUsed: Date(),
            category: .video
        )
        #expect(file.syncsWithICloud == false)
    }

    /// A dataless placeholder has a large logical size and zero bytes allocated.
    /// The same scan must keep the dense neighbour and drop the placeholder, so a
    /// later switch to logical size cannot fill the list with files that aren't here.
    @Test
    func scanKeepsTheDenseFileAndDropsTheDatalessPlaceholder() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "purge-icloud-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let denseName = "dense.bin"
        try Data(repeating: 0x01, count: 4096).write(to: root.appendingPathComponent(denseName))

        let placeholder = root.appendingPathComponent("placeholder.bin")
        fm.createFile(atPath: placeholder.path, contents: nil)
        let handle = try FileHandle(forWritingTo: placeholder)
        try handle.truncate(atOffset: 8 * 1024 * 1024)
        try handle.close()

        let values = try placeholder.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        #expect(values.totalFileAllocatedSize == 0)
        #expect((values.fileSize ?? 0) > 1024)

        let stream = LargeFileScanner().scanStream(
            minBytes: 1024,
            staleDays: 0,
            roots: [root],
            exclusions: ScanExclusions(keys: []),
            isExcluded: { _ in false }
        )

        var yielded: [LargeFile] = []
        for await file in stream {
            yielded.append(file)
        }

        #expect(yielded.count == 1)
        let file = try #require(yielded.first)
        let marker = root.lastPathComponent + "/"
        let range = try #require(file.path.path.range(of: marker))
        #expect(String(file.path.path[range.upperBound...]) == denseName)
        #expect(file.syncsWithICloud == false)
    }
}

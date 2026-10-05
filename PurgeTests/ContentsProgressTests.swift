import Foundation
import Testing
@testable import Purge

/// A folder emptied one entry at a time reports each entry's own size as it moves,
/// so the progress screen keeps moving and the total only counts what moved (#59).
@Suite("Contents progress")
struct ContentsProgressTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentsProgressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Files report their allocated size and folders their du size")
    func entrySizesMatchTheScannersMeasure() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("clip.mp4")
        try Data(count: 10_000).write(to: file)

        let folder = root.appendingPathComponent("thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data(count: 50_000).write(to: folder.appendingPathComponent("t\(index)"))
        }

        let link = root.appendingPathComponent("latest")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

        let sizes = FileDeleter.contentsEntrySizes([file, folder, link])

        let fileAllocated = try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
        #expect(sizes[file] == Int64(fileAllocated ?? -1))
        #expect(sizes[folder] == FolderSizing.directoryByteSize(at: folder))
        #expect((sizes[folder] ?? 0) >= 150_000)
        // A link moves as a link. Counting its target would claim the folder twice.
        #expect((sizes[link] ?? .max) < 50_000)
    }

    @Test("An entry that vanished before sizing counts as nothing")
    func missingEntriesCountAsZero() {
        let gone = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentsProgressTests-missing-\(UUID().uuidString)")
        #expect(FileDeleter.contentsEntrySizes([gone])[gone] == 0)
    }

    @MainActor
    @Test("Partial events move the byte total without counting an item")
    func bufferCountsPartialBytesButNotItems() {
        let buffer = DeletionProgressBuffer()
        buffer.ingest(.itemStarted(name: "Telegram Media Cache"))
        buffer.ingest(.itemPartlyDeleted(sizeBytes: 300))
        buffer.ingest(.itemPartlyDeleted(sizeBytes: 700))
        var snapshot = buffer.snapshot()
        #expect(snapshot.bytesMovedToTrash == 1_000)
        #expect(snapshot.itemsCompleted == 0)

        buffer.ingest(.itemDeleted(sizeBytes: 0))
        snapshot = buffer.snapshot()
        #expect(snapshot.bytesMovedToTrash == 1_000)
        #expect(snapshot.itemsCompleted == 1)
    }
}

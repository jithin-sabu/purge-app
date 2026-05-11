import Foundation

/// Shared folder sizing so scans can call this from background tasks without hopping through `MainActor`.
enum FolderSizing {
    nonisolated static func directoryByteSize(at url: URL) -> Int64 {
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles],
            errorHandler: { _, _ in true }
        )

        var total: Int64 = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            do {
                let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values.isDirectory == true { continue }
                total += Int64(values.fileSize ?? 0)
            } catch {
                continue
            }
        }
        return total
    }

    nonisolated static func contentModificationDate(at url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

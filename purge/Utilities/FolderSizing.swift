import Foundation

/// Shared folder sizing so scans can call this from background tasks without hopping through `MainActor`.
enum FolderSizing {
    nonisolated static func directoryByteSize(at url: URL) -> Int64 {
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isRegularFileKey
            ],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        var visitedInodes = Set<UInt64>()

        while let fileURL = enumerator.nextObject() as? URL {
            if Task.isCancelled { return 0 }
            do {
                let values = try fileURL.resourceValues(forKeys: [
                    .fileSizeKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .isRegularFileKey,
                    .fileResourceIdentifierKey
                ])

                guard values.isDirectory != true else { continue }
                guard values.isSymbolicLink != true else { continue }
                guard values.isRegularFile == true else { continue }

                if let identifier = values.fileResourceIdentifier as? NSObject {
                    let hash = UInt64(bitPattern: Int64(identifier.hash))
                    if visitedInodes.contains(hash) { continue }
                    visitedInodes.insert(hash)
                }

                total += Int64(values.fileSize ?? 0)
            } catch {
                continue
            }
        }
        return total
    }

    nonisolated static func singleFileSize(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return 0 }
        return Int64(size)
    }

    nonisolated static func contentModificationDate(at url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

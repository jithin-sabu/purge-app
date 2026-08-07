import AppKit
import Foundation

/// One filesystem location a scan row can reveal. `sizeBytes` is shown in the
/// "Show in Finder" submenu so a multi-location row says which folder holds the bulk.
nonisolated struct ScanRowLocation: Hashable {
    let url: URL
    let sizeBytes: Int64?

    init(url: URL, sizeBytes: Int64? = nil) {
        self.url = url
        self.sizeBytes = sizeBytes
    }
}

@MainActor
enum FinderReveal {
    /// Reveals exactly one folder.
    ///
    /// Deliberately never called with several URLs at once: `activateFileViewerSelecting`
    /// groups its argument by parent directory and opens one Finder window *per distinct
    /// parent*. Cache locations for a single app almost always sit under different parents
    /// (`~/Library/Caches`, `~/Library/Application Support`, `~/Library/Containers`), so
    /// passing them together fans out a burst of windows. Multi-location rows offer a
    /// submenu instead and reveal the one the user picked.
    static func show(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url.standardizedFileURL])
    }

    static func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let text = urls
            .map { $0.standardizedFileURL.path }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Submenu label: abbreviated path, plus size when known.
    static func menuTitle(for location: ScanRowLocation) -> String {
        let path = displayDirectoryPath(for: location.url)
        guard let sizeBytes = location.sizeBytes, sizeBytes > 0 else { return path }
        return "\(path) — \(formatBytes(sizeBytes))"
    }
}

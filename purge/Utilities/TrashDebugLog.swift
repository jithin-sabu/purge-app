import Foundation

/// Append-only diagnostic log for the trash-measurement pipeline, written to
/// `~/Library/Application Support/io.getpurge.app/trash-debug.log`.
///
/// Temporary instrumentation for chasing the "In Trash resets to zero after a clean"
/// report: every watcher event, size pass, resolution, and published value lands here
/// with timestamps, so a single reproduction pins which path published the zero.
/// Remove once the bug is understood.
///
/// It lives in Purge's own Application Support folder — NOT `~/Library/Logs` — because
/// `~/Library/Logs` is one of Purge's cleaning targets, and the first reproduction run
/// cleaned the diagnostic log into the trash along with everything else. The directory
/// is re-ensured on every write for the same reason.
nonisolated enum TrashDebugLog {
    private static let queue = DispatchQueue(label: "purge.trash-debug-log", qos: .utility)

    /// Formatting is confined to the serial queue; `DateFormatter` is not thread-safe.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let directoryURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("io.getpurge.app", isDirectory: true)

    static let fileURL: URL = directoryURL.appendingPathComponent("trash-debug.log")

    static func log(_ message: String) {
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}

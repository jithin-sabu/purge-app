import Foundation

func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 bytes" }

    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .file
    formatter.includesUnit = true

    return formatter.string(fromByteCount: bytes)
}

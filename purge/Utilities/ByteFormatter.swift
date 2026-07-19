import Foundation

func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 bytes" }

    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .file
    formatter.includesUnit = true

    return formatter.string(fromByteCount: bytes)
}

/// Formats volume figures for the storage sidebar — one decimal at most (e.g. "313.4 GB").
func formatStorageBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 bytes" }

    let units: [(threshold: Int64, suffix: String)] = [
        (1_000_000_000_000, "TB"),
        (1_000_000_000, "GB"),
        (1_000_000, "MB"),
        (1_000, "KB")
    ]

    for unit in units where bytes >= unit.threshold {
        let tenths = (bytes * 10 + unit.threshold / 2) / unit.threshold
        let whole = tenths / 10
        let fraction = tenths % 10
        guard fraction > 0 else { return "\(whole) \(unit.suffix)" }
        return "\(whole).\(fraction) \(unit.suffix)"
    }

    return "\(bytes) bytes"
}

/// Formats a ceiling, rounding **down** so the figure can never overstate.
///
/// `formatBytes` rounds to nearest, which would turn 1.29 GB into "1.3 GB" and quietly
/// promise more than exists. An "up to" figure has to under-promise by construction: the
/// measured outcome must always be able to meet or beat it.
func formatBytesRoundedDown(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 bytes" }

    let units: [(threshold: Int64, suffix: String)] = [
        (1_000_000_000_000, "TB"),
        (1_000_000_000, "GB"),
        (1_000_000, "MB"),
        (1_000, "KB")
    ]

    for unit in units where bytes >= unit.threshold {
        // Truncate at one decimal place rather than rounding it.
        let tenths = (bytes * 10) / unit.threshold
        let whole = tenths / 10
        let fraction = tenths % 10
        guard fraction > 0 else { return "\(whole) \(unit.suffix)" }
        return "\(whole).\(fraction) \(unit.suffix)"
    }

    return "\(bytes) bytes"
}

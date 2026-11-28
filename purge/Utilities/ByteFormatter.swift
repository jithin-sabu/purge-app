import Foundation

/// Made once: `formatBytes` runs per row per render. Foundation's formatters are
/// safe to share across threads once configured.
nonisolated(unsafe) private let byteCountFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    return formatter
}()

nonisolated func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return String(localized: "0 bytes") }
    return byteCountFormatter.string(fromByteCount: bytes)
}

/// Writes a figure with zero or one fraction digit and no grouping, in the locale's own
/// digits and decimal separator. A `NumberFormatter`, not a `FormatStyle`: only the
/// formatter follows a separator the user picked in System Settings, the way
/// `formatBytes` does (#460).
nonisolated private func makeOneDecimalFormatter(_ locale: Locale) -> NumberFormatter {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 1
    formatter.usesGroupingSeparator = false
    return formatter
}

/// Made once, like `byteCountFormatter`: storage figures run per row per render.
nonisolated(unsafe) private let oneDecimalFormatter = makeOneDecimalFormatter(.autoupdatingCurrent)

/// Formats volume figures for the storage sidebar — one decimal at most (e.g. "313.4 GB").
func formatStorageBytes(_ bytes: Int64) -> String {
    formatOneDecimal(bytes, roundingDown: false)
}

/// Formats a ceiling, rounding **down** so the figure can never overstate.
///
/// `formatBytes` rounds to nearest, which would turn 1.29 GB into "1.3 GB" and quietly
/// promise more than exists. An "up to" figure has to under-promise by construction: the
/// measured outcome must always be able to meet or beat it.
nonisolated func formatBytesRoundedDown(_ bytes: Int64) -> String {
    formatOneDecimal(bytes, roundingDown: true)
}

/// Decimal units with one decimal at most, rounded to nearest or truncated.
/// `locale` is injected so the tests can check other regions and digit settings
/// without touching the process-wide locale; `nil` means the user's own.
nonisolated func formatOneDecimal(
    _ bytes: Int64,
    roundingDown: Bool,
    locale: Locale? = nil
) -> String {
    guard bytes > 0 else { return String(localized: "0 bytes") }

    // Units come from the string tables, so a Mac set to Russian reads "217,5 ГБ"
    // and not "217.5 GB", the way `formatBytes` already writes its own figures.
    let units: [(threshold: Int64, suffix: String)] = [
        (1_000_000_000_000, String(localized: "TB")),
        (1_000_000_000, String(localized: "GB")),
        (1_000_000, String(localized: "MB")),
        (1_000, String(localized: "KB"))
    ]

    for unit in units where bytes >= unit.threshold {
        // The rounding is done here in whole tenths, so the formatter below never
        // rounds again and a ceiling stays rounded down.
        let tenths = (bytes * 10 + (roundingDown ? 0 : unit.threshold / 2)) / unit.threshold
        let value = NSDecimalNumber(mantissa: UInt64(tenths), exponent: -1, isNegative: false)
        // The locale writes the digits and the separator, so an Arabic or Persian Mac
        // gets its own digits here, the same as `formatBytes` and the counts (#460).
        let formatter = locale.map(makeOneDecimalFormatter) ?? oneDecimalFormatter
        let figure = formatter.string(from: value) ?? "\(value)"
        return "\(figure) \(unit.suffix)"
    }

    return String(localized: "\(bytes) bytes")
}

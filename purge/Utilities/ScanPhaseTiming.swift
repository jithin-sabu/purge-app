import Foundation

/// Scan timing for profiling, printed as lines prefixed with `PURGE-TIMING:` in debug
/// builds. Release builds compile it out, messages included.
nonisolated enum ScanPhaseTiming {
    /// Messages are only built in a debug build (#190).
    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("PURGE-TIMING: \(message())")
        #endif
    }

    static func elapsed(since start: Date) -> String {
        String(format: "%.3f", Date().timeIntervalSince(start))
    }

    static func finish(_ label: String, since start: Date, detail: @autoclosure () -> String? = nil) {
        #if DEBUG
        let suffix = detail().map { " — \($0)" } ?? ""
        log("\(label): \(elapsed(since: start))s\(suffix)")
        #endif
    }
}

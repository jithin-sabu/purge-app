import Foundation

/// Temporary scan instrumentation — logs lines prefixed with `PURGE-TIMING:` for profiling.
enum ScanPhaseTiming {
    static func log(_ message: String) {
        #if DEBUG
        print("PURGE-TIMING: \(message)")
        #endif
    }

    static func elapsed(since start: Date) -> String {
        String(format: "%.3f", Date().timeIntervalSince(start))
    }

    static func finish(_ label: String, since start: Date, detail: String? = nil) {
        let suffix = detail.map { " — \($0)" } ?? ""
        log("\(label): \(elapsed(since: start))s\(suffix)")
    }
}

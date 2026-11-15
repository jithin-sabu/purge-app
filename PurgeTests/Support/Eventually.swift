import Foundation

/// Waits until `condition` holds, or `timeout` seconds of waiting pass. Returns
/// whether it held.
///
/// The deadline only stops a hang: other suites fill the cooperative thread
/// pool on purpose for several seconds at a time, and a 5-second wait ran out
/// on a 3-core CI runner. It counts only the time this loop was running: on CI
/// the test host can stall for tens of seconds with every suite waiting, and a
/// wall-clock deadline expires during the stall through no fault of the
/// condition.
@MainActor
func eventually(timeout: TimeInterval = 30, _ condition: () -> Bool) async -> Bool {
    var waited: TimeInterval = 0
    var last = Date()
    while !condition() {
        guard waited < timeout else { return false }
        try? await Task.sleep(for: .milliseconds(10))
        let now = Date()
        waited += min(now.timeIntervalSince(last), 0.25)
        last = now
    }
    return true
}

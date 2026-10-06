import Combine
import Foundation

/// The local Time Machine snapshots the Overview shows, read again whenever the page
/// appears or Purge comes back to the front: macOS takes and drops them on its own.
@MainActor
final class LocalSnapshotStore: ObservableObject {
    /// Nil until the first reading lands, or when `tmutil` never answered.
    @Published private(set) var snapshots: LocalSnapshots?

    /// Guards against a slow reading overwriting a newer one.
    private var latestPass = 0

    func refresh() async {
        latestPass += 1
        let pass = latestPass
        let reading = await LocalSnapshotReader.read()
        guard pass == latestPass else { return }
        // A failed reading keeps the last good one rather than hiding the row.
        if let reading {
            snapshots = reading
        }
    }
}

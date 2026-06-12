import Combine
import Foundation

/// Per-item progress emitted by `FileDeleter` while a deletion run executes off the main actor.
enum DeletionProgressEvent: Sendable {
    case itemStarted(name: String)
    case itemDeleted(sizeBytes: Int64)
}

/// Lock-protected accumulator between the deletion engine and the UI.
/// The engine writes per item; a main-actor poller reads a snapshot every
/// ~120ms so `@Published` state is never updated per item.
final class DeletionProgressBuffer: @unchecked Sendable {
    struct Snapshot: Equatable {
        var bytesFreed: Int64 = 0
        var itemsCompleted: Int = 0
        var currentItemName: String?
    }

    private let lock = NSLock()
    private var current = Snapshot()

    func ingest(_ event: DeletionProgressEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .itemStarted(let name):
            current.currentItemName = name
        case .itemDeleted(let sizeBytes):
            current.bytesFreed += sizeBytes
            current.itemsCompleted += 1
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

/// Drives `SafeCleanupCelebrationOverlay` through its cleaning and complete phases.
///
/// A live run starts in `.cleaning` when the user confirms deletion and flips to
/// `.complete` when the engine finishes — no navigation happens at completion.
/// Flows with their own progress choreography (safe cleanup, onboarding) create
/// an already-`.complete` session via `completed(...)`.
@MainActor
final class DeletionSession: ObservableObject, Identifiable {
    enum Phase {
        case cleaning
        case complete
    }

    let totalBytes: Int64
    let totalItems: Int
    /// `true` when the session was created in `.cleaning` to track a live engine run.
    let isLiveRun: Bool
    /// Wall-clock anchor when the user started the cleanup (tap/confirm).
    let startedAt: Date?

    @Published private(set) var phase: Phase
    @Published private(set) var bytesFreed: Int64 = 0
    @Published private(set) var itemsCompleted: Int = 0
    @Published private(set) var currentItemName: String?

    /// Final engine results — valid once `phase == .complete`. The displayed
    /// total is exactly `finalBytesFreed`; nothing is recomputed in the view.
    private(set) var finalBytesFreed: Int64 = 0
    private(set) var elapsedSeconds: Double = 0
    private(set) var failedCount: Int = 0
    private(set) var movedToTrashCount: Int = 0

    init(totalBytes: Int64, totalItems: Int, startedAt: Date = Date()) {
        self.totalBytes = totalBytes
        self.totalItems = totalItems
        self.isLiveRun = true
        self.startedAt = startedAt
        self.phase = .cleaning
    }

    private init(freedBytes: Int64, startedAt: Date?) {
        self.totalBytes = freedBytes
        self.totalItems = 0
        self.isLiveRun = false
        self.startedAt = startedAt
        self.phase = .complete
    }

    static func completed(
        freedBytes: Int64,
        elapsedSeconds: Double,
        movedToTrashCount: Int,
        failedCount: Int,
        startedAt: Date? = nil
    ) -> DeletionSession {
        let session = DeletionSession(freedBytes: freedBytes, startedAt: startedAt)
        session.finalBytesFreed = freedBytes
        session.elapsedSeconds = elapsedSeconds
        session.movedToTrashCount = movedToTrashCount
        session.failedCount = failedCount
        return session
    }

    func applyProgress(_ snapshot: DeletionProgressBuffer.Snapshot) {
        guard phase == .cleaning else { return }
        if bytesFreed != snapshot.bytesFreed { bytesFreed = snapshot.bytesFreed }
        if itemsCompleted != snapshot.itemsCompleted { itemsCompleted = snapshot.itemsCompleted }
        if currentItemName != snapshot.currentItemName { currentItemName = snapshot.currentItemName }
    }

    func completeRun(
        bytesFreed finalBytes: Int64,
        elapsedSeconds engineElapsed: Double,
        failedCount: Int,
        movedToTrashCount: Int
    ) {
        guard phase == .cleaning else { return }
        finalBytesFreed = finalBytes
        if let startedAt {
            elapsedSeconds = Date().timeIntervalSince(startedAt)
        } else {
            elapsedSeconds = engineElapsed
        }
        self.failedCount = failedCount
        self.movedToTrashCount = movedToTrashCount
        phase = .complete
    }
}

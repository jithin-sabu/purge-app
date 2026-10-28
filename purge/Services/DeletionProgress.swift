import Combine
import Foundation

/// Per-item progress emitted by `FileDeleter` while a deletion run executes off the main actor.
enum DeletionProgressEvent: Sendable {
    case itemStarted(name: String)
    /// One entry of the current item moved, with that entry's own size. Folders
    /// emptied one entry at a time send these so the total keeps moving instead of
    /// waiting for the last file.
    case itemPartlyDeleted(sizeBytes: Int64)
    /// The item finished. `sizeBytes` is whatever its partial events did not
    /// already report: the whole size for a single move, 0 for an emptied folder.
    case itemDeleted(sizeBytes: Int64)
}

/// Lock-protected accumulator between the deletion engine and the UI.
/// The engine writes per item; a main-actor poller reads a snapshot every
/// ~120ms so `@Published` state is never updated per item.
final class DeletionProgressBuffer: @unchecked Sendable {
    struct Snapshot: Equatable {
        /// Running sum of sizes moved to the trash, not space reclaimed.
        var bytesMovedToTrash: Int64 = 0
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
        case .itemPartlyDeleted(let sizeBytes):
            current.bytesMovedToTrash += sizeBytes
        case .itemDeleted(let sizeBytes):
            current.bytesMovedToTrash += sizeBytes
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
    @Published private(set) var bytesMovedToTrash: Int64 = 0
    @Published private(set) var itemsCompleted: Int = 0
    @Published private(set) var currentItemName: String?

    /// Final engine results — valid once `phase == .complete`. The displayed
    /// total is exactly `finalBytesMovedToTrash`; nothing is recomputed in the view.
    /// This is what was moved to the trash, never a claim about reclaimed space.
    private(set) var finalBytesMovedToTrash: Int64 = 0
    private(set) var elapsedSeconds: Double = 0
    private(set) var failedCount: Int = 0
    private(set) var movedToTrashCount: Int = 0
    /// Items that went outright rather than to the Trash: simulators, runtimes
    /// and cask apps Homebrew removed. Their bytes are inside
    /// `finalBytesMovedToTrash`, which is the one figure the screen shows; this
    /// count is what lets the screen say "deleted permanently" about them (#162).
    private(set) var removedPermanentlyCount: Int = 0
    @Published private(set) var failedItems: [CleanFailureItem] = []
    /// `true` when at least one item was moved to the Trash by the privileged helper
    /// but could not be fully handed back to the user, so emptying the Trash may ask
    /// for a password. Drives one honest line on the completion screen; `false` for
    /// every ordinary removal.
    @Published private(set) var trashOwnershipWarning = false

    /// Raises the Trash-ownership note. Safe to call more than once.
    func noteTrashOwnershipWarning() { trashOwnershipWarning = true }

    /// Plain lines the completion screen shows under the total: what Homebrew
    /// said when it could not remove a cask app and Purge trashed it instead
    /// (#254), and a simulator runtime download macOS kept (#165). Empty for
    /// every ordinary run.
    @Published private(set) var notes: [String] = []

    func addNote(_ note: String) { notes.append(note) }

    init(totalBytes: Int64, totalItems: Int, startedAt: Date = Date()) {
        self.totalBytes = totalBytes
        self.totalItems = totalItems
        self.isLiveRun = true
        self.startedAt = startedAt
        self.phase = .cleaning
    }

    private init(movedBytes: Int64, startedAt: Date?) {
        self.totalBytes = movedBytes
        self.totalItems = 0
        self.isLiveRun = false
        self.startedAt = startedAt
        self.phase = .complete
    }

    static func completed(
        bytesMovedToTrash: Int64,
        elapsedSeconds: Double,
        movedToTrashCount: Int,
        removedPermanentlyCount: Int = 0,
        failedItems: [CleanFailureItem],
        startedAt: Date? = nil
    ) -> DeletionSession {
        let session = DeletionSession(movedBytes: bytesMovedToTrash, startedAt: startedAt)
        session.finalBytesMovedToTrash = bytesMovedToTrash
        session.elapsedSeconds = elapsedSeconds
        session.movedToTrashCount = movedToTrashCount
        session.removedPermanentlyCount = removedPermanentlyCount
        session.failedItems = failedItems
        session.failedCount = failedItems.count
        return session
    }

    func applyProgress(_ snapshot: DeletionProgressBuffer.Snapshot) {
        guard phase == .cleaning else { return }
        if bytesMovedToTrash != snapshot.bytesMovedToTrash { bytesMovedToTrash = snapshot.bytesMovedToTrash }
        if itemsCompleted != snapshot.itemsCompleted { itemsCompleted = snapshot.itemsCompleted }
        if currentItemName != snapshot.currentItemName { currentItemName = snapshot.currentItemName }
    }

    func completeRun(
        bytesMovedToTrash finalBytes: Int64,
        elapsedSeconds engineElapsed: Double,
        failedItems: [CleanFailureItem],
        movedToTrashCount: Int,
        removedPermanentlyCount: Int = 0
    ) {
        guard phase == .cleaning else { return }
        finalBytesMovedToTrash = finalBytes
        if let startedAt {
            elapsedSeconds = Date().timeIntervalSince(startedAt)
        } else {
            elapsedSeconds = engineElapsed
        }
        self.failedItems = failedItems
        self.failedCount = failedItems.count
        self.movedToTrashCount = movedToTrashCount
        self.removedPermanentlyCount = removedPermanentlyCount
        phase = .complete
    }

    /// Everything the run and its retries removed, to the Trash or outright.
    var removedCount: Int { movedToTrashCount + removedPermanentlyCount }

    /// What the run set out to remove: what went plus what is still listed. A
    /// retry moves a row from one side to the other, so the sum holds.
    var attemptedCount: Int { removedCount + failedItems.count }

    /// Which screen this run gets (#162). Only meaningful once `phase == .complete`.
    var outcome: CleanOutcome {
        CleanOutcome.resolve(removedCount: removedCount, failedItems: failedItems)
    }

    /// The line under the figure. Trash moves keep the wording that reminds the
    /// user nothing is reclaimed yet; items removed outright are gone, and the
    /// screen must say so (#136, #162). A mixed run names both by count.
    var removalWording: String {
        if removedPermanentlyCount == 0 {
            return String(localized: "moved to trash, not yet reclaimed")
        }
        if movedToTrashCount == 0 {
            return String(localized: "deleted permanently")
        }
        return String(localized: "\(movedToTrashCount) moved to trash, \(removedPermanentlyCount) deleted permanently")
    }

    func removeResolvedFailure(id: UUID, additionalMovedBytes: Int64) {
        failedItems.removeAll { $0.id == id }
        failedCount = failedItems.count
        finalBytesMovedToTrash += additionalMovedBytes
    }

    /// Counts items a retry moved to the Trash after the run finished, so a run that
    /// moved nothing at first still shows the "Empty your Trash" line once a retry
    /// does (#174). Items removed outright are not counted.
    func noteMovedToTrash(count: Int) {
        guard count > 0 else { return }
        movedToTrashCount += count
    }

    /// Counts a simulator, runtime or cask app a retry removed outright, so the
    /// outcome and the wording under the figure follow the retry (#162).
    func noteRemovedPermanently(count: Int) {
        guard count > 0 else { return }
        removedPermanentlyCount += count
    }

    /// Credits bytes from a partial retry while leaving its unresolved failure visible.
    func addRetriedMovedBytes(_ bytes: Int64) {
        guard bytes > 0 else { return }
        finalBytesMovedToTrash += bytes
    }

    /// Replaces one grouped failure with the exact items that remain after a partial
    /// uninstall. This keeps leftover failures visible after the app bundle moved.
    func replaceFailure(id: UUID, with replacements: [CleanFailureItem]) {
        guard let index = failedItems.firstIndex(where: { $0.id == id }) else { return }
        failedItems.remove(at: index)
        failedItems.insert(contentsOf: replacements, at: index)
        failedCount = failedItems.count
    }
}

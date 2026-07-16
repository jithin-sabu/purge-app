import AppKit
import Combine
import Foundation

/// Why an Empty Trash attempt did not complete. Nothing here fails silently: each
/// case either tells the user something or is a choice they just made themselves.
enum EmptyTrashFailure: Equatable {
    /// The user declined the automation prompt, or Purge was denied in
    /// Privacy & Security > Automation.
    case automationDenied
    /// The user backed out of a confirmation. Not a problem to explain to them.
    case cancelled
    /// Finder accepted the event but reported an error, or the event never landed.
    case finderError(String)

    /// `nil` when the user already knows why nothing happened, because they chose it.
    var message: String? {
        switch self {
        case .automationDenied:
            return """
            Purge needs permission to control Finder to empty the trash. Allow it in \
            System Settings > Privacy & Security > Automation, or empty the trash in Finder.
            """
        case .cancelled:
            return nil
        case .finderError(let detail):
            return "Finder could not empty the trash. \(detail)"
        }
    }

    /// Whether to put the user in front of the trash so they can finish by hand.
    /// Only when Purge cannot do it, never when the user chose to stop.
    var suggestsOpeningFinder: Bool {
        switch self {
        case .automationDenied, .finderError:
            return true
        case .cancelled:
            return false
        }
    }
}

/// What a completed Empty Trash actually recovered, measured on the volume.
struct EmptyTrashOutcome: Equatable {
    /// Trash total immediately before Finder emptied it.
    let bytesInTrashBefore: Int64
    /// Measured volume delta across the operation. `nil` when the volume could not be
    /// read at both ends, which stays distinct from a delta of zero.
    let bytesReclaimedOnVolume: Int64?

    /// `true` when the volume gave back meaningfully less than the trash held. Open
    /// file handles and APFS local snapshots both pin blocks past the delete, so this
    /// is normal rather than an error, and is shown rather than hidden.
    var reclaimedLessThanExpected: Bool {
        guard let bytesReclaimedOnVolume else { return false }
        return bytesReclaimedOnVolume < bytesInTrashBefore - VolumeCapacityReader.noiseFloorBytes
    }
}

/// Owns the trash total and the Empty Trash action.
///
/// Purge asks Finder to empty the trash rather than removing `~/.Trash` itself. Doing
/// it directly would require Full Disk Access, would miss the per-volume `.Trashes`
/// directories, and would make Purge the thing performing permanent deletion, which is
/// exactly what the trash-by-default design exists to avoid.
@MainActor
final class TrashStore: ObservableObject {
    @Published private(set) var trashBytes: Int64 = 0
    @Published private(set) var isEmptying = false
    /// Set when an attempt fails; the view shows it until the next attempt.
    @Published var lastFailure: EmptyTrashFailure?
    /// Result of the most recent completed empty, used to report what the volume
    /// actually gave back. Only ever set from a real measurement.
    @Published private(set) var lastOutcome: EmptyTrashOutcome?

    private let trashURL: URL?

    init() {
        trashURL = try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
    }

    var hasTrashContents: Bool { trashBytes > 0 }

    func refresh() async {
        guard let trashURL else { return }
        let bytes = await Task.detached(priority: .utility) {
            FolderSizing.directoryByteSize(at: trashURL)
        }.value
        trashBytes = bytes
    }

    /// Asks Finder to empty the trash, measuring the volume on both sides so the
    /// reclaimed figure comes from the volume rather than from what we hoped to free.
    /// Returns `true` only when Finder reported completion.
    func emptyTrash() async -> Bool {
        guard !isEmptying else { return false }
        isEmptying = true
        lastFailure = nil
        defer { isEmptying = false }

        let bytesInTrashBefore = trashBytes
        let capacityBefore = VolumeCapacityReader.read()

        let result = await Task.detached(priority: .userInitiated) {
            FinderTrashEmptier.emptyTrash()
        }.value

        switch result {
        case .success:
            let capacityAfter = VolumeCapacityReader.read()
            var reclaimed: Int64?
            if let capacityBefore, let capacityAfter {
                reclaimed = capacityAfter.availableBytes - capacityBefore.availableBytes
            }
            lastOutcome = EmptyTrashOutcome(
                bytesInTrashBefore: bytesInTrashBefore,
                bytesReclaimedOnVolume: reclaimed
            )
            await refresh()
            return true
        case .failure(let failure):
            lastFailure = failure
            return false
        }
    }

    /// Fallback when Purge cannot drive Finder: put the user in front of the trash so
    /// they can empty it themselves.
    func openTrashInFinder() {
        guard let trashURL else { return }
        NSWorkspace.shared.open(trashURL)
    }
}

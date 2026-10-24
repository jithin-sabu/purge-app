import Foundation

/// Which result screen a finished clean gets (#162). Picked from what happened,
/// never from a share of the items: one 40 GB item that failed next to nine small
/// ones that went is still a run that removed something, and a run that removed
/// nothing is a failure however small the one item was.
enum CleanOutcome: Equatable {
    /// Every item went. The success screen, as before.
    case success
    /// Some items went and at least one did not. The figure stays, because it is
    /// true, and the list of what stayed shows open under it.
    case partial
    /// Nothing went, and at least one item failed for a reason other than a
    /// safety skip. No checkmark, figure or timing: the failure is the screen.
    case failed
    /// Nothing went, and Purge kept every item on purpose. Neither a failure nor
    /// a success, so the screen says so plainly.
    case skippedOnly
    /// Nothing went and nothing is listed: every item was already gone, at clean
    /// time or by the time its row was retried. No figure, since nothing moved.
    case nothingLeft

    /// `removedCount` counts Trash moves and permanent removals alike. A row that
    /// a retry resolved has left `failedItems` and been counted, so the outcome
    /// follows the retries too.
    static func resolve(removedCount: Int, failedItems: [CleanFailureItem]) -> CleanOutcome {
        if failedItems.isEmpty { return removedCount > 0 ? .success : .nothingLeft }
        if removedCount > 0 { return .partial }
        return failedItems.allSatisfy { $0.reason == .safetySkipped } ? .skippedOnly : .failed
    }
}

extension CleanOutcome {
    /// Whether the screen shows the checkmark, the figure and the timing. A run
    /// that removed nothing has no figure to show.
    var showsFigure: Bool {
        switch self {
        case .success, .partial: true
        case .failed, .skippedOnly, .nothingLeft: false
        }
    }
}

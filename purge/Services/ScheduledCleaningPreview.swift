import Foundation

/// What the first scheduled clean would move, shown to the user before anything
/// moves (#331). Until the user chooses Clean once, a due scheduled clean shows
/// this list instead of cleaning. Choosing Clean cleans only these paths, each
/// checked again first; Not Now moves nothing and records nothing.
///
/// Built from the same checks the clean applies (`PurgeStore.safeCleanupBatch`),
/// so it lists Safe items going to the Trash only. Nothing here is ever deleted
/// permanently: simulators, runtimes and every other removal that skips the
/// Trash are never Safe, so they never reach a scheduled clean (#136).
struct ScheduledCleanPreview: Identifiable {
    let id = UUID()
    let candidates: [PurgeStore.DeletionCandidate]

    /// The standardized paths the user saw. The approved clean takes nothing
    /// outside this set.
    var paths: Set<String> {
        Set(candidates.map { $0.path.standardizedFileURL.path })
    }

    var totalBytes: Int64 {
        candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    /// Largest first, so the items that matter most are read first.
    var sortedCandidates: [PurgeStore.DeletionCandidate] {
        candidates.sorted {
            $0.sizeBytes == $1.sizeBytes
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : $0.sizeBytes > $1.sizeBytes
        }
    }

    /// One row per path. A clean can list the same folder twice when two scan
    /// rows reach it; the list shows it once.
    static func uniqueByPath(_ candidates: [PurgeStore.DeletionCandidate]) -> [PurgeStore.DeletionCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.path.standardizedFileURL.path).inserted }
    }

    /// The rows the approved clean may take: the clean's current Safe list,
    /// narrowed to paths the user saw. A row the user saw that is no longer in
    /// that list (it changed level, or was cleaned meanwhile) is left alone, and
    /// a row that appeared since the list was built is never added.
    static func approved(
        _ current: [PurgeStore.DeletionCandidate],
        paths: Set<String>
    ) -> [PurgeStore.DeletionCandidate] {
        current.filter {
            $0.safetyInfo.level == .safe && paths.contains($0.path.standardizedFileURL.path)
        }
    }
}

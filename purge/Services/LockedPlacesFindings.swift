import Foundation

/// What granting Full Disk Access turned up: the safe-to-clean items that sit in
/// places a limited scan could not read.
///
/// Counted by location, not by comparing totals before and after. The first
/// scan's items may already be in the Trash and caches grow back between scans,
/// so a difference of totals could come out inflated or even negative. An item
/// under a `ProtectedLocations` root, on the other hand, can only have been found
/// because of the permission.
struct LockedPlacesFindings {
    let bytes: Int64
    let categories: [OnboardingResultsCategory]
    /// The scan hit its time cap with project discovery or git checks still
    /// running, so more may turn up. Nothing can say "nothing was hiding" then.
    var isPartial = false

    /// Below this the number is too small to lead with, and the reveal talks about
    /// what access opened up instead of celebrating a few megabytes.
    static let headlineThresholdBytes: Int64 = 500 * 1024 * 1024

    var isWorthLeadingWith: Bool { bytes >= Self.headlineThresholdBytes }

    /// Large files are left out on purpose: they are the user's own files, not
    /// clutter, and Purge never counts them toward "to clean".
    static func from(candidates: [PurgeStore.DeletionCandidate], categorize: ([PurgeStore.DeletionCandidate]) -> [OnboardingResultsCategory]) -> LockedPlacesFindings {
        let locked = candidates.filter { ProtectedLocations.contains($0.path) }
        return LockedPlacesFindings(
            bytes: locked.reduce(Int64(0)) { $0 + $1.sizeBytes },
            categories: categorize(locked)
        )
    }
}

extension PurgeStore {
    func lockedPlacesFindings() -> LockedPlacesFindings {
        LockedPlacesFindings.from(candidates: manualSafeCleanupCandidates()) { resultsCategories(for: $0) }
    }

    /// Runs a full scan and reports what the newly readable places held.
    ///
    /// `scanAll` returns before project discovery and its git checks finish, and
    /// projects in Documents or Desktop are often the biggest thing access unlocks,
    /// so this waits for them too, up to a cap so a huge home folder can't hold the
    /// reveal open.
    func scanLockedPlaces() async -> LockedPlacesFindings {
        await scanAll()
        let deadline = Date().addingTimeInterval(30)
        while isScanningProjects || isEnrichingDeveloper || isEnrichingGeneral, Date() < deadline {
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        var findings = lockedPlacesFindings()
        findings.isPartial = isScanningProjects || isEnrichingDeveloper || isEnrichingGeneral
        return findings
    }

    private static let lastKnownFullDiskAccessKey = "access.lastKnownFullDiskAccess"

    /// True exactly once per grant: access is on now, and the last value Purge
    /// recorded was off. Persisted, so a grant that came with macOS's "Quit &
    /// Reopen" still counts on the next launch. Every caller records the current
    /// value, which is how the look-deeper screen claims a grant it already showed.
    @discardableResult
    func consumeFullDiskAccessGrant(userDefaults: UserDefaults = .standard) -> Bool {
        let previous = userDefaults.object(forKey: Self.lastKnownFullDiskAccessKey) as? Bool
        userDefaults.set(hasFullDiskAccess, forKey: Self.lastKnownFullDiskAccessKey)
        return previous == false && hasFullDiskAccess
    }

    /// For a grant made while the look-deeper screen was not open: rescan, then let
    /// the sidebar say what turned up.
    func revealFullDiskAccessGrant() async {
        let findings = await scanLockedPlaces()
        accessGrantFindings = findings
    }
}

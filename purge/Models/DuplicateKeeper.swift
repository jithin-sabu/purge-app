import Foundation

/// Suggests which copy in a duplicate group is worth keeping, so the "keep one,
/// delete the rest" action can pre-select a survivor.
///
/// This only *suggests*. The user always sees the choice and can pick a different
/// copy before anything moves to Trash. Issue #17 rejected choosing the survivor
/// *silently*; a visible, overridable suggestion is a different thing.
///
/// The pick is deterministic and based only on the path, because that is all a
/// duplicate group agrees on. Every copy is byte-identical and the same size, so
/// content tells them apart in no way. Signals, most important first:
///
/// 1. **Where it lives.** A copy in a cache, a build folder, or `node_modules` is
///    disposable; one in Downloads or on the Desktop is a landing zone; anything
///    else is treated as a real home. Keep the realest home.
/// 2. **What it's called.** A `… copy`, `… copy 2`, or `… (1)` name is the copy,
///    not the original. Keep the canonical name.
/// 3. **Tie-breakers.** Fewer path components, then the path itself, so the same
///    group always suggests the same keeper across scans.
nonisolated enum DuplicateKeeper {
    /// The id of the copy to keep, or nil for an empty group.
    static func suggestedKeeperID(among files: [LargeFile]) -> String? {
        files.min { sortKey(for: $0) < sortKey(for: $1) }?.id
    }

    /// Lower sorts first, and first is the keeper.
    private static func sortKey(for file: LargeFile) -> (Int, Int, Int, String) {
        let path = file.id // already the standardized path
        let base = file.path.deletingPathExtension().lastPathComponent
        return (
            locationRank(path),
            copyNameRank(base),
            path.split(separator: "/").count,
            path
        )
    }

    /// 0 for a real home, 1 for a landing zone (Downloads/Desktop), 2 for a
    /// disposable location. The keeper wants the lowest.
    private static func locationRank(_ path: String) -> Int {
        let lower = path.lowercased()
        let disposable = [
            "/library/caches/", "/caches/", "/.cache/",
            "/deriveddata/", "/library/developer/xcode/",
            "/node_modules/", "/.build/", "/build/", "/target/",
            "/.trash/", "/tmp/", "/.tmp/",
        ]
        if disposable.contains(where: lower.contains) { return 2 }
        if lower.contains("/downloads/") || lower.contains("/desktop/") { return 1 }
        return 0
    }

    /// 1 when the name looks like a duplicate the OS or the user made — `foo copy`,
    /// `foo copy 3`, `foo (1)` — else 0. The keeper wants 0.
    private static func copyNameRank(_ base: String) -> Int {
        let name = base.lowercased()
        if name.range(of: #" copy( \d+)?$"#, options: .regularExpression) != nil { return 1 }
        if name.range(of: #" \(\d+\)$"#, options: .regularExpression) != nil { return 1 }
        return 0
    }
}

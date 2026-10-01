import Foundation

/// What Settings knows about one excluded path's size.
nonisolated enum ExcludedPathSize: Equatable, Sendable {
    case measured(Int64)
    /// Nothing exists at the path any more.
    case missing
    /// The path exists but `du` produced no reading for it (denied, interrupted).
    /// Not the same as empty, so it never counts as 0.
    case unmeasurable
}

/// The Total row under Settings > Excluded from scans.
nonisolated struct ExcludedPathsTotal: Equatable, Sendable {
    let bytes: Int64
    /// Every counted path has a result, so the figure is final.
    let isComplete: Bool
    /// At least one counted path couldn't be measured, so `bytes` is a floor.
    let hasUnmeasured: Bool

    /// Counts each byte once. A path inside another listed path is already part of
    /// that folder's size, which happens when someone excludes a file and later its
    /// folder, so only paths with no listed ancestor are added up.
    static func compute(paths: [String], sizes: [String: ExcludedPathSize]) -> ExcludedPathsTotal {
        var bytes: Int64 = 0
        var isComplete = true
        var hasUnmeasured = false
        for path in topLevel(paths) {
            switch sizes[path] {
            case .measured(let value): bytes += value
            case .missing: break
            case .unmeasurable: hasUnmeasured = true
            case nil: isComplete = false
            }
        }
        return ExcludedPathsTotal(bytes: bytes, isComplete: isComplete, hasUnmeasured: hasUnmeasured)
    }

    /// `paths` minus any that sit inside another entry of `paths`.
    static func topLevel(_ paths: [String]) -> [String] {
        let all = Set(paths)
        return paths.filter { path in
            !all.contains { other in
                other != path && path.hasPrefix(other.hasSuffix("/") ? other : other + "/")
            }
        }
    }
}

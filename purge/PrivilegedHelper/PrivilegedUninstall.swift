import Foundation

/// Outcome of an escalated move: which paths reached the Trash and which did not.
nonisolated struct PrivilegedMoveResult: Sendable {
    let moved: [URL]
    let failed: [URL]
}

/// The single entry point the deletion engine uses to escalate a stuck uninstall.
///
/// Escalation goes through the signed helper and nothing else. There is deliberately
/// no unprivileged fallback: the old osascript route made macOS show a "could not
/// verify this script is free of malware" dialog, which is the first thing a new user
/// would ever see and reads like an attack. So if the helper is not set up yet, this
/// moves nothing and reports the items back — the UI then invites the user to enable
/// the helper once, through the trustworthy system prompt, rather than ambushing them.
nonisolated enum PrivilegedUninstall {
    static func moveToTrash(_ urls: [URL]) async -> PrivilegedMoveResult {
        guard !urls.isEmpty else { return PrivilegedMoveResult(moved: [], failed: []) }

        let trashDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")

        guard let result = await PrivilegedHelperManager.shared.moveToTrash(urls, trashDirectory: trashDirectory) else {
            // Helper not enabled (or unreachable): nothing moved, nothing scary shown.
            return PrivilegedMoveResult(moved: [], failed: urls)
        }
        return result
    }
}

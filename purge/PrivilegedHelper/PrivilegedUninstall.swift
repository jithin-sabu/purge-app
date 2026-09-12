import Foundation

/// Outcome of an escalated move. `indeterminate` means the helper did not reply, so
/// the caller must not claim either success or failure until it checks the disk.
/// `ownershipIncomplete` is the subset of `moved` the helper could not fully hand
/// back: those items are in the Trash, but emptying them may prompt for a password.
nonisolated struct PrivilegedMoveResult: Sendable {
    let moved: [URL]
    let failed: [URL]
    let indeterminate: [URL]
    var ownershipIncomplete: [URL] = []
    /// `true` when an enabled helper actually attempted the move. `false` means the
    /// helper is not set up yet, so a still-present item is a one-time-setup prompt,
    /// not a failure of an escalated attempt.
    var helperAvailable: Bool = true
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
        guard !urls.isEmpty else {
            return PrivilegedMoveResult(moved: [], failed: [], indeterminate: [])
        }

        // The root helper validates this directory but never creates it. Creating it
        // here means it naturally belongs to the signed-in user.
        let trashDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: trashDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        guard let result = await PrivilegedHelperManager.shared.moveToTrash(urls) else {
            // Helper not enabled (or unreachable): nothing moved, nothing scary shown.
            return PrivilegedMoveResult(
                moved: [],
                failed: urls,
                indeterminate: [],
                helperAvailable: false
            )
        }
        return result
    }
}

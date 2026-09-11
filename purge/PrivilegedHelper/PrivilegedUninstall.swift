import Foundation

/// The single entry point the deletion engine uses to escalate a stuck uninstall.
/// It prefers the installed root helper — silent, no password — and falls back to the
/// one-shot osascript prompt when the helper isn't enabled yet, so a locked app can
/// always be removed either way. Both routes move to the Trash; neither deletes for good.
nonisolated enum PrivilegedUninstall {
    static func moveToTrash(_ urls: [URL]) async -> PrivilegedRemover.Result {
        let trashDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")

        if let viaHelper = await PrivilegedHelperManager.shared.moveToTrash(urls, trashDirectory: trashDirectory) {
            return viaHelper
        }
        return await PrivilegedRemover.moveToTrashAsRoot(urls, trashDirectory: trashDirectory)
    }
}

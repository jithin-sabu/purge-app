import Foundation

/// The helper's build version. Bump it whenever the helper's behaviour changes so the
/// app can notice a stale copy left by a previous install and re-register the current
/// one. Kept as a plain constant because a launchd tool has no Info.plist to read.
enum HelperInfo {
    static let version = "1"
}

/// The root-side implementation of the one privileged operation Purge performs:
/// moving a caller-chosen path into the user's Trash and handing ownership back. It
/// assumes nothing about intent — the app already vetted and the user already
/// confirmed what to remove — but it still refuses a destination that is not a Trash
/// directory, so a future caller bug cannot turn this into an arbitrary mover.
final class HelperService: NSObject, PurgeHelperProtocol {
    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply(HelperInfo.version)
    }

    func moveToTrash(
        paths: [String],
        trashDirectoryPath: String,
        uid: Int,
        gid: Int,
        withReply reply: @escaping ([String]) -> Void
    ) {
        let fileManager = FileManager.default

        // Defence in depth behind the code-signing gate: only ever move *into* a
        // Trash. The client is already proven to be Purge, but a narrow destination
        // means even a bug on that side cannot relocate files anywhere else.
        let trashDirectory = URL(fileURLWithPath: trashDirectoryPath, isDirectory: true)
        guard trashDirectory.lastPathComponent == ".Trash",
              isDirectory(trashDirectory.path, fileManager: fileManager) else {
            NSLog("PurgeHelper: refusing non-Trash destination %@", trashDirectoryPath)
            reply([])
            return
        }

        var moved: [String] = []
        var claimed = Set<String>()
        for path in paths {
            let source = URL(fileURLWithPath: path)
            guard fileManager.fileExists(atPath: source.path) else { continue }

            let destination = uniqueDestination(for: source, in: trashDirectory, claimed: &claimed, fileManager: fileManager)
            do {
                try fileManager.moveItem(at: source, to: destination)
                chownRecursively(at: destination, uid: uid_t(uid), gid: gid_t(gid))
                moved.append(path)
            } catch {
                NSLog("PurgeHelper: move failed for %@ — %@", path, error.localizedDescription)
            }
        }
        reply(moved)
    }

    private func isDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// `~/.Trash/Name`, or `Name <n>` when taken, so a re-run or an existing trashed
    /// copy never makes the move clobber or fail.
    private func uniqueDestination(
        for url: URL,
        in trashDirectory: URL,
        claimed: inout Set<String>,
        fileManager: FileManager
    ) -> URL {
        let name = url.lastPathComponent
        var candidate = trashDirectory.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: candidate.path), claimed.insert(candidate.path).inserted {
            return candidate
        }

        let ext = url.pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var suffix = 1
        repeat {
            let stamped = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            candidate = trashDirectory.appendingPathComponent(stamped)
            suffix += 1
        } while fileManager.fileExists(atPath: candidate.path) || !claimed.insert(candidate.path).inserted
        return candidate
    }

    /// Hands the moved item and everything under it back to the user, so emptying the
    /// Trash later needs no second authorization. `lchown` so a symlink is retargeted,
    /// never followed out of the tree.
    private func chownRecursively(at url: URL, uid: uid_t, gid: gid_t) {
        _ = lchownPath(url.path, uid: uid, gid: gid)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for case let child as URL in enumerator {
            _ = lchownPath(child.path, uid: uid, gid: gid)
        }
    }

    private func lchownPath(_ path: String, uid: uid_t, gid: gid_t) -> Bool {
        path.withCString { lchown($0, uid, gid) == 0 }
    }
}

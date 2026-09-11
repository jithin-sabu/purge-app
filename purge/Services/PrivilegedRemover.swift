import Foundation

/// Removes files the current user cannot move unaided — chiefly root-owned app
/// bundles that an installer planted in `/Applications` — by asking macOS for a
/// single administrator authorization and doing the move as root.
///
/// This is the *only* place Purge escalates. It exists so an uninstall the user
/// explicitly asked for cannot be quietly defeated by ownership the user never
/// chose: without it a bundle owned by `root:wheel` reports a bare "couldn't be
/// removed", and no retry can ever succeed because trashing a directory is a
/// cross-directory rename that needs write permission the user does not hold.
///
/// It still *moves to the Trash*, never `rm`s: the removal stays recoverable, so
/// the app's no-permanent-delete stance holds even here. The moved item is then
/// chowned back to the user, so emptying the Trash later needs no second prompt.
nonisolated enum PrivilegedRemover {
    struct Result: Sendable {
        /// Paths that now sit in the Trash.
        let moved: [URL]
        /// Paths still present on disk after the attempt.
        let failed: [URL]
        /// The user dismissed the administrator prompt. `failed` then holds
        /// everything, and the caller should treat it as retryable, not broken.
        let cancelled: Bool
    }

    /// The auth dialog blocks on the user typing a password, so the budget is
    /// generous — but still bounded, so a dialog left untouched cannot wedge the run.
    private static let authTimeout: TimeInterval = 300

    /// Moves each still-present URL into `trashDirectory` as root behind one prompt.
    /// Determines success by re-checking the source afterwards, so a partial run is
    /// reported honestly rather than trusting a single exit code.
    static func moveToTrashAsRoot(_ urls: [URL], trashDirectory: URL) async -> Result {
        let present = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !present.isEmpty else {
            return Result(moved: [], failed: [], cancelled: false)
        }

        // Pre-resolve a collision-free destination per item so the shell only has to
        // `mv`, and chown it back to the invoking user so the Trash stays emptyable.
        var pairs: [(src: URL, dst: URL)] = []
        var claimed = Set<String>()
        for url in present {
            let dst = uniqueDestination(for: url, in: trashDirectory, claimed: &claimed)
            pairs.append((url, dst))
        }

        guard let scriptURL = writeMoveScript(pairs: pairs) else {
            return Result(moved: [], failed: present, cancelled: false)
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        // The script path is a per-user $TMPDIR UUID, so it carries no quote that
        // could break out of the AppleScript string literal — but refuse rather than
        // risk it if that ever stops being true.
        guard !scriptURL.path.contains("\"") else {
            return Result(moved: [], failed: present, cancelled: false)
        }
        let appleScript = "do shell script \"/bin/sh '\(scriptURL.path)'\" with administrator privileges"

        let output = await ProcessRunner.runAsync(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", appleScript],
            timeout: authTimeout
        )

        // Truth comes from the filesystem, not the exit code: whatever still exists
        // at its source did not move, whatever is gone did.
        var moved: [URL] = []
        var failed: [URL] = []
        for (src, _) in pairs {
            if FileManager.default.fileExists(atPath: src.path) {
                failed.append(src)
            } else {
                moved.append(src)
            }
        }

        let cancelled = moved.isEmpty && wasCancelled(output)
        return Result(moved: moved, failed: failed, cancelled: cancelled)
    }

    /// A `-128` / "User canceled" from osascript is the user dismissing the prompt,
    /// which is a benign "not now", distinct from an authorization that failed.
    private static func wasCancelled(_ output: ProcessRunner.Output?) -> Bool {
        guard let output, !output.succeeded else { return false }
        let stderr = output.stderrText
        return stderr.contains("-128") || stderr.localizedCaseInsensitiveContains("User canceled")
    }

    /// `~/.Trash/Name`, or `Name <timestamp>` when that is taken, so a re-run or an
    /// existing trashed copy never makes `mv` clobber or refuse.
    private static func uniqueDestination(
        for url: URL,
        in trashDirectory: URL,
        claimed: inout Set<String>
    ) -> URL {
        let name = url.lastPathComponent
        var candidate = trashDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path), claimed.insert(candidate.path).inserted {
            return candidate
        }

        let ext = url.pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var suffix = 1
        repeat {
            let stamped = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            candidate = trashDirectory.appendingPathComponent(stamped)
            suffix += 1
        } while FileManager.default.fileExists(atPath: candidate.path) || !claimed.insert(candidate.path).inserted
        return candidate
    }

    /// Writes the root-side `mv`+`chown` script to the per-user temp directory
    /// (mode 0700, owner-only), returning `nil` if it cannot be written.
    private static func writeMoveScript(pairs: [(src: URL, dst: URL)]) -> URL? {
        let uid = getuid()
        let gid = getgid()
        var lines = ["#!/bin/sh"]
        for (src, dst) in pairs {
            let s = shellQuoted(src.path)
            let d = shellQuoted(dst.path)
            // chown only on a successful move, so a failed item is never re-owned in place.
            lines.append("/bin/mv -f \(s) \(d) && /usr/sbin/chown -R \(uid):\(gid) \(d)")
        }
        let script = lines.joined(separator: "\n") + "\n"

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-privileged-\(UUID().uuidString).sh")
        do {
            try script.data(using: .utf8)?.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    /// Single-quotes a path for `/bin/sh`, escaping embedded single quotes the only
    /// way single-quoting allows: close, an escaped quote, reopen.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

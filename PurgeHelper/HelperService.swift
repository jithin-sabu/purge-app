import Darwin
import Foundation
import os

/// The root-side implementation of the one privileged operation Purge performs:
/// moving an approved uninstall path, or a leftover macOS update file, into the
/// connecting user's Trash and handing ownership back. Both the source and
/// destination are opened without following symlinks, so another process cannot
/// redirect a checked path while the move runs.
final class HelperService: NSObject, PurgeHelperProtocol {
    private let idleTracker: HelperIdleTracker

    /// Paths and error numbers are public: an app path is not private, and without
    /// them a failed removal can't be explained from the log (#299).
    private static let log = Logger(subsystem: PurgeHelperConstants.machServiceName, category: "move")

    init(idleTracker: HelperIdleTracker) {
        self.idleTracker = idleTracker
    }

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply(PurgeHelperConstants.version)
    }

    func moveToTrash(
        paths: [String],
        withReply reply: @escaping ([String]) -> Void
    ) {
        reply(performMove(paths: paths).moved)
    }

    func moveToTrashReportingOwnership(
        paths: [String],
        withReply reply: @escaping ([String], [String]) -> Void
    ) {
        let outcome = performMove(paths: paths)
        reply(outcome.moved, outcome.ownershipIncomplete)
    }

    func moveToTrashReportingFailures(
        paths: [String],
        withReply reply: @escaping ([String], [String], [String: Int], Int) -> Void
    ) {
        let outcome = performMove(paths: paths)
        reply(outcome.moved, outcome.ownershipIncomplete, outcome.failureCodes, outcome.refusal.rawValue)
    }

    /// The result of a move request: which paths left their source, and which of those
    /// moved items the helper could not fully hand back to the user. An item in
    /// `ownershipIncomplete` is also in `moved` — it is in the Trash, but emptying it
    /// may prompt for a password. `refusal` says why the whole request was turned
    /// down, and `failureCodes` why each tried path stayed (#299).
    private struct MoveOutcome {
        var moved: [String] = []
        var ownershipIncomplete: [String] = []
        var failureCodes: [String: Int] = [:]
        var refusal: HelperMoveRefusal = .accepted

        init(refusal: HelperMoveRefusal = .accepted) {
            self.refusal = refusal
        }
    }

    /// The one privileged operation, shared by both reply shapes. The peer identity
    /// determines both ownership and destination. Nothing in a root operation should
    /// trust a uid, gid, or Trash path supplied by the app.
    private func performMove(paths: [String]) -> MoveOutcome {
        // Keep the helper alive until this move and its ownership hand-back finish,
        // even if the app stops waiting and closes the connection first.
        idleTracker.acquire()
        defer { idleTracker.release() }

        guard let connection = NSXPCConnection.current() else {
            Self.log.error("refusing request without a current XPC connection")
            return MoveOutcome(refusal: .invalidPeer)
        }
        let ownerUID = connection.effectiveUserIdentifier
        let ownerGID = connection.effectiveGroupIdentifier
        guard ownerUID != 0, let account = userAccount(for: ownerUID) else {
            Self.log.error("refusing request with invalid peer uid \(ownerUID, privacy: .public)")
            return MoveOutcome(refusal: .invalidPeer)
        }

        // The caller being the genuine Purge app is not enough: this helper is shared by
        // every account on the Mac once any administrator approves it. Removing
        // protected apps is an administrator action, so require the connecting user to
        // be an administrator too. A standard account is refused even through a real
        // Purge, and is told to ask an administrator to run the removal.
        guard isAdministrator(account) else {
            Self.log.error("refusing non-administrator peer uid \(ownerUID, privacy: .public)")
            return MoveOutcome(refusal: .notAdministrator)
        }

        let homeDirectory = account.home
        let trashDirectory = homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
        guard let trashFD = HelperDirectory.openWithoutFollowingSymlinks(trashDirectory),
              validatedTrashDirectory(fileDescriptor: trashFD, ownerUID: ownerUID) else {
            Self.log.error("refusing invalid Trash directory \(trashDirectory.path, privacy: .public)")
            return MoveOutcome(refusal: .invalidTrash)
        }
        defer { close(trashFD) }

        // Decided once, before anything moves: moving an entry out changes the
        // folder's date, which would refuse the rest of the same request.
        let installLeftoverRuleHolds = paths.contains {
            PurgeHelperConstants.isAllowedInstallLeftoverLocation(URL(fileURLWithPath: $0))
        } && MacOSInstallLeftovers.isLeftover()

        var outcome = MoveOutcome()
        for path in paths {
            let source = URL(fileURLWithPath: path)
            guard PurgeHelperConstants.isAllowedMoveSource(
                source,
                homeDirectory: homeDirectory,
                installLeftoverRuleHolds: installLeftoverRuleHolds
            ) else {
                Self.log.error("refusing source outside allowed locations \(source.path, privacy: .public)")
                outcome.failureCodes[path] = PurgeHelperConstants.outsideAllowedLocationsCode
                continue
            }

            let result = secureMoveToTrash(
                source,
                trashFD: trashFD,
                uid: ownerUID,
                gid: ownerGID
            )
            if result.moved {
                outcome.moved.append(path)
                if !result.ownershipComplete { outcome.ownershipIncomplete.append(path) }
            } else {
                Self.log.error("move failed for \(path, privacy: .public) (errno \(result.failureErrno, privacy: .public))")
                outcome.failureCodes[path] = Int(result.failureErrno)
            }
        }
        return outcome
    }

    /// The connecting user's directory record, read once per request.
    private struct UserAccount {
        let name: String
        let primaryGID: gid_t
        let home: URL
    }

    /// Looks up the connecting user without consulting the daemon's own
    /// environment, which belongs to root. The strings are copied while the
    /// re-entrant lookup buffer is alive.
    private func userAccount(for uid: uid_t) -> UserAccount? {
        let suggestedSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        let bufferSize = suggestedSize > 0 ? Int(suggestedSize) : 16_384
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: bufferSize)

        return buffer.withUnsafeMutableBufferPointer { storage in
            guard let baseAddress = storage.baseAddress else { return nil }
            let status = getpwuid_r(uid, &record, baseAddress, storage.count, &result)
            guard status == 0, result != nil,
                  let namePointer = record.pw_name,
                  let directory = record.pw_dir else { return nil }
            return UserAccount(
                name: String(cString: namePointer),
                primaryGID: record.pw_gid,
                home: URL(fileURLWithPath: String(cString: directory), isDirectory: true).standardizedFileURL
            )
        }
    }

    /// The gid of the local `admin` group, read from its directory record.
    private func adminGroupID() -> gid_t? {
        let suggestedSize = sysconf(_SC_GETGR_R_SIZE_MAX)
        let bufferSize = suggestedSize > 0 ? Int(suggestedSize) : 16_384
        var record = group()
        var result: UnsafeMutablePointer<group>?
        var buffer = [CChar](repeating: 0, count: bufferSize)

        let status = buffer.withUnsafeMutableBufferPointer { storage -> Int32 in
            guard let baseAddress = storage.baseAddress else { return -1 }
            return getgrnam_r("admin", &record, baseAddress, storage.count, &result)
        }
        guard status == 0, result != nil else { return nil }
        return record.gr_gid
    }

    /// True only when the account is a member of the local `admin` group. Any
    /// lookup that fails refuses.
    private func isAdministrator(_ account: UserAccount) -> Bool {
        guard let adminGID = adminGroupID() else { return false }
        var capacity: Int32 = 32
        // A short buffer makes `getgrouplist` return -1, so it grows and asks
        // again. A list that never fits refuses.
        while capacity <= 4_096 {
            var groups = [Int32](repeating: 0, count: Int(capacity))
            var count = capacity
            let status = account.name.withCString {
                getgrouplist($0, Int32(bitPattern: account.primaryGID), &groups, &count)
            }
            if status == 0 {
                return groups.prefix(Int(count)).contains(Int32(bitPattern: adminGID))
            }
            capacity = max(capacity * 2, count)
        }
        return false
    }

    /// Requires the real, user-owned ~/.Trash directory. The descriptor was opened
    /// one path component at a time with `O_NOFOLLOW`, so no component can be a
    /// symlink and its identity stays fixed for this request.
    private func validatedTrashDirectory(fileDescriptor: Int32, ownerUID: uid_t) -> Bool {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == ownerUID
    }

    /// Whether a move happened and, if so, whether every moved file's ownership was
    /// handed back. `moved == false` means nothing left the source; when `moved` is
    /// true, `ownershipComplete == false` means the item is in the Trash but still
    /// partly owned by root, so emptying it may prompt for a password.
    private struct SecureMoveResult {
        let moved: Bool
        let ownershipComplete: Bool
        /// The errno of the step that failed, read right after that call, or 0 when
        /// the item moved. Reading the global `errno` later gives whatever the
        /// cleanup calls left there.
        var failureErrno: Int32 = 0
    }

    /// Atomically renames the source relative to already-open source and Trash
    /// directories. This means path components cannot be swapped after validation.
    private func secureMoveToTrash(_ source: URL, trashFD: Int32, uid: uid_t, gid: gid_t) -> SecureMoveResult {
        func notMoved(_ code: Int32) -> SecureMoveResult {
            SecureMoveResult(moved: false, ownershipComplete: false, failureErrno: code)
        }
        guard let sourceParentFD = HelperDirectory.openWithoutFollowingSymlinks(source.deletingLastPathComponent()) else {
            return notMoved(errno)
        }
        defer { close(sourceParentFD) }

        let sourceName = source.lastPathComponent
        let sourceFD = sourceName.withCString {
            openat(sourceParentFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceFD >= 0 else { return notMoved(errno) }
        defer { close(sourceFD) }

        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0 else { return notMoved(errno) }
        let sourceType = sourceInfo.st_mode & S_IFMT
        guard sourceType == S_IFDIR || sourceType == S_IFREG else { return notMoved(EFTYPE) }

        let renameErrno = renameToUniqueDestination(
            source,
            sourceParentFD: sourceParentFD,
            sourceName: sourceName,
            trashFD: trashFD
        )
        guard renameErrno == 0 else { return notMoved(renameErrno) }

        let ownershipComplete = chownRecursively(fileDescriptor: sourceFD, uid: uid, gid: gid)
        if !ownershipComplete {
            Self.log.error("moved \(source.path, privacy: .public) but could not update every owner")
        }
        return SecureMoveResult(moved: true, ownershipComplete: ownershipComplete)
    }

    /// Renames to a unique Trash name with `RENAME_EXCL`, which makes the collision
    /// check and move one atomic operation. A different process cannot create an item
    /// between those two steps and have it overwritten. Returns 0 on success, or the
    /// rename's errno.
    private func renameToUniqueDestination(
        _ source: URL,
        sourceParentFD: Int32,
        sourceName: String,
        trashFD: Int32
    ) -> Int32 {
        let name = source.lastPathComponent
        let ext = source.pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))

        for suffix in 0..<10_000 {
            let candidate: String
            if suffix == 0 {
                candidate = name
            } else {
                candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            }

            let result = sourceName.withCString { sourcePointer in
                candidate.withCString { destinationPointer in
                    renameatx_np(
                        sourceParentFD,
                        sourcePointer,
                        trashFD,
                        destinationPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if result == 0 { return 0 }
            let code = errno
            if code != EEXIST { return code }
        }
        return EEXIST
    }

    /// Changes descendants first and the containing directory last. The operation
    /// stays attached to open descriptors, even if the item is renamed in Trash.
    private func chownRecursively(fileDescriptor: Int32, uid: uid_t, gid: gid_t) -> Bool {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else { return false }
        var succeeded = true

        if (info.st_mode & S_IFMT) == S_IFDIR {
            let duplicate = dup(fileDescriptor)
            guard duplicate >= 0, let directory = fdopendir(duplicate) else {
                if duplicate >= 0 { close(duplicate) }
                return false
            }
            defer { closedir(directory) }

            while let entry = readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }

                let childFD = name.withCString {
                    openat(fileDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                }
                if childFD >= 0 {
                    if !chownRecursively(fileDescriptor: childFD, uid: uid, gid: gid) {
                        succeeded = false
                    }
                    close(childFD)
                } else if errno == ELOOP {
                    // Symlinks are owned without following their targets.
                    let result = name.withCString {
                        fchownat(fileDescriptor, $0, uid, gid, AT_SYMLINK_NOFOLLOW)
                    }
                    if result != 0 { succeeded = false }
                } else {
                    succeeded = false
                }
            }
        }

        if fchown(fileDescriptor, uid, gid) != 0 { succeeded = false }
        return succeeded
    }
}

import Darwin
import Foundation
import os
import Security

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

    func moveToTrashWithAuthorization(
        paths: [String],
        authorization: Data,
        withReply reply: @escaping ([String], [String], [String: Int], Int) -> Void
    ) {
        let outcome = performMove(paths: paths, authorization: authorization)
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

    /// The one privileged operation, shared by every reply shape. The peer identity
    /// determines both ownership and destination. Nothing in a root operation should
    /// trust a uid, gid, or Trash path supplied by the app.
    /// - Parameter authorization: The external form of the app's `AuthorizationRef`,
    ///   used to ask an administrator to approve a standard account's request. `nil`
    ///   from the older methods, which refuse a standard account outright.
    private func performMove(paths: [String], authorization: Data? = nil) -> MoveOutcome {
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
        guard ownerUID != 0, let account = UserRecord.lookUp(uid: ownerUID) else {
            Self.log.error("refusing request with invalid peer uid \(ownerUID, privacy: .public)")
            return MoveOutcome(refusal: .invalidPeer)
        }

        let homeDirectory = account.home
        let trashDirectory = homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
        guard let trashFD = HelperDirectory.openWithoutFollowingSymlinks(trashDirectory),
              validatedTrashDirectory(fileDescriptor: trashFD, ownerUID: ownerUID) else {
            Self.log.error("refusing invalid Trash directory \(trashDirectory.path, privacy: .public)")
            return MoveOutcome(refusal: .invalidTrash)
        }
        defer { close(trashFD) }

        var outcome = MoveOutcome()
        var allowedPaths = allowedSources(paths, homeDirectory: homeDirectory, outcome: &outcome)
        // Nothing to move, so nobody is asked for a password.
        guard !allowedPaths.isEmpty else { return outcome }

        // The caller being the genuine Purge app is not enough: this helper is shared by
        // every account on the Mac once any administrator approves it. Removing
        // protected apps is an administrator action, as it is in Finder. An
        // administrator's own request goes ahead. A standard account's goes ahead only
        // once an administrator types their name and password for it (#314).
        if !AdministratorMembership.includes(userName: account.name, primaryGID: account.primaryGID) {
            let approval = administratorApproval(authorization)
            guard approval == .accepted else {
                Self.log.error("refusing non-administrator peer uid \(ownerUID, privacy: .public) (refusal \(approval.rawValue, privacy: .public))")
                return MoveOutcome(refusal: approval)
            }
            Self.log.notice("an administrator approved the request of peer uid \(ownerUID, privacy: .public)")
            // The dialog can stay open for minutes, and the paths can change on disk
            // while it does, so every check runs again now, right before the moves.
            outcome = MoveOutcome()
            allowedPaths = allowedSources(paths, homeDirectory: homeDirectory, outcome: &outcome)
        }

        for path in allowedPaths {
            let result = secureMoveToTrash(
                URL(fileURLWithPath: path),
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

    /// The paths the helper may move, in order. Each one outside the allowed places
    /// gets its failure code in `outcome`. The macOS update rule is decided here, once
    /// for the request and before anything moves: moving an entry out changes the
    /// folder's date, which would refuse the rest of the same request.
    private func allowedSources(_ paths: [String], homeDirectory: URL, outcome: inout MoveOutcome) -> [String] {
        let installLeftoverRuleHolds = paths.contains {
            PurgeHelperConstants.isAllowedInstallLeftoverLocation(URL(fileURLWithPath: $0))
        } && MacOSInstallLeftovers.isLeftover()

        var allowed: [String] = []
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
            allowed.append(path)
        }
        return allowed
    }

    /// Asks an administrator to approve a standard account's request, in a macOS
    /// dialog shown in the app's session (#314). `.accepted` only when an
    /// administrator's name and password were typed for this request.
    ///
    /// The right's definition is written first, as root, every time: any process may
    /// add a right macOS doesn't know yet, so a rule that asks for nothing could
    /// otherwise sit under this name. Changing a right that exists takes an
    /// administrator or root.
    private func administratorApproval(_ authorization: Data?) -> HelperMoveRefusal {
        // The older methods carry no authorization, so a standard account is refused.
        guard let authorization else { return .notAdministrator }
        guard authorization.count == MemoryLayout<AuthorizationExternalForm>.size else {
            Self.log.error("refusing an authorization of \(authorization.count, privacy: .public) bytes")
            return .approvalUnavailable
        }

        var rootAuthorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &rootAuthorization) == errAuthorizationSuccess,
              let rootAuthorization else {
            Self.log.error("could not create the helper's own authorization")
            return .approvalUnavailable
        }
        defer { AuthorizationFree(rootAuthorization, []) }
        let setStatus = AuthorizationRightSet(
            rootAuthorization,
            PurgeHelperConstants.removalRightName,
            PurgeHelperConstants.removalRightDefinition as CFDictionary,
            nil,
            nil,
            nil
        )
        guard setStatus == errAuthorizationSuccess else {
            Self.log.error("could not write the removal right (status \(setStatus, privacy: .public))")
            return .approvalUnavailable
        }

        var externalForm = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &externalForm) { _ = authorization.copyBytes(to: $0) }
        var clientAuthorization: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&externalForm, &clientAuthorization) == errAuthorizationSuccess,
              let clientAuthorization else {
            Self.log.error("could not read the app's authorization")
            return .approvalUnavailable
        }
        // The app owns this authorization, so its rights are left for the app to free.
        defer { AuthorizationFree(clientAuthorization, []) }

        let status = PurgeHelperConstants.removalRightName.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(
                    clientAuthorization,
                    &rights,
                    nil,
                    [.extendRights, .interactionAllowed],
                    nil
                )
            }
        }
        switch status {
        case errAuthorizationSuccess:
            return .accepted
        case errAuthorizationCanceled, errAuthorizationDenied, errAuthorizationInteractionNotAllowed:
            return .notAdministrator
        default:
            Self.log.error("could not ask for an administrator's approval (status \(status, privacy: .public))")
            return .approvalUnavailable
        }
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
        // `O_NONBLOCK` so a FIFO in the source's place can't stall the helper on open.
        let sourceFD = sourceName.withCString {
            openat(sourceParentFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard sourceFD >= 0 else { return notMoved(errno) }
        defer { close(sourceFD) }

        // Judged on the open descriptor, which the move and the owner change then use.
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0 else { return notMoved(errno) }
        if let refusal = HelperLinkPolicy.refusal(
            forSourceMode: sourceInfo.st_mode,
            linkCount: sourceInfo.st_nlink,
            isAppBundlePath: source.pathExtension.lowercased() == "app"
        ) {
            Self.log.error("refusing \(source.path, privacy: .public) (type \(sourceInfo.st_mode & S_IFMT, privacy: .public), links \(sourceInfo.st_nlink, privacy: .public))")
            return notMoved(refusal)
        }

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
    /// stays attached to open descriptors, even if the item is renamed in Trash. A
    /// file with a second name keeps its owner, since that name may be a root file
    /// somewhere else (`HelperLinkPolicy`), and the item reads as not fully handed back.
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
                    openat(fileDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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

        guard HelperLinkPolicy.mayChangeOwner(mode: info.st_mode, linkCount: info.st_nlink) else {
            Self.log.error("kept the owner of a file with \(info.st_nlink, privacy: .public) links")
            return false
        }
        if fchown(fileDescriptor, uid, gid) != 0 { succeeded = false }
        return succeeded
    }
}

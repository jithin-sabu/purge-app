import Darwin
import Foundation

/// The root-side implementation of the one privileged operation Purge performs:
/// moving an approved uninstall path into the connecting user's Trash and handing
/// ownership back. Both the source and destination are opened without following
/// symlinks, so another process cannot redirect a checked path while the move runs.
final class HelperService: NSObject, PurgeHelperProtocol {
    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply(PurgeHelperConstants.version)
    }

    func moveToTrash(
        paths: [String],
        withReply reply: @escaping ([String]) -> Void
    ) {
        // The peer identity determines both ownership and destination. Nothing in a
        // root operation should trust a uid, gid, or Trash path supplied by the app.
        guard let connection = NSXPCConnection.current() else {
            NSLog("PurgeHelper: refusing request without a current XPC connection")
            reply([])
            return
        }
        let ownerUID = connection.effectiveUserIdentifier
        let ownerGID = connection.effectiveGroupIdentifier
        guard ownerUID != 0, let homeDirectory = homeDirectory(for: ownerUID) else {
            NSLog("PurgeHelper: refusing request with invalid peer uid %u", ownerUID)
            reply([])
            return
        }

        let trashDirectory = homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
        guard let trashFD = openDirectoryWithoutFollowingSymlinks(trashDirectory),
              validatedTrashDirectory(fileDescriptor: trashFD, ownerUID: ownerUID) else {
            NSLog("PurgeHelper: refusing invalid Trash directory %@", trashDirectory.path)
            reply([])
            return
        }
        defer { close(trashFD) }

        var moved: [String] = []
        for path in paths {
            let source = URL(fileURLWithPath: path)
            guard PurgeHelperConstants.isAllowedUninstallLocation(
                source,
                homeDirectory: homeDirectory
            ) else {
                NSLog("PurgeHelper: refusing source outside uninstall locations %@", source.path)
                continue
            }

            if secureMoveToTrash(
                source,
                trashFD: trashFD,
                uid: ownerUID,
                gid: ownerGID
            ) {
                moved.append(path)
            } else {
                NSLog("PurgeHelper: move failed for %@ (errno %d)", path, errno)
            }
        }
        reply(moved)
    }

    /// Looks up the connecting user's home without consulting the daemon's own
    /// environment, which belongs to root. The returned string is copied while the
    /// re-entrant lookup buffer is alive.
    private func homeDirectory(for uid: uid_t) -> URL? {
        let suggestedSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        let bufferSize = suggestedSize > 0 ? Int(suggestedSize) : 16_384
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: bufferSize)

        let path: String? = buffer.withUnsafeMutableBufferPointer { storage in
            guard let baseAddress = storage.baseAddress else { return nil }
            let status = getpwuid_r(uid, &record, baseAddress, storage.count, &result)
            guard status == 0, result != nil, let directory = record.pw_dir else { return nil }
            return String(cString: directory)
        }
        return path.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    /// Requires the real, user-owned ~/.Trash directory. The descriptor was opened
    /// one path component at a time with `O_NOFOLLOW`, so no component can be a
    /// symlink and its identity stays fixed for this request.
    private func validatedTrashDirectory(fileDescriptor: Int32, ownerUID: uid_t) -> Bool {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == ownerUID
    }

    /// Opens an absolute directory from `/` one component at a time. Holding each
    /// descriptor until the next is open closes the usual check-then-use symlink race.
    private func openDirectoryWithoutFollowingSymlinks(_ url: URL) -> Int32? {
        let components = url.standardizedFileURL.pathComponents.dropFirst()
        var currentFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard currentFD >= 0 else { return nil }

        for component in components {
            let nextFD = component.withCString {
                openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(currentFD)
            guard nextFD >= 0 else { return nil }
            currentFD = nextFD
        }
        return currentFD
    }

    /// Atomically renames the source relative to already-open source and Trash
    /// directories. This means path components cannot be swapped after validation.
    private func secureMoveToTrash(_ source: URL, trashFD: Int32, uid: uid_t, gid: gid_t) -> Bool {
        guard let sourceParentFD = openDirectoryWithoutFollowingSymlinks(source.deletingLastPathComponent()) else {
            return false
        }
        defer { close(sourceParentFD) }

        let sourceName = source.lastPathComponent
        let sourceFD = sourceName.withCString {
            openat(sourceParentFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceFD >= 0 else { return false }
        defer { close(sourceFD) }

        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0 else { return false }
        let sourceType = sourceInfo.st_mode & S_IFMT
        guard sourceType == S_IFDIR || sourceType == S_IFREG else { return false }

        guard renameToUniqueDestination(
            source,
            sourceParentFD: sourceParentFD,
            sourceName: sourceName,
            trashFD: trashFD
        ) else { return false }

        if !chownRecursively(fileDescriptor: sourceFD, uid: uid, gid: gid) {
            NSLog("PurgeHelper: moved %@ but could not update every owner", source.path)
        }
        return true
    }

    /// Renames to a unique Trash name with `RENAME_EXCL`, which makes the collision
    /// check and move one atomic operation. A different process cannot create an item
    /// between those two steps and have it overwritten.
    private func renameToUniqueDestination(
        _ source: URL,
        sourceParentFD: Int32,
        sourceName: String,
        trashFD: Int32
    ) -> Bool {
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
            if result == 0 { return true }
            if errno != EEXIST { return false }
        }
        return false
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

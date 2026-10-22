import Darwin

/// A file or folder as the file system knows it: its volume and inode. Two paths
/// with the same identity name the same item, however they are spelled:
/// `~/Developer` and `~/developer` on the default case-insensitive volume, a link
/// and its target, or `/var` and `/private/var`.
nonisolated struct FileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t

    /// `stat`, so a link is followed. Nil when the path can't be read.
    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

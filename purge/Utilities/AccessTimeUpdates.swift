import Darwin

/// Reads that leave a file's access time alone (#373).
///
/// Large Files shows a file's access time as "Last used", so Purge's own reads
/// must not move it. On APFS a plain `read()` moves it only when it is older
/// than the modification time, which is a file nobody has read since it was
/// written. With updates off for the thread, it doesn't move at all.
nonisolated enum AccessTimeUpdates {
    /// Runs `body` with access-time updates off for this thread, then puts the
    /// thread's policy back.
    ///
    /// This covers `read()` only. A memory-mapped read still moves the access
    /// time, and so does a read in another process, such as Quick Look's: those
    /// go through `FileAccessLedger`. `body` must not suspend, because a task
    /// can resume on another thread and leave this one with updates off for
    /// whatever runs on it next.
    static func off<T>(_ body: () throws -> T) rethrows -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_THREAD)
        let changed = previous >= 0
            && setiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_THREAD, IOPOL_ATIME_UPDATES_OFF) == 0
        defer {
            if changed {
                _ = setiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_THREAD, previous)
            }
        }
        return try body()
    }
}

import Foundation

/// The access times Purge moved itself, so Large Files' "Last used" shows the
/// user's own use and not Purge's (#373).
///
/// "Last used" is a file's access time. On APFS a memory-mapped read moves it
/// every time. Quick Look maps files, in its own processes, so no I/O policy
/// Purge sets can stop it: the preview panel moved the access time of every
/// file it showed, and a thumbnail moves it for images and PDFs. At the next
/// scan those rows read "Today", and the age filter dropped files it had shown
/// a minute before.
///
/// So Purge reads the times before Quick Look reads the file and again after.
/// When they moved, this keeps the earlier access time, and the scan shows it
/// while the file still has exactly the access and modification times Quick
/// Look left. Once the user opens the file, the access time moves again, the entry
/// no longer matches and is dropped, and the scan shows the new time. A file
/// written since is dropped the same way.
///
/// Entries are kept by standardized path, as `LargeFile.path` spells it, in one
/// JSON file in Purge's Application Support folder, because the next scan is
/// often after a relaunch. Times are seconds since 1970, not ISO 8601 dates,
/// which drop the fractions an exact match needs.
nonisolated final class FileAccessLedger: @unchecked Sendable {
    static let shared = FileAccessLedger(
        fileURL: AppSupportFolder.url().appendingPathComponent("access-times.json", isDirectory: false)
    )

    /// When `watch` checks a file after the preview panel shows it. The panel
    /// reads a file as it loads it, and Purge can't tell when that is done.
    static let previewChecks: [TimeInterval] = [1, 3, 10]

    /// One file's times. The two dates match the file's own to within this.
    /// The listing and `URLResourceValues` round nanoseconds differently.
    static let matchTolerance: Double = 0.000_001

    struct Entry: Codable, Equatable, Sendable {
        /// The access time Purge's read left on the file.
        var causedAccess: Double
        /// The access time before Purge first moved it: the user's own.
        var userAccess: Double
        /// The modification time around the read.
        var modification: Double
        /// When the entry was made, so the oldest go first past `maxEntries`.
        var recorded: Double

        /// True while the file still has the times Purge's read left.
        func matches(_ times: Times) -> Bool {
            FileAccessLedger.matches(causedAccess, times.access)
                && FileAccessLedger.matches(modification, times.modification)
        }
    }

    /// A file's access and modification times, in seconds since 1970, as
    /// `lstat` reads them.
    struct Times: Equatable, Sendable {
        let access: Double
        let modification: Double

        init(access: Double, modification: Double) {
            self.access = access
            self.modification = modification
        }

        /// Nil when the file can't be read.
        init?(url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            access = Self.seconds(info.st_atimespec)
            modification = Self.seconds(info.st_mtimespec)
        }

        private static func seconds(_ time: timespec) -> Double {
            Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
        }
    }

    let fileURL: URL
    private let maxEntries: Int
    private let lock = NSLock()
    private var loaded: [String: Entry]?
    /// Records and writes run here, off the caller's thread: the thumbnail
    /// service calls in from the main actor.
    private let queue = DispatchQueue(label: "io.getpurge.file-access-ledger", qos: .utility)
    private var writeScheduled = false
    /// The file the preview panel shows now. Each `watch` replaces it, and
    /// the one before stops checking.
    private var currentWatch: Watch?

    init(fileURL: URL, maxEntries: Int = 5_000) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
    }

    /// The access time the scan shows for the file at `url`: the user's own
    /// when Purge moved it and the file still has the times Purge left, else
    /// `access` as it is.
    func userAccess(of url: URL, access: Date, modification: Date) -> Date {
        if lock.withLock({ loadLocked().isEmpty }) { return access }
        let key = Self.key(url)
        guard let entry = lock.withLock({ loadLocked()[key] }) else { return access }
        if entry.matches(Times(access: access.timeIntervalSince1970, modification: modification.timeIntervalSince1970)) {
            return Date(timeIntervalSince1970: entry.userAccess)
        }
        // The walk read these times a moment ago, and Quick Look may have read
        // the file since. Only the file as it is now can say the user opened
        // it, or it was written, since Purge's read.
        if let current = Times(url: url), entry.matches(current) {
            return Date(timeIntervalSince1970: entry.userAccess)
        }
        lock.withLock {
            var entries = loadLocked()
            guard entries[key] == entry else { return }
            entries[key] = nil
            loaded = entries
            scheduleWriteLocked()
        }
        return access
    }

    /// Notes what a read of Purge's did to the file at `url`, from its times
    /// right before and right after the read.
    func record(url: URL, before: Times?, after: Times?, now: Date = Date()) {
        guard let before, let after else { return }
        let key = Self.key(url)
        queue.async { [self] in
            _ = store(key: key, before: before, after: after, now: now)
        }
    }

    /// Notes what a read in another process does to the file at `url` over
    /// the next few seconds, for a reader that gives no sign when it is done:
    /// the Quick Look panel. Call it before the read starts.
    ///
    /// The checks stop at the first move they keep, so a later change, such as
    /// the user opening the file, is the user's own. They also stop when the
    /// next `watch` starts, because the panel shows one file at a time. The
    /// file before gets one last check then, for a read already done.
    func watch(_ url: URL, checks: [TimeInterval] = previewChecks) {
        let watch = Watch(url: url, key: Self.key(url), before: Times(url: url))
        let previous = lock.withLock {
            defer { currentWatch = watch }
            return currentWatch
        }
        if let previous {
            queue.async { [self] in check(previous) }
        }
        for delay in checks {
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                guard lock.withLock({ currentWatch === watch }) else { return }
                check(watch)
            }
        }
    }

    /// One file the panel showed. Its `isDone` is read and written on `queue`
    /// only.
    private final class Watch: @unchecked Sendable {
        let url: URL
        let key: String
        let before: Times?
        var isDone = false

        init(url: URL, key: String, before: Times?) {
            self.url = url
            self.key = key
            self.before = before
        }
    }

    /// Runs on `queue`.
    private func check(_ watch: Watch) {
        guard !watch.isDone, let before = watch.before, let after = Times(url: watch.url) else { return }
        if store(key: watch.key, before: before, after: after, now: Date()) {
            watch.isDone = true
        }
    }

    /// Keeps the user's access time from before a read that moved it. Runs on
    /// `queue`. False when nothing was kept: the access time didn't move, the
    /// file was written in between, or the file had not been read since it
    /// was written.
    private func store(key: String, before: Times, after: Times, now: Date) -> Bool {
        guard Self.matches(before.modification, after.modification),
              !Self.matches(before.access, after.access) else { return false }
        return lock.withLock {
            var entries = loadLocked()
            // Already kept, by a read that overlapped this one, such as a
            // thumbnail drawn while the panel showed the file.
            if let earlier = entries[key], earlier.matches(after) { return true }
            // A second read after the first: the user's time is still the
            // one from before the first.
            var userAccess = before.access
            if let earlier = entries[key],
               Self.matches(earlier.causedAccess, before.access),
               Self.matches(earlier.modification, before.modification) {
                userAccess = earlier.userAccess
            } else if before.access < before.modification - Self.matchTolerance {
                // Not read since it was written. The user's first plain
                // `read()` would have moved the access time; after Quick
                // Look's it won't, so an entry could outlast the user's own
                // use and make the file look older than it is. Quick Look's
                // time shows instead, which keeps the file out of an age
                // filter rather than in it.
                return false
            }
            entries[key] = Entry(
                causedAccess: after.access,
                userAccess: userAccess,
                modification: after.modification,
                recorded: now.timeIntervalSince1970
            )
            if entries.count > maxEntries {
                let oldest = entries.sorted { $0.value.recorded < $1.value.recorded }
                    .prefix(entries.count - maxEntries)
                for (path, _) in oldest { entries[path] = nil }
            }
            loaded = entries
            scheduleWriteLocked()
            return true
        }
    }

    /// The entry kept for `url`, after every pending record.
    func entry(for url: URL) -> Entry? {
        queue.sync {}
        return lock.withLock { loadLocked()[Self.key(url)] }
    }

    /// Waits for every pending record and writes the file now, if anything
    /// changed. The write that was due later is then skipped.
    func flush() {
        queue.sync { writeNow() }
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    fileprivate static func matches(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < matchTolerance
    }

    // MARK: - Disk

    private func loadLocked() -> [String: Entry] {
        if let loaded { return loaded }
        let disk = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        loaded = disk
        return disk
    }

    /// Several records in a row, as a list full of new thumbnails makes, cost
    /// one write.
    private func scheduleWriteLocked() {
        guard !writeScheduled else { return }
        writeScheduled = true
        queue.asyncAfter(deadline: .now() + 1) { [self] in writeNow() }
    }

    private func writeNow() {
        let entries: [String: Entry]? = lock.withLock {
            guard writeScheduled else { return nil }
            writeScheduled = false
            return loaded
        }
        guard let entries else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: [.atomic])
    }
}

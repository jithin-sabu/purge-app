import Darwin
import Foundation

/// Counts the bytes allocated under folders the way `du -sk` does, but inside
/// Purge and on several threads at once.
///
/// One `du` reads its folders one directory after another on one core. This
/// reads many directories side by side with `getattrlistbulk`, which returns a
/// whole directory's sizes in a few calls. On a 10-core M4 it sized Xcode.app
/// (167,000 entries) in 0.22 s against 0.93 s for `du`, with the same figure.
///
/// It reads only. It opens folders to list them and never follows a link.
///
/// What it counts matches `du -sk`, except for APFS clones (#131):
/// - every entry's allocated blocks, folders and links included, rounded up to
///   a kilobyte for the whole folder;
/// - a file that is a full clone of others counts for an equal share of the
///   blocks they all share, so a set of clones adds up to one copy wherever
///   the copies are, and a clone of a file outside the folder counts for its
///   share only (`SharedBlocks`);
/// - a file with several hard links once per folder asked about (a `du` run
///   counts it once per run; scans gave each folder its own run);
/// - nothing under a folder it cannot open, and no figure at all for a folder
///   asked about that cannot be read or is missing;
/// - a link or a file asked about as itself;
/// - with `staysOnVolume`, a file system mounted inside a folder as the
///   mount's own folder only, as `du -x` does.
nonisolated final class FolderWalker: @unchecked Sendable {
    /// Shared by every scan, so scans running side by side share these threads
    /// rather than each starting their own.
    static let shared = FolderWalker(threadCount: defaultThreadCount)

    /// Most of a walk is spent waiting in the kernel, so a few more threads than
    /// cores keeps the disk busy when the folders are not in memory. On a
    /// 10-core M4, 12 sized Homebrew's Cellar about 15% faster than 8 from cold,
    /// and more gained nothing.
    static let defaultThreadCount = min(12, ProcessInfo.processInfo.activeProcessorCount + 2)

    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var started = false
    private let threadCount: Int

    /// How long one call waits before it gives up on the folders not done
    /// yet, as a `du` run was stopped after 300 s. A read stuck on a dead
    /// network or device mount can't be interrupted; this only stops the scan
    /// from waiting on it.
    private let timeout: TimeInterval

    init(threadCount: Int, timeout: TimeInterval = 300) {
        self.threadCount = threadCount
        self.timeout = timeout
    }

    /// The size of each folder in `roots`, in their order; nil where a folder
    /// could not be read. `onRootDone` hears each folder as it finishes, on a
    /// walker thread, and has returned for every folder before this does.
    /// Blocks until every folder is done, `isCancelled` turns true, or the
    /// timeout passes: then folders not finished yet come back nil.
    func sizes(
        of roots: [String],
        staysOnVolume: Bool,
        isCancelled: @escaping () -> Bool = { Task.isCancelled },
        onRootDone: ((_ index: Int, _ bytes: Int64?) -> Void)? = nil
    ) -> [Int64?] {
        guard !roots.isEmpty else { return [] }
        let request = Request(rootCount: roots.count, counting: .du, staysOnVolume: staysOnVolume, onRootDone: onRootDone)
        walk(roots, request: request, isCancelled: isCancelled)
        return request.results().map { $0?.bytes }
    }

    /// The bytes allocated to the regular files under `root`, and the latest
    /// time one was read or changed, the way `FolderSizing.walkedSize` sums them
    /// file by file: every file counted, hard links and hidden files too, links
    /// never followed, packages walked into. Clones count as `SharedBlocks`
    /// says. Nothing for a root that is not a readable folder.
    func fileTotals(of root: String, isCancelled: () -> Bool = { Task.isCancelled }) -> (bytes: Int64, lastUsed: Date) {
        let request = Request(rootCount: 1, counting: .regularFiles, staysOnVolume: false, onRootDone: nil)
        walk([root], request: request, isCancelled: isCancelled)
        guard let totals = request.results().first ?? nil else { return (0, .distantPast) }
        return (totals.bytes, totals.lastUsed)
    }

    private func walk(_ roots: [String], request: Request, isCancelled: () -> Bool) {
        let startedAt = Date()
        // Even a root's own `lstat` runs on a walker thread: inside a container
        // it can wait on `ContainerAccessGate`, and this thread must stay free
        // to notice a cancel or the timeout.
        let rootJobs = roots.enumerated().map { index, path in
            Job(request: request, root: index, path: path, isRoot: true, rootDevice: 0)
        }
        request.lock.lock()
        for job in rootJobs { request.pending[job.root] = 1 }
        request.lock.unlock()
        enqueue(rootJobs)
        // Waits in short steps so a cancelled caller lets go quickly.
        let deadline = DispatchTime.now() + timeout
        while request.done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if isCancelled() || DispatchTime.now() >= deadline {
                request.cancel()
                break
            }
        }
        ScanPhaseTiming.finish("folder walk", since: startedAt, detail: request.countsDescription(roots: roots.count))
    }

    // MARK: Work queue

    private struct Job {
        let request: Request
        let root: Int
        let path: String
        let isRoot: Bool
        /// The device of the folder asked about, for `staysOnVolume`.
        let rootDevice: dev_t
    }

    private func enqueue(_ new: [Job]) {
        condition.lock()
        if !started {
            started = true
            for index in 0..<threadCount {
                let thread = Thread { [unowned self] in self.work() }
                thread.name = "purge.folder-walker.\(index)"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        }
        jobs.append(contentsOf: new)
        condition.unlock()
        // Wakes only as many threads as there is new work for.
        for _ in 0..<min(new.count, threadCount) {
            condition.signal()
        }
    }

    private func work() {
        let reader = DirectoryReader()
        // The folder this thread reads next: one of the last folder's own, so a
        // thread works down its own branch while the others take the siblings.
        // Threads reading side by side in one folder slowed each other down.
        var own: Job?
        while true {
            let job: Job
            if let next = own {
                job = next
                own = nil
            } else {
                condition.lock()
                while jobs.isEmpty { condition.wait() }
                // Last in, first out: the walk goes deep before wide, so the
                // queue stays short.
                job = jobs.removeLast()
                condition.unlock()
            }

            let request = job.request
            guard !request.isCancelled else {
                request.finish(job.root, read: nil)
                continue
            }
            if job.isRoot {
                var info = stat()
                guard ContainerAccessGate.access(job.path, { lstat(job.path, &info) }) == 0 else {
                    request.finishRootEarly(job.root, bytes: nil)
                    continue
                }
                guard (info.st_mode & S_IFMT) == S_IFDIR else {
                    // `du` asked about a file or a link reports that entry
                    // alone; `walkedSize` finds no files to sum in one.
                    let bytes = request.counting == .du ? Self.kilobyteRounded(blocks: Int64(info.st_blocks)) : 0
                    request.finishRootEarly(job.root, bytes: bytes)
                    continue
                }
            }
            let read = reader.read(
                job.path,
                isRoot: job.isRoot,
                rootDevice: job.rootDevice,
                staysOnVolume: request.staysOnVolume,
                counting: request.counting
            )
            var children = request.finish(job.root, read: read, isRoot: job.isRoot)
            guard let kept = children.popLast() else { continue }
            let device = job.isRoot ? (read?.device ?? 0) : job.rootDevice
            own = Job(request: request, root: job.root, path: kept, isRoot: false, rootDevice: device)
            if !children.isEmpty {
                enqueue(children.map { Job(request: request, root: job.root, path: $0, isRoot: false, rootDevice: device) })
            }
        }
    }

    static func kilobyteRounded(blocks: Int64) -> Int64 {
        // `du -k` prints 512-byte blocks rounded up to whole kilobytes.
        (blocks + 1) / 2 * 1024
    }

    // MARK: One call

    /// What a walk adds up.
    enum Counting {
        /// Every entry's blocks, as `du -sk` counts them.
        case du
        /// The allocated bytes of regular files and their latest use, as
        /// `FolderSizing.walkedSize` counts them.
        case regularFiles
    }

    private final class Request: @unchecked Sendable {
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        let counting: Counting
        let staysOnVolume: Bool
        let onRootDone: ((Int, Int64?) -> Void)?
        var pending: [Int]
        /// 512-byte blocks for `.du`, bytes for `.regularFiles`.
        private var blocks: [Int64]
        private var latest: [Double]
        private var unreadable: [Bool]
        private var finished: [Bool]
        private var linked: [Set<FileKey>]
        private var remaining: Int
        /// `onRootDone` calls under way. `done` waits for them, so a caller
        /// that finishes a stream after the walk loses no folder's report.
        private var callbacksInFlight = 0
        private var signaled = false
        private var cancelled = false
        private var entryCount = 0
        private var directoryCount = 0

        func countsDescription(roots: Int) -> String {
            lock.lock()
            defer { lock.unlock() }
            return "\(roots) roots, \(entryCount) entries, \(directoryCount) folders"
        }

        init(rootCount: Int, counting: Counting, staysOnVolume: Bool, onRootDone: ((Int, Int64?) -> Void)?) {
            self.counting = counting
            self.staysOnVolume = staysOnVolume
            self.onRootDone = onRootDone
            pending = Array(repeating: 0, count: rootCount)
            blocks = Array(repeating: 0, count: rootCount)
            latest = Array(repeating: -.infinity, count: rootCount)
            unreadable = Array(repeating: false, count: rootCount)
            finished = Array(repeating: false, count: rootCount)
            linked = Array(repeating: [], count: rootCount)
            remaining = rootCount
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        /// A folder asked about that is not walked: missing, a file or a link.
        func finishRootEarly(_ root: Int, bytes: Int64?) {
            lock.lock()
            guard !finished[root] else {
                lock.unlock()
                return
            }
            finished[root] = true
            if let bytes {
                blocks[root] = bytes / 512
            } else {
                unreadable[root] = true
            }
            remaining -= 1
            // A cancelled caller has stopped listening.
            guard !cancelled, let onRootDone else {
                signalIfDone()
                lock.unlock()
                return
            }
            callbacksInFlight += 1
            lock.unlock()
            onRootDone(root, bytes)
            callbackReturned()
        }

        /// Signals `done` once every folder is finished and every report has
        /// been heard. Called with `lock` held.
        private func signalIfDone() {
            guard remaining == 0, callbacksInFlight == 0, !signaled else { return }
            signaled = true
            done.signal()
        }

        private func callbackReturned() {
            lock.lock()
            callbacksInFlight -= 1
            signalIfDone()
            lock.unlock()
        }

        /// Adds one directory's reading and returns the folders to read next.
        /// `read` is nil for a directory that could not be opened.
        @discardableResult
        func finish(_ root: Int, read: DirectoryReading?, isRoot: Bool = false) -> [String] {
            lock.lock()
            var children: [String] = []
            if cancelled {
                unreadable[root] = true
            } else if let read {
                if read.isIncomplete { unreadable[root] = true }
                entryCount += read.entryCount
                directoryCount += 1
                blocks[root] += read.blocks
                latest[root] = max(latest[root], read.latest)
                for file in read.linkedFiles where linked[root].insert(file.key).inserted {
                    blocks[root] += file.blocks
                }
                children = read.folders
                pending[root] += children.count
            } else if isRoot {
                unreadable[root] = true
            }
            pending[root] -= 1
            var doneBytes: Int64?? = nil
            if pending[root] == 0, !finished[root] {
                finished[root] = true
                remaining -= 1
                // A cancelled caller has stopped listening.
                if !cancelled, onRootDone != nil {
                    doneBytes = .some(unreadable[root] ? nil : total(root))
                    callbacksInFlight += 1
                }
            }
            signalIfDone()
            lock.unlock()
            if let doneBytes {
                onRootDone?(root, doneBytes)
                callbackReturned()
            }
            return children
        }

        private func total(_ root: Int) -> Int64 {
            switch counting {
            case .du: return FolderWalker.kilobyteRounded(blocks: blocks[root])
            case .regularFiles: return blocks[root]
            }
        }

        func results() -> [(bytes: Int64, lastUsed: Date)?] {
            lock.lock()
            defer { lock.unlock() }
            return blocks.indices.map { index in
                guard finished[index], !unreadable[index] else { return nil }
                let lastUsed = latest[index].isFinite ? Date(timeIntervalSince1970: latest[index]) : .distantPast
                return (total(index), lastUsed)
            }
        }
    }
}

/// One directory's own blocks, the blocks of its files with a single link, the
/// files with several links (counted once per folder by the caller), and the
/// folders inside it.
nonisolated struct DirectoryReading {
    var device: dev_t
    var blocks: Int64
    var linkedFiles: [(key: FileKey, blocks: Int64)]
    var folders: [String]
    var entryCount = 0
    /// The latest access or change of a regular file in it, in seconds since
    /// 1970; only `.regularFiles` reads it.
    var latest: Double = -.infinity
    /// The listing failed part way, so the folder's figure would be short.
    var isIncomplete = false
}

nonisolated struct FileKey: Hashable {
    let device: Int32
    let fileID: UInt64
}

/// How much of a file's allocated space deleting it gives back on APFS (#131).
///
/// The allocated size counts blocks a file shares with its clones. A copy made
/// with `clonefile` (Finder's Duplicate, `cp -c`, Xcode's build copies) reports
/// the full size while it takes no new space, so adding up allocated sizes
/// promised more than a clean could free: DerivedData on one Mac summed to
/// 5.06 GB file by file and 4.09 GB with this rule.
///
/// - A file that shares all its blocks with `n` full clones, itself included,
///   counts `allocated / n`. The clones add up to one copy wherever they are,
///   and a clone of something outside the scan counts only its share.
/// - A file that shares only some of its blocks has no count of who it shares
///   them with, so it counts in full, as before.
/// - A purgeable file counts in full. macOS gives its space back by itself, but
///   only `volumeAvailableCapacityForImportantUsage` counts it as free; `df`
///   and System Settings don't, and a clean still moves it to the Trash. At 0
///   it hid real rows: a folder holding only purgeable files fell out of App
///   Caches, and a downloaded iCloud bundle out of Large Files.
///
/// It reads `EF_SHARES_ALL_BLOCKS` and the clone count, never
/// `ATTR_CMNEXT_PRIVATESIZE`, which walked a folder about 70% slower. On a
/// volume that reports neither, such as HFS+ or exFAT, every file counts its
/// allocated size.
nonisolated enum SharedBlocks {
    /// The extended attributes asked for in each listing: flags and clone
    /// count, or flags alone, or nothing, whichever this kernel takes. A bit
    /// it doesn't know fails the whole listing with `EINVAL`.
    static let attributes: attrgroup_t = {
        let full = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) | attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT)
        for candidate in [full, attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)] where accepts(candidate) {
            return candidate
        }
        return 0
    }()

    private static func accepts(_ forkattr: attrgroup_t) -> Bool {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = forkattr
        var buffer = [UInt8](repeating: 0, count: 64)
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)
        return buffer.withUnsafeMutableBytes { getattrlist("/", &list, $0.baseAddress, $0.count, options) } == 0
    }

    /// `flags` and `cloneCount` are nil when the volume did not report them.
    static func countedBytes(allocated: Int64, flags: UInt64?, cloneCount: UInt32?) -> Int64 {
        guard let flags, flags & UInt64(EF_SHARES_ALL_BLOCKS) != 0, let cloneCount, cloneCount > 1 else {
            return allocated
        }
        let clones = Int64(cloneCount)
        return (allocated + clones - 1) / clones
    }

    /// One file read on its own, without following a link: `allocated` when
    /// the volume says nothing or the file can't be read.
    static func countedBytes(ofFileAt path: String, allocated: Int64) -> Int64 {
        state(ofFileAt: path).countedBytes(allocated: allocated)
    }
}

/// One file's shared blocks, read on their own or from a listing: Large Files
/// rows and Duplicates (#376), and the sizes a contents clean books.
nonisolated extension SharedBlocks {
    /// What the volume reports about one file's shared blocks. Both are nil
    /// when it reports nothing.
    struct FileState {
        var flags: UInt64?
        var cloneCount: UInt32?

        static let unknown = FileState(flags: nil, cloneCount: nil)

        /// The file shares all its blocks with at least one other full clone,
        /// so moving it to the Trash gives back nothing while they stay.
        var isFullClone: Bool {
            guard let flags, flags & UInt64(EF_SHARES_ALL_BLOCKS) != 0, let cloneCount else { return false }
            return cloneCount > 1
        }

        /// A full clone's share of `allocated`, and all of it for any other
        /// file, a purgeable one included.
        func countedBytes(allocated: Int64) -> Int64 {
            SharedBlocks.countedBytes(allocated: allocated, flags: flags, cloneCount: cloneCount)
        }
    }

    /// Reads one file's flags and clone count with `getattrlist`, without
    /// following a link. `.unknown` when it can't be read.
    static func state(ofFileAt path: String) -> FileState {
        guard attributes != 0 else { return .unknown }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = attributes
        // Length, returned set, then a UInt64 and a UInt32.
        var buffer = [UInt8](repeating: 0, count: 64)
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)
        return buffer.withUnsafeMutableBytes { raw -> FileState in
            guard let base = raw.baseAddress,
                  getattrlist(path, &list, base, raw.count, options) == 0 else { return .unknown }
            var field = base + 4
            let returned = field.loadUnaligned(as: attribute_set_t.self)
            field += MemoryLayout<attribute_set_t>.size
            return readState(from: &field, returned: returned)
        }
    }

    /// Reads the flags and clone count where `field` points, in the order the
    /// kernel packs them, and moves `field` past them.
    static func readState(from field: inout UnsafeMutableRawPointer, returned: attribute_set_t) -> FileState {
        var state = FileState.unknown
        if returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 {
            state.flags = field.loadUnaligned(as: UInt64.self)
            field += MemoryLayout<UInt64>.size
        }
        if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT) != 0 {
            state.cloneCount = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        return state
    }
}

/// Lists one directory with `getattrlistbulk`. One per walker thread, since it
/// keeps a buffer.
nonisolated final class DirectoryReader {
    private static let bufferSize = 256 * 1024
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: DirectoryReader.bufferSize, alignment: 16)
    private var attributes = DirectoryReader.attributes(withTimes: false)
    private var attributesWithTimes = DirectoryReader.attributes(withTimes: true)
    private var plainAttributes = DirectoryReader.attributes(withTimes: false, extended: false)
    private var plainAttributesWithTimes = DirectoryReader.attributes(withTimes: true, extended: false)

    private static func attributes(withTimes: Bool, extended: Bool = true) -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // `ATTR_CMN_ERROR` reports an entry whose attributes can't be read in
        // that entry, which is then skipped. Without it, one such entry fails
        // the whole call.
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
            | attrgroup_t(ATTR_CMN_ERROR)
        if withTimes {
            list.commonattr |= attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ACCTIME)
        }
        list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        list.forkattr = extended ? SharedBlocks.attributes : 0
        return list
    }

    /// `FSOPT_ATTR_CMN_EXTENDED` when `SharedBlocks` asks for anything, so
    /// `forkattr` is read as the extended common attributes.
    private static let options = SharedBlocks.attributes == 0 ? UInt64(0) : UInt64(FSOPT_ATTR_CMN_EXTENDED)

    deinit {
        buffer.deallocate()
    }

    /// nil when the directory can't be opened or stat'ed; `du` counts nothing
    /// for such a folder, not even its own blocks.
    func read(
        _ path: String,
        isRoot: Bool,
        rootDevice: dev_t,
        staysOnVolume: Bool,
        counting: FolderWalker.Counting = .du
    ) -> DirectoryReading? {
        let fd = Self.openDirectory(path)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        // Another file system mounted here: `du -x` counts the mount's own
        // folder and does not go in.
        if staysOnVolume, !isRoot, info.st_dev != rootDevice {
            return DirectoryReading(device: info.st_dev, blocks: Int64(info.st_blocks), linkedFiles: [], folders: [])
        }
        // `.regularFiles` counts files only, not the folders that hold them.
        let ownBlocks = counting == .du ? Int64(info.st_blocks) : 0
        var reading = DirectoryReading(device: info.st_dev, blocks: ownBlocks, linkedFiles: [], folders: [])
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var extended = Self.options != 0
        while true {
            let count: Int32
            switch (counting, extended) {
            case (.du, true): count = getattrlistbulk(fd, &attributes, buffer, Self.bufferSize, Self.options)
            case (.du, false): count = getattrlistbulk(fd, &plainAttributes, buffer, Self.bufferSize, 0)
            case (.regularFiles, true):
                count = getattrlistbulk(fd, &attributesWithTimes, buffer, Self.bufferSize, Self.options)
            case (.regularFiles, false):
                count = getattrlistbulk(fd, &plainAttributesWithTimes, buffer, Self.bufferSize, 0)
            }
            if count < 0, errno == EINTR { continue }
            // A file system that refuses the extended attributes before listing
            // anything is listed without them, and its files count in full.
            if count < 0, errno == EINVAL, extended, reading.entryCount == 0 {
                extended = false
                continue
            }
            if count < 0 {
                reading.isIncomplete = true
                break
            }
            guard count > 0 else { break }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.load(as: UInt32.self))
                parse(entry, prefix: prefix, counting: counting, into: &reading)
                reading.entryCount += 1
                entry += length
            }
        }
        return reading
    }

    /// Reads the fields in the order `getattrlistbulk` packs them: common
    /// attributes by bit, then file attributes by bit, then the extended
    /// common attributes by bit.
    private func parse(
        _ entry: UnsafeMutableRawPointer,
        prefix: String,
        counting: FolderWalker.Counting,
        into reading: inout DirectoryReading
    ) {
        var field = entry + 4
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size
        // Right after the returned set. An entry that could not be read is
        // left out, as `du` leaves out an entry it can't stat.
        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            guard field.loadUnaligned(as: UInt32.self) == 0 else { return }
            field += MemoryLayout<UInt32>.size
        }
        var nameStart: UnsafeMutableRawPointer?
        if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
            let reference = field.loadUnaligned(as: attrreference_t.self)
            nameStart = field + Int(reference.attr_dataoffset)
            field += MemoryLayout<attrreference_t>.size
        }
        var device: Int32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            device = field.loadUnaligned(as: Int32.self)
            field += MemoryLayout<Int32>.size
        }
        var type: UInt32 = VNON.rawValue
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            type = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        var latest = -Double.infinity
        if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            latest = max(latest, Self.seconds(field.loadUnaligned(as: timespec.self)))
            field += MemoryLayout<timespec>.size
        }
        if returned.commonattr & attrgroup_t(ATTR_CMN_ACCTIME) != 0 {
            latest = max(latest, Self.seconds(field.loadUnaligned(as: timespec.self)))
            field += MemoryLayout<timespec>.size
        }
        var fileID: UInt64 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            fileID = field.loadUnaligned(as: UInt64.self)
            field += MemoryLayout<UInt64>.size
        }
        if type == VDIR.rawValue {
            // Its own blocks are counted when it is opened, as `du` counts a
            // folder it could read.
            guard let nameStart else { return }
            let name = String(cString: nameStart.assumingMemoryBound(to: CChar.self))
            reading.folders.append(prefix + name)
            return
        }
        var links: UInt32 = 1
        if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            links = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        var allocated: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            allocated = field.loadUnaligned(as: Int64.self)
            field += MemoryLayout<Int64>.size
        }
        let counted = SharedBlocks.readState(from: &field, returned: returned).countedBytes(allocated: max(0, allocated))
        if counting == .regularFiles {
            guard type == VREG.rawValue else { return }
            reading.blocks += counted
            reading.latest = max(reading.latest, latest)
            return
        }
        let blocks = (counted + 511) / 512
        if links > 1 {
            reading.linkedFiles.append((FileKey(device: device, fileID: fileID), blocks))
        } else {
            reading.blocks += blocks
        }
    }

    private static func seconds(_ time: timespec) -> Double {
        Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    /// Opens a directory without following a link in its last component. A path
    /// past `PATH_MAX` is opened one component at a time, as `du` reaches deep
    /// folders by changing into them.
    static func openDirectory(_ path: String) -> Int32 {
        ContainerAccessGate.access(path) { openDirectoryUngated(path) }
    }

    private static func openDirectoryUngated(_ path: String) -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = open(path, flags)
        while fd < 0, errno == EINTR { fd = open(path, flags) }
        guard fd < 0, errno == ENAMETOOLONG else { return fd }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        for (index, component) in components.enumerated() {
            guard current >= 0 else { return -1 }
            let isLast = index == components.count - 1
            let next = openat(current, String(component), isLast ? flags : (O_RDONLY | O_DIRECTORY | O_CLOEXEC))
            close(current)
            current = next
        }
        return current
    }
}

/// One entry of a folder, as `DirectoryListing` reads it.
nonisolated struct ListingEntry {
    let name: String
    let isDirectory: Bool
    let isRegularFile: Bool
    /// The `UF_HIDDEN` flag, which hides an entry without a leading dot.
    let isHiddenFlagSet: Bool
    let allocatedBytes: Int64
    /// What the volume says about the blocks the entry shares with clones
    /// (#376).
    let sharedBlocks: SharedBlocks.FileState
    /// The data's length, `fileSize` in `URLResourceValues`.
    let logicalBytes: Int64
    let accessDate: Date
    let modificationDate: Date

    /// What `FileManager`'s `.skipsHiddenFiles` leaves out.
    var isHidden: Bool { name.hasPrefix(".") || isHiddenFlagSet }
}

/// A folder's entries read with `getattrlistbulk`: names, kinds, allocated
/// sizes and dates in a few calls per folder. `FileManager` builds a URL and a
/// cache for every entry; for a sweep of hundreds of thousands of entries that
/// was most of the time.
nonisolated enum DirectoryListing {
    private static let bufferSize = 64 * 1024

    /// nil when the folder cannot be opened. Links are listed as neither file
    /// nor folder and never followed.
    static func entries(of path: String) -> [ListingEntry]? {
        let fd = DirectoryReader.openDirectory(path)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ACCTIME)
            | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_ERROR)
        list.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE) | attrgroup_t(ATTR_FILE_DATALENGTH)
        list.forkattr = SharedBlocks.attributes
        let options = SharedBlocks.attributes == 0 ? UInt64(0) : UInt64(FSOPT_ATTR_CMN_EXTENDED)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var entries: [ListingEntry] = []
        while true {
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, options)
            if count < 0, errno == EINTR { continue }
            // A listing that fails part way is not passed off as the folder.
            if count < 0 { return nil }
            guard count > 0 else { break }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.load(as: UInt32.self))
                if let listed = parse(entry) { entries.append(listed) }
                entry += length
            }
        }
        return entries
    }

    /// Fields in the order `getattrlistbulk` packs them: common attributes by
    /// bit, then file attributes by bit, then the extended common attributes
    /// by bit.
    private static func parse(_ entry: UnsafeMutableRawPointer) -> ListingEntry? {
        var field = entry + 4
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size
        // Right after the returned set; an entry that could not be read is
        // left out.
        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            guard field.loadUnaligned(as: UInt32.self) == 0 else { return nil }
            field += MemoryLayout<UInt32>.size
        }
        guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let reference = field.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        field += MemoryLayout<attrreference_t>.size
        var type: UInt32 = VNON.rawValue
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            type = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        var modified = Date.distantPast
        if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            modified = date(field.loadUnaligned(as: timespec.self))
            field += MemoryLayout<timespec>.size
        }
        var accessed = Date.distantPast
        if returned.commonattr & attrgroup_t(ATTR_CMN_ACCTIME) != 0 {
            accessed = date(field.loadUnaligned(as: timespec.self))
            field += MemoryLayout<timespec>.size
        }
        var flags: UInt32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            flags = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        var allocated: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            allocated = field.loadUnaligned(as: Int64.self)
            field += MemoryLayout<Int64>.size
        }
        var logical: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
            logical = field.loadUnaligned(as: Int64.self)
            field += MemoryLayout<Int64>.size
        }
        let sharedBlocks = SharedBlocks.readState(from: &field, returned: returned)
        return ListingEntry(
            name: name,
            isDirectory: type == VDIR.rawValue,
            isRegularFile: type == VREG.rawValue,
            isHiddenFlagSet: flags & UInt32(UF_HIDDEN) != 0,
            allocatedBytes: max(0, allocated),
            sharedBlocks: sharedBlocks,
            logicalBytes: max(0, logical),
            accessDate: accessed,
            modificationDate: modified
        )
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }
}


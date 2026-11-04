import Darwin
import Foundation

/// Directory access for the root helper. Both the app and the helper compile this
/// file, so the app's tests can cover the exact code the helper runs.
nonisolated enum HelperDirectory {
    /// Opens an absolute directory from `/` one component at a time. Holding each
    /// descriptor until the next is open closes the usual check-then-use symlink race.
    ///
    /// Every component is opened with `O_SEARCH`, which asks only to pass through the
    /// directory, never to list it. That matters for `~/.Trash`: macOS privacy
    /// protection refuses to let a process without Full Disk Access read it, and that
    /// includes this root helper, so an `O_RDONLY` open fails with `EPERM`. Moving an
    /// item in with `renameat` needs no read access, so a search-only descriptor is
    /// all the helper needs, and it is less than it had before.
    ///
    /// The path is used exactly as given. A `.` or `..` component is refused rather
    /// than resolved, so the walk can never climb out of the folder that was checked.
    /// (Standardizing the URL instead would also rewrite `/private/var` as `/var`, a
    /// symlink this walk then refuses.)
    static func openWithoutFollowingSymlinks(_ url: URL) -> Int32? {
        let path = url.path
        guard path.hasPrefix("/") else { return nil }
        let components = URL(fileURLWithPath: path).pathComponents.dropFirst()
        guard !components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            return nil
        }
        var currentFD = open("/", O_SEARCH | O_CLOEXEC)
        guard currentFD >= 0 else { return nil }

        for component in components {
            let nextFD = component.withCString {
                openat(currentFD, $0, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
            }
            close(currentFD)
            guard nextFD >= 0 else { return nil }
            currentFD = nextFD
        }
        return currentFD
    }
}

/// Lets the root helper quit once nobody needs it, so the next request starts a fresh
/// copy from the app bundle that is installed now.
///
/// Without this the helper ran until the Mac restarted. An update replaces the
/// helper's file on disk, but the old process kept answering, and the app refused
/// every answer because it could not verify the signature of a program whose file
/// was gone. launchd starts the helper again on the next request, so quitting costs
/// nothing.
///
/// A hold is an open connection or a move in progress. The helper may quit only after
/// it has had no holds for `idleInterval`. A move keeps its own hold, so a slow
/// ownership hand-back is never cut short even if the app has stopped waiting.
nonisolated final class HelperIdleTracker: @unchecked Sendable {
    typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void

    private let lock = NSLock()
    private var holds = 0
    /// Bumped on every change, so a timer armed before the latest change does nothing.
    private var generation = 0
    /// Set, under the lock, the moment the helper commits to quitting. From then on
    /// `acquire()` refuses, so no connection or move can start in the gap before the
    /// process exits.
    private var exiting = false
    private let idleInterval: TimeInterval
    private let schedule: Scheduler
    private let onIdle: @Sendable () -> Void

    init(
        idleInterval: TimeInterval,
        schedule: @escaping Scheduler = { delay, work in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        },
        onIdle: @escaping @Sendable () -> Void
    ) {
        self.idleInterval = idleInterval
        self.schedule = schedule
        self.onIdle = onIdle
    }

    /// Arms the first timer, so a helper that launchd started but nobody ever reached
    /// still quits.
    func start() {
        lock.lock()
        let armed = armLocked()
        lock.unlock()
        armed()
    }

    /// Adds a hold. Returns `false` once the helper has committed to quitting: the
    /// caller must then turn the connection away, and the app's next request starts a
    /// fresh helper.
    @discardableResult
    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !exiting else { return false }
        holds += 1
        generation += 1
        return true
    }

    func release() {
        lock.lock()
        holds = max(0, holds - 1)
        let armed = holds == 0 ? armLocked() : nil
        lock.unlock()
        armed?()
    }

    /// Records a new idle period and returns the call that schedules its timer. The
    /// caller runs it after unlocking, so a scheduler that fires at once cannot
    /// deadlock on `lock`.
    private func armLocked() -> () -> Void {
        generation += 1
        let armedGeneration = generation
        return { [self] in
            schedule(idleInterval) { [self] in
                lock.lock()
                let commit = !exiting && holds == 0 && generation == armedGeneration
                if commit { exiting = true }
                lock.unlock()
                if commit { onIdle() }
            }
        }
    }
}

/// Whether an account is in the local `admin` group. Both the app and the helper
/// compile this file, so Settings and the root helper always agree on who is an
/// administrator (#314).
nonisolated enum AdministratorMembership {
    /// True only when `userName`, whose primary group is `primaryGID`, is a member of
    /// the local `admin` group. Any lookup that fails says no.
    static func includes(userName: String, primaryGID: gid_t) -> Bool {
        guard let adminGID = adminGroupID() else { return false }
        var capacity: Int32 = 32
        // A short buffer makes `getgrouplist` return -1, so it grows and asks
        // again. A list that never fits says no.
        while capacity <= 4_096 {
            var groups = [Int32](repeating: 0, count: Int(capacity))
            var count = capacity
            let status = userName.withCString {
                getgrouplist($0, Int32(bitPattern: primaryGID), &groups, &count)
            }
            if status == 0 {
                return groups.prefix(Int(count)).contains(Int32(bitPattern: adminGID))
            }
            capacity = max(capacity * 2, count)
        }
        return false
    }

    /// Whether the account running this process is an administrator. Settings reads
    /// it to say whether removing an admin-locked app will ask for a password.
    static func currentUserIsAdministrator() -> Bool {
        guard let account = UserRecord.lookUp(uid: getuid()) else { return false }
        return includes(userName: account.name, primaryGID: account.primaryGID)
    }

    /// The gid of the local `admin` group, read from its directory record. The
    /// record lists the group's members, so a big group needs a bigger buffer:
    /// `ERANGE` grows it and asks again, up to 1 MB.
    private static func adminGroupID() -> gid_t? {
        let suggestedSize = sysconf(_SC_GETGR_R_SIZE_MAX)
        var bufferSize = suggestedSize > 0 ? Int(suggestedSize) : 16_384
        while bufferSize <= 1_048_576 {
            var record = group()
            var result: UnsafeMutablePointer<group>?
            var buffer = [CChar](repeating: 0, count: bufferSize)
            let status = buffer.withUnsafeMutableBufferPointer { storage -> Int32 in
                guard let baseAddress = storage.baseAddress else { return -1 }
                return getgrnam_r("admin", &record, baseAddress, storage.count, &result)
            }
            if status == ERANGE {
                bufferSize *= 2
                continue
            }
            guard status == 0, result != nil else { return nil }
            return record.gr_gid
        }
        return nil
    }
}

/// An account's directory record, read once per request.
nonisolated struct UserRecord {
    let name: String
    let primaryGID: gid_t
    let home: URL

    /// Looks up the account without consulting this process's environment, which
    /// belongs to root in the helper. The strings are copied while the re-entrant
    /// lookup buffer is alive.
    static func lookUp(uid: uid_t) -> UserRecord? {
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
            return UserRecord(
                name: String(cString: namePointer),
                primaryGID: record.pw_gid,
                home: URL(fileURLWithPath: String(cString: directory), isDirectory: true).standardizedFileURL
            )
        }
    }
}

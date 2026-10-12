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

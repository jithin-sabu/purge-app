import Foundation

/// Runs a blocking read for each item on several threads at once and returns
/// the results in the items' order. For independent reads only, such as code
/// signatures or folder listings: `transform` must not depend on another
/// item's result.
///
/// Blocks the calling thread until every item is done, so call it off the main
/// actor. At most `width` items run at once, never more than there are cores;
/// a walk of the disk passes a small width so a scan leaves the rest of the Mac
/// room to work.
nonisolated enum ConcurrentMap {
    static func values<T, R>(
        _ items: [T],
        width: Int = ProcessInfo.processInfo.activeProcessorCount,
        _ transform: (T) -> R
    ) -> [R] {
        let lanes = min(max(1, width), items.count)
        guard lanes > 1 else { return items.map(transform) }
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        let lock = NSLock()
        // Each lane takes the next item when it is free, so one slow item holds
        // up only its own lane.
        DispatchQueue.concurrentPerform(iterations: lanes) { _ in
            while true {
                lock.lock()
                let index = next
                next += 1
                lock.unlock()
                guard index < items.count else { return }
                let value = transform(items[index])
                lock.lock()
                results[index] = value
                lock.unlock()
            }
        }
        return results.map { $0! }
    }
}

/// A stop signal that work on `ConcurrentMap`'s threads can read. There
/// `Task.isCancelled` is always false, since those threads run no task, so the
/// caller raises this from `withTaskCancellationHandler`'s `onCancel` instead.
nonisolated final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }
}

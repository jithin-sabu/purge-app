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
    /// `outer` runs each lane on a thread of its own instead of through
    /// `concurrentPerform`, for a map whose items run maps of their own: GCD
    /// runs a `concurrentPerform` nested inside another with little or no
    /// parallelism. Plain maps keep `concurrentPerform`, which shares the cores
    /// out between maps that run at the same time.
    static func values<T, R>(
        _ items: [T],
        width: Int = ProcessInfo.processInfo.activeProcessorCount,
        outer: Bool = false,
        _ transform: (T) -> R
    ) -> [R] {
        let lanes = min(max(1, width), items.count)
        guard lanes > 1 else { return items.map(transform) }
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        let lock = NSLock()
        // Each lane takes the next item when it is free, so one slow item holds
        // up only its own lane.
        let lane: (Int) -> Void = { _ in
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
        if outer {
            runLanes(lanes, lane)
        } else {
            DispatchQueue.concurrentPerform(iterations: lanes, execute: lane)
        }
        return results.map { $0! }
    }

    /// Runs `body` for lanes `0..<count` side by side and returns when all are
    /// done. Lane 0 runs on the calling thread, the rest on queues of their
    /// own, so a `concurrentPerform` inside a lane is not nested in another.
    fileprivate static func runLanes(_ count: Int, _ body: (Int) -> Void) {
        guard count > 1 else {
            body(0)
            return
        }
        withoutActuallyEscaping(body) { body in
            // The queued blocks hold the closure unretained: a block can outlive
            // its `leave()` for a moment, and a retained copy then would still be
            // alive when this returns, which `withoutActuallyEscaping` traps on.
            // The one retain is dropped after every lane is done.
            let lanes = Unmanaged.passRetained(LaneBody(body))
            let group = DispatchGroup()
            // At the priority of the calling thread, as `concurrentPerform` ran.
            let qos = DispatchQoS(qosClass: DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .default, relativePriority: 0)
            for lane in 1..<count {
                group.enter()
                DispatchQueue(label: "purge.concurrent-map", qos: qos).async {
                    lanes.takeUnretainedValue().run(lane)
                    group.leave()
                }
            }
            body(0)
            group.wait()
            lanes.release()
        }
    }
}

private nonisolated final class LaneBody {
    let run: (Int) -> Void

    init(_ run: @escaping (Int) -> Void) {
        self.run = run
    }
}

extension ConcurrentMap {
    /// Runs two independent blocking reads side by side and returns both,
    /// each free to run maps of its own. Blocks the calling thread until both
    /// are done.
    static func both<A, B>(_ first: () -> A, _ second: () -> B) -> (A, B) {
        var a: A?
        var b: B?
        let lock = NSLock()
        runLanes(2) { index in
            if index == 0 {
                let value = first()
                lock.lock()
                a = value
                lock.unlock()
            } else {
                let value = second()
                lock.lock()
                b = value
                lock.unlock()
            }
        }
        lock.lock()
        defer { lock.unlock() }
        return (a!, b!)
    }
}

/// One step of a folder that `ConcurrentMap.tree` reads: something found, or
/// a subfolder to read next.
nonisolated enum TreeStep<Value, Child> {
    case value(Value)
    case child(Child)
}

extension ConcurrentMap {
    /// Reads a tree on several threads at once: `read` lists one folder and
    /// returns its steps in listing order. A thread takes the next folder as
    /// soon as it is free, so no folder waits for the others at its depth.
    /// Returns every value in the order one depth-first walk meets them, and
    /// hands them to `onValues` in that order as soon as every folder before
    /// them is read, so a caller can show them while the walk goes on.
    /// `onValues` runs on a reading thread with the walk's lock held, so it
    /// must be quick. Blocks the calling thread; once `isCancelled` turns true
    /// it stops and returns the values handed out so far.
    static func tree<Item, Value>(
        _ roots: [Item],
        width: Int,
        isCancelled: () -> Bool,
        onValues: (([Value]) -> Void)? = nil,
        read: (Item) -> [TreeStep<Value, Item>]
    ) -> [Value] {
        // Each node's steps, with children replaced by their node's index; nil
        // until the node is read.
        var nodes: [[TreeStep<Value, Int>]?] = Array(repeating: nil, count: roots.count)
        var items: [Item] = roots
        var queue = Array(roots.indices.reversed())
        var busy = 0
        let condition = NSCondition()

        // Where a depth-first walk over the nodes read so far has got to. It
        // stops at the first node not read yet, so values come out in walk
        // order however the reads finish.
        var values: [Value] = []
        var path: [(node: Int, step: Int)] = []
        var nextRoot = 0
        func advance() -> [Value] {
            var ready: [Value] = []
            while true {
                if path.isEmpty {
                    guard nextRoot < roots.count else { break }
                    path.append((nextRoot, 0))
                    nextRoot += 1
                }
                let (node, step) = path[path.count - 1]
                guard let steps = nodes[node] else { break }
                guard step < steps.count else {
                    path.removeLast()
                    continue
                }
                path[path.count - 1].step += 1
                switch steps[step] {
                case .value(let value): ready.append(value)
                case .child(let child): path.append((child, 0))
                }
            }
            return ready
        }

        DispatchQueue.concurrentPerform(iterations: max(1, width)) { _ in
            while true {
                condition.lock()
                while queue.isEmpty, busy > 0 { condition.wait() }
                guard !isCancelled(), let index = queue.popLast() else {
                    condition.broadcast()
                    condition.unlock()
                    return
                }
                let item = items[index]
                busy += 1
                condition.unlock()

                let steps = read(item)

                condition.lock()
                var resolved: [TreeStep<Value, Int>] = []
                resolved.reserveCapacity(steps.count)
                var added: [Int] = []
                for step in steps {
                    switch step {
                    case .value(let value):
                        resolved.append(.value(value))
                    case .child(let child):
                        let childIndex = items.count
                        items.append(child)
                        nodes.append(nil)
                        resolved.append(.child(childIndex))
                        added.append(childIndex)
                    }
                }
                nodes[index] = resolved
                // Reversed, so the first subfolder is read next.
                queue.append(contentsOf: added.reversed())
                busy -= 1
                // Handed out with the lock held, so batches never overtake
                // one another.
                let ready = advance()
                values += ready
                if !ready.isEmpty { onValues?(ready) }
                if !added.isEmpty || busy == 0 { condition.broadcast() }
                condition.unlock()
            }
        }
        return values
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

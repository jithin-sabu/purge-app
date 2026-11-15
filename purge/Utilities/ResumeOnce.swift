import Foundation

/// Resumes a checked continuation once, for whichever caller gets there first: a
/// reply, an error handler or a timeout, often on different queues. Later calls
/// do nothing (#185).
nonisolated final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

extension ResumeOnce where Value == Void {
    func resume() {
        resume(returning: ())
    }
}

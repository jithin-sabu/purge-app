import Foundation
@testable import Purge

/// Stands in for the Trash in `FileDeleter` tests, so nothing a test makes ends
/// up in the user's own Trash (#171). It moves nothing: it records each item it
/// was asked to trash, and whether any call came on the main thread.
///
/// Pass `trash` to `FileDeleter(trash:)`.
final class FakeTrash: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var calledOnMainThread = false
    private var failuresLeft = 0

    /// Makes the next `count` trash calls fail with a write error macOS gives no
    /// reason for, the kind the helper fallback picks up, so a test can see a
    /// failure and then a retry (#174).
    func failNextCalls(_ count: Int) {
        lock.lock()
        failuresLeft = count
        lock.unlock()
    }

    var trash: FileDeleter.Trasher {
        { [self] url in
            lock.lock()
            defer { lock.unlock() }
            if Thread.isMainThread { calledOnMainThread = true }
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: nil)
            }
            urls.append(url)
        }
    }

    /// Standardized paths, in the order they were trashed.
    var trashedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return urls.map(\.standardizedFileURL.path)
    }

    var sawMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return calledOnMainThread
    }
}

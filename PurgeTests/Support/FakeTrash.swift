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

    var trash: FileDeleter.Trasher {
        { [self] url in
            lock.lock()
            defer { lock.unlock() }
            urls.append(url)
            if Thread.isMainThread { calledOnMainThread = true }
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

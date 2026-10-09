import Foundation

/// A UserDefaults suite for one test that leaves nothing behind on disk.
///
/// A named suite lives in ~/Library/Preferences, and removing its domain is not
/// enough: cfprefsd keeps an empty plist there, and if the file is deleted it
/// writes it back about ten seconds later. So the suite name is a path inside a
/// temporary folder of its own, and `remove()` deletes the whole folder.
///
/// Hold it as a stored property of the test suite: Swift Testing makes a fresh
/// suite instance for every test, so `deinit` cleans up when the test ends. A
/// test that needs a second suite makes a local one and calls `remove()` in a
/// `defer`. Either way the cleanup must come after the last write, because a
/// write after `remove()` puts the folder back.
final class ThrowawayDefaults {
    /// The suite name, which is also the domain name for `persistentDomain(forName:)`.
    let name: String
    let defaults: UserDefaults
    private let folder: URL

    init() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-tests-defaults-\(UUID().uuidString)", isDirectory: true)
        name = folder.appendingPathComponent("defaults").path
        defaults = UserDefaults(suiteName: name)!
    }

    deinit {
        remove()
    }

    func remove() {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }
}

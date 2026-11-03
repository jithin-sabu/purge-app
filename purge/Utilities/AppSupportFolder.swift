import Foundation

/// Purge's folder in Application Support, where its stores keep their files.
/// While the tests run it is the run's scratch folder: the tests run inside a
/// hosted copy of the app, and nothing they write may reach the user's own
/// files (#185).
nonisolated enum AppSupportFolder {
    static func url() -> URL {
        if TestHost.isActive() { return TestHost.supportDirectory() }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.getpurge.app", isDirectory: true)
    }
}

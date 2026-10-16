import Foundation

/// The unit tests run inside a hosted copy of the app, which shares the user's
/// real defaults and files. Anything that acts on those at launch (a scheduled
/// clean, the deleted-apps agent, recorded access state) checks this first.
nonisolated enum TestHost {
    static func isActive(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let testHostKeys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
        return testHostKeys.contains { environment[$0] != nil }
    }

    /// Where stores keep the files they would keep in Application Support while
    /// the tests run: one temporary folder per test run, shared by every test in it.
    static func supportDirectory() -> URL {
        runSupportDirectory
    }

    /// A later run can get the same process ID, and an earlier run's folder can still
    /// be there, so the name also carries an ID made once per run.
    private static let runSupportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "PurgeTestSupport-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )
}

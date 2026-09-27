import Foundation

/// The unit tests run inside a hosted copy of the app, which shares the user's
/// real defaults and files. Anything that acts on those at launch (a scheduled
/// clean, the deleted-apps agent, recorded access state) checks this first.
nonisolated enum TestHost {
    static func isActive(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let testHostKeys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
        return testHostKeys.contains { environment[$0] != nil }
    }
}

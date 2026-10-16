import Foundation
import Testing
@testable import Purge

/// The tests run inside a hosted copy of the app. A store that kept its file in
/// Application Support there would read and change the user's own records (#171).
@Suite("Stores keep what the tests write out of the user's files")
struct TestHostStoreIsolationTests {
    private let realSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("io.getpurge.app", isDirectory: true)

    @Test
    func exclusionsAndSafetyChoicesLiveInTheTestRunsScratchFolder() {
        #expect(TestHost.isActive())
        let scratch = TestHost.supportDirectory().standardizedFileURL
        for file in [ExcludedPathsStore.fileURL(), UserOverridesStore.fileURL()] {
            #expect(file.deletingLastPathComponent().standardizedFileURL == scratch)
            #expect(!file.standardizedFileURL.path.hasPrefix(realSupport.standardizedFileURL.path + "/"))
        }
    }
}

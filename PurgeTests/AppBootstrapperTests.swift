import Foundation
import Testing
@testable import Purge

/// The tests run inside a hosted copy of the app, on the user's real defaults
/// and files. Nothing that acts at launch may run there (#181): the launch scan
/// walks the real disk, the registrar rewrites the real reminders, and Sparkle
/// checks for updates in the middle of a test run.
@Suite("Startup work stays out of the unit-test host")
struct AppBootstrapperTests {
    private static let testHostEnvironments: [[String: String]] = [
        ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
        ["XCTestBundlePath": "/tmp/PurgeTests.xctest"],
        ["XCTestSessionIdentifier": "ABC"],
    ]

    /// Only the test host skips the bootstrap. A build run from Xcode is a real
    /// launch, and a launch that did nothing would leave the menu bar dead.
    @Test
    func onlyTheTestHostSkipsTheBootstrap() {
        #expect(AppBootstrapper.runsAtLaunch(environment: [:]))
        #expect(AppBootstrapper.runsAtLaunch(environment: ["HOME": "/Users/x"]))
        for environment in Self.testHostEnvironments {
            #expect(!AppBootstrapper.runsAtLaunch(environment: environment))
        }
        #expect(!AppBootstrapper.runsAtLaunch(environment: ProcessInfo.processInfo.environment))
    }

    /// Sparkle starts on every real launch and never in the test host.
    @Test
    func onlyTheTestHostLeavesSparkleStopped() {
        #expect(PurgeUpdater.startsUpdater(environment: [:]))
        #expect(PurgeUpdater.startsUpdater(environment: ["HOME": "/Users/x"]))
        for environment in Self.testHostEnvironments {
            #expect(!PurgeUpdater.startsUpdater(environment: environment))
        }
        #expect(!PurgeUpdater.startsUpdater(environment: ProcessInfo.processInfo.environment))
    }

    /// The gates agree with the ones the registrar and the deleted-apps watcher
    /// already use, so one launch is either wholly real or wholly a test.
    @Test
    func launchGatesAgree() {
        for environment in Self.testHostEnvironments + [[:], ["HOME": "/Users/x"]] {
            let expected = !TestHost.isActive(environment: environment)
            #expect(AppBootstrapper.runsAtLaunch(environment: environment) == expected)
            #expect(PurgeUpdater.startsUpdater(environment: environment) == expected)
            #expect(ScheduledCleaningRegistrar.cleansOnActivation(environment: environment) == expected)
            #expect(RemovedAppMonitor.managesLiveAgent(environment: environment) == expected)
        }
    }
}

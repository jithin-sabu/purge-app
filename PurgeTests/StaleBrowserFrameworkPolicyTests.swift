import Foundation
import Testing
@testable import Purge

@Suite("Stale Chromium frameworks stay put while a running browser still loads them")
struct StaleBrowserFrameworkPolicyTests {
    private let chrome = "/Applications/Google Chrome.app"
    private let versions = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions"
    private let loaded = "152.0.7977.76"
    private let unused = "153.0.8010.48"
    private let current = "153.0.8010.50"

    private var helperExecutable: String {
        "\(versions)/\(loaded)/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
    }

    private var runningChrome: [DeletionSafetyPolicy.RunningProcessPaths] {
        [
            .init(
                bundlePath: chrome,
                executablePath: "\(chrome)/Contents/MacOS/Google Chrome"
            ),
            .init(
                bundlePath: "\(versions)/\(loaded)/Helpers/Google Chrome Helper.app",
                executablePath: helperExecutable
            )
        ]
    }

    @Test
    func frameworkVersionComesFromTheVersionsComponent() {
        #expect(DeletionSafetyPolicy.frameworkVersion(in: "\(versions)/\(loaded)") == loaded)
        #expect(DeletionSafetyPolicy.frameworkVersion(in: helperExecutable) == loaded)
        #expect(DeletionSafetyPolicy.frameworkVersion(in: "\(versions)/Current") == nil)
        #expect(DeletionSafetyPolicy.frameworkVersion(in: "\(chrome)/Contents/MacOS/Google Chrome") == nil)
    }

    @Test
    func browserAppPathIsTheOuterBundleNotTheHelper() {
        #expect(DeletionSafetyPolicy.browserAppPath(containing: "\(versions)/\(loaded)") == chrome)
        #expect(DeletionSafetyPolicy.browserAppPath(containing: helperExecutable) == chrome)
    }

    @Test
    func loadedHelperVersionIsRefusedAndUnusedLeftoverIsOffered() {
        let (running, versionsInUse) = DeletionSafetyPolicy.loadedFrameworkVersions(
            inAppPath: chrome,
            processes: runningChrome
        )
        #expect(running)
        #expect(versionsInUse == [loaded])

        #expect(!DeletionSafetyPolicy.shouldOfferStaleFrameworkVersion(
            version: loaded,
            currentVersion: current,
            loadedVersions: versionsInUse,
            appIsRunning: running
        ))
        #expect(DeletionSafetyPolicy.shouldOfferStaleFrameworkVersion(
            version: unused,
            currentVersion: current,
            loadedVersions: versionsInUse,
            appIsRunning: running
        ))
        #expect(!DeletionSafetyPolicy.shouldOfferStaleFrameworkVersion(
            version: current,
            currentVersion: current,
            loadedVersions: versionsInUse,
            appIsRunning: running
        ))
    }

    @Test
    func runningBrowserWithNoVisibleVersionHidesEveryLeftover() {
        let processes = [
            DeletionSafetyPolicy.RunningProcessPaths(
                bundlePath: chrome,
                executablePath: "\(chrome)/Contents/MacOS/Google Chrome"
            )
        ]
        let (running, versionsInUse) = DeletionSafetyPolicy.loadedFrameworkVersions(
            inAppPath: chrome,
            processes: processes
        )
        #expect(running)
        #expect(versionsInUse.isEmpty)
        for version in [loaded, unused] {
            #expect(!DeletionSafetyPolicy.shouldOfferStaleFrameworkVersion(
                version: version,
                currentVersion: current,
                loadedVersions: versionsInUse,
                appIsRunning: running
            ))
        }
    }

    @Test
    func quitBrowserStillOffersLeftoversOtherThanCurrent() {
        let (running, versionsInUse) = DeletionSafetyPolicy.loadedFrameworkVersions(
            inAppPath: chrome,
            processes: []
        )
        #expect(!running)
        #expect(DeletionSafetyPolicy.shouldOfferStaleFrameworkVersion(
            version: loaded,
            currentVersion: current,
            loadedVersions: versionsInUse,
            appIsRunning: running
        ))
        #expect(!DeletionSafetyPolicy.shouldOfferStaleFrameworkVersion(
            version: current,
            currentVersion: current,
            loadedVersions: versionsInUse,
            appIsRunning: running
        ))
    }
}

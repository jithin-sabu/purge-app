import Foundation
import Testing
@testable import Purge

@Suite("FirstRunGate install detection")
struct FirstRunGateTests {
    /// Each test gets its own defaults suite so the persistent domain starts genuinely empty.
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "io.getpurge.tests.firstrun.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private func emptySupportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("firstrun-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A clean install with no traces on disk gets onboarding")
    func freshInstallShowsOnboarding() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let decision = FirstRunGate.resolve(
            defaults: defaults,
            domainName: name,
            supportDirectory: emptySupportDirectory(),
            appVersion: "1.2.0"
        )

        #expect(decision == .freshInstall)
        #expect(defaults.bool(forKey: FirstRunGate.onboardingCompletedKey) == false)
        #expect(defaults.string(forKey: FirstRunGate.firstSeenVersionKey) == "1.2.0")
    }

    @Test("An update from a pre-onboarding build skips onboarding", arguments: [
        "appearance.mode",
        "totalRecoveredBytes",
        "scheduledClean.enabled",
        "filter.appCaches",
    ])
    func priorDefaultsKeySkipsOnboarding(existingKey: String) {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("whatever", forKey: existingKey)

        let decision = FirstRunGate.resolve(
            defaults: defaults,
            domainName: name,
            supportDirectory: emptySupportDirectory(),
            appVersion: "1.2.0"
        )

        #expect(decision == .existingInstall)
        #expect(defaults.bool(forKey: FirstRunGate.onboardingCompletedKey))
    }

    @Test("Application Support files alone mark the install as existing")
    func supportFilesSkipOnboarding() throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let support = emptySupportDirectory()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try Data("{}".utf8).write(
            to: support.appendingPathComponent("cleanup_history.json", isDirectory: false)
        )

        let decision = FirstRunGate.resolve(
            defaults: defaults,
            domainName: name,
            supportDirectory: support,
            appVersion: "1.2.0"
        )

        #expect(decision == .existingInstall)
        #expect(defaults.bool(forKey: FirstRunGate.onboardingCompletedKey))
    }

    @Test("A decision already on disk is never overwritten", arguments: [true, false])
    func existingFlagIsPreserved(completed: Bool) {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(completed, forKey: FirstRunGate.onboardingCompletedKey)

        let decision = FirstRunGate.resolve(
            defaults: defaults,
            domainName: name,
            supportDirectory: emptySupportDirectory(),
            appVersion: "9.9.9"
        )

        #expect(decision == .alreadyResolved)
        #expect(defaults.bool(forKey: FirstRunGate.onboardingCompletedKey) == completed)
        #expect(defaults.string(forKey: FirstRunGate.firstSeenVersionKey) == nil)
    }

    /// Quitting mid-onboarding must resume onboarding, not fall through to the "existing install"
    /// branch on the strength of defaults the flow itself wrote.
    @Test("Interrupted onboarding resumes on the next launch")
    func interruptedOnboardingResumes() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(
            FirstRunGate.resolve(
                defaults: defaults,
                domainName: name,
                supportDirectory: emptySupportDirectory(),
                appVersion: "1.2.0"
            ) == .freshInstall
        )
        defaults.set(true, forKey: "onboarding.pendingCelebration")

        let relaunch = FirstRunGate.resolve(
            defaults: defaults,
            domainName: name,
            supportDirectory: emptySupportDirectory(),
            appVersion: "1.2.0"
        )

        #expect(relaunch == .alreadyResolved)
        #expect(defaults.bool(forKey: FirstRunGate.onboardingCompletedKey) == false)
    }
}

import Foundation
import Testing
@testable import Purge

/// The Language row writes `AppleLanguages`, the entry System Settings writes
/// for Purge under Language & Region > Applications (#465). These drive it
/// against a throwaway suite, never Purge's real preferences.
@MainActor
@Suite("Language picker")
struct AppLanguagePreferenceTests {
    private let suite = ThrowawayDefaults()
    private let shipped = ["ar", "en", "ru", "tr", "zh-Hans"]

    private func makePreference(
        launchLanguage: String = "en",
        macLanguages: [String] = ["en-US"]
    ) -> AppLanguagePreference {
        AppLanguagePreference(
            defaults: suite.defaults,
            domainName: suite.name,
            shipped: shipped,
            launchLanguage: launchLanguage,
            systemLanguages: { macLanguages }
        )
    }

    private var saved: [String]? {
        suite.defaults.persistentDomain(forName: suite.name)?[AppLanguagePreference.defaultsKey] as? [String]
    }

    @Test("No entry is System default")
    func noEntryIsSystemDefault() {
        let preference = makePreference()
        #expect(preference.choice == .system)
        #expect(!preference.needsRelaunch)
    }

    @Test("Picking a language saves only that language")
    func pickingSavesOneLanguage() {
        let preference = makePreference()
        preference.select(.language("ru"))
        #expect(saved == ["ru"])
        #expect(preference.choice == .language("ru"))
    }

    @Test("System default removes the entry")
    func systemDefaultRemovesEntry() {
        let preference = makePreference()
        preference.select(.language("tr"))
        preference.select(.system)
        #expect(saved == nil)
        #expect(preference.choice == .system)
    }

    @Test("A change made in System Settings shows after refresh")
    func refreshReadsOutsideChange() {
        let preference = makePreference()
        // System Settings writes a region too.
        suite.defaults.set(["zh-Hans-CN"], forKey: AppLanguagePreference.defaultsKey)
        preference.refresh()
        #expect(preference.choice == .language("zh-Hans"))
    }

    @Test("A saved language Purge doesn't ship shows as the one macOS falls back to")
    func unshippedLanguageShowsFallback() {
        #expect(AppLanguagePreference.choice(saved: ["fr"], shipped: shipped) == .language("en"))
        #expect(AppLanguagePreference.choice(saved: ["fr", "tr"], shipped: shipped) == .language("tr"))
        #expect(AppLanguagePreference.choice(saved: [], shipped: shipped) == .system)
    }

    @Test("Relaunch is needed only when the next launch loads another language")
    func relaunchOnlyWhenLanguageChanges() {
        let preference = makePreference(launchLanguage: "en", macLanguages: ["en-GB"])
        preference.select(.language("en"))
        #expect(!preference.needsRelaunch)
        preference.select(.language("ar"))
        #expect(preference.needsRelaunch)
        #expect(preference.resolvedLanguage == "ar")
        preference.select(.system)
        #expect(!preference.needsRelaunch)
    }

    @Test("System default resolves through the Mac's own languages")
    func systemDefaultFollowsMac() {
        let preference = makePreference(launchLanguage: "ru", macLanguages: ["tr-TR", "en-US"])
        #expect(preference.resolvedLanguage == "tr")
        #expect(preference.needsRelaunch)
    }

    @Test("The menu lists System default, then each language")
    func optionsOrder() {
        let preference = makePreference()
        #expect(preference.options == [.system] + shipped.map(AppLanguageChoice.language))
    }

    @Test("Each language is named in itself, with a capital")
    func nativeNames() {
        #expect(AppLanguagePreference.nativeName(of: "en") == "English")
        #expect(AppLanguagePreference.nativeName(of: "ru") == "Русский")
        #expect(AppLanguagePreference.nativeName(of: "tr") == "Türkçe")
        #expect(AppLanguagePreference.nativeName(of: "zh-Hans") == "简体中文")
        #expect(AppLanguagePreference.nativeName(of: "ar") == "العربية")
    }

    @Test("The shipped list is the bundle's languages without Base")
    func shippedFromBundle() {
        // The test host is Purge itself.
        let languages = AppLanguagePreference.shippedLanguages(in: .main)
        #expect(!languages.contains("Base"))
        #expect(languages == languages.sorted())
        for language in shipped {
            #expect(languages.contains(language))
        }
    }

    @Test("The relaunch waiter gets the pid and path as arguments, not in the script")
    func waiterArguments() {
        let path = "/Applications/Purge \"$(touch x)\".app"
        let arguments = AppRelauncher.waiterArguments(pid: 4242, bundlePath: path)
        #expect(arguments.count == 5)
        #expect(arguments[0] == "-c")
        #expect(!arguments[1].contains(path))
        #expect(!arguments[1].contains("4242"))
        #expect(arguments[2] == "4242")
        #expect(arguments[3] == path)
        #expect(arguments[4] == AppRelauncher.launchArgument)
    }

    @Test("Only the copy a relaunch opens carries the marker")
    func relaunchMarker() {
        #expect(AppRelauncher.isRelaunch(arguments: ["/Applications/Purge.app/Contents/MacOS/Purge", AppRelauncher.launchArgument]))
        #expect(!AppRelauncher.isRelaunch(arguments: ["/Applications/Purge.app/Contents/MacOS/Purge"]))
        // The program path is never read as the marker.
        #expect(!AppRelauncher.isRelaunch(arguments: [AppRelauncher.launchArgument]))
        // The test host was not opened by a relaunch.
        #expect(!AppRelauncher.launchedByRelaunch)
    }
}

/// Relaunch Now waits for every scan, not only the full cache scan (#465).
/// Drives the real store and queue with held fake scans.
@MainActor
@Suite("Relaunch waits for scans")
struct RelaunchWaitsForScansTests {
    @Test("An idle store has no scan running")
    func idleStoreIsNotScanning() {
        let fake = FakeScans()
        let store = fake.makeStore()
        #expect(!store.isAnyScanRunning)
        fake.cleanUp()
    }

    @Test("A Large Files scan counts, though it is not the full cache scan")
    func largeFilesScanCounts() async {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        fake.holdsFullAccessSteps = true
        store.requestScan(.largeFiles)
        #expect(await eventually { fake.log == ["step largeFiles"] })
        #expect(!store.isScanningAll)
        #expect(store.isAnyScanRunning)

        fake.holdsFullAccessSteps = false
        fake.finishHeldSteps()
        #expect(await eventually { !store.isAnyScanRunning })
        fake.cleanUp()
    }
}

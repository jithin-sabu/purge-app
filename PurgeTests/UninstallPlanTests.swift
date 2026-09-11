import Foundation
import Testing
@testable import Purge

/// Two installs can share one bundle id (Xcode and Xcode-beta), which resolves to
/// the same bundle-id-keyed leftovers. The plan totals must count a shared path
/// once, so the review sheet and the deletion denominator are not doubled.
@Suite("Uninstall plan totals deduplicate shared paths")
struct UninstallPlanTests {
    private let safe = SafetyInfo(
        level: .safe,
        headline: "",
        explanation: "",
        recoverySteps: "",
        reinstallCommand: nil
    )

    private func makeApp(bundlePath: String) -> InstalledApp {
        InstalledApp(
            name: "Xcode",
            bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
            bundleID: "com.apple.dt.Xcode",
            bundleSizeBytes: 0,
            isRunning: false
        )
    }

    private func item(path: String, bytes: Int64, reason: MatchReason) -> UninstallItem {
        UninstallItem(
            path: URL(fileURLWithPath: path),
            sizeBytes: bytes,
            category: reason == .appBundle ? .bundle : .preferences,
            safetyInfo: safe,
            matchReason: reason,
            isSelected: true
        )
    }

    @Test
    func sharedLeftoverPathIsCountedOnce() {
        // Two distinct bundles, each with its own bundle item, plus a shared
        // bundle-id-keyed preference selected under both.
        let sharedPref = "/Users/x/Library/Preferences/com.apple.dt.Xcode.plist"
        let appA = UninstallAppPlan(
            app: makeApp(bundlePath: "/Applications/Xcode.app"),
            items: [
                item(path: "/Applications/Xcode.app", bytes: 1_000, reason: .appBundle),
                item(path: sharedPref, bytes: 50, reason: .bundleID)
            ]
        )
        let appB = UninstallAppPlan(
            app: makeApp(bundlePath: "/Applications/Xcode-beta.app"),
            items: [
                item(path: "/Applications/Xcode-beta.app", bytes: 2_000, reason: .appBundle),
                item(path: sharedPref, bytes: 50, reason: .bundleID)
            ]
        )
        let plan = UninstallPlan(id: "x", apps: [appA, appB])

        // Three unique paths: the two bundles plus the one shared pref.
        #expect(plan.totalSelectedItems == 3)
        // 1000 + 2000 + 50, not 50 twice.
        #expect(plan.totalSelectedBytes == 3_050)
    }

    @Test
    func uniquePathsAreAllCounted() {
        let appA = UninstallAppPlan(
            app: makeApp(bundlePath: "/Applications/Xcode.app"),
            items: [item(path: "/Applications/Xcode.app", bytes: 1_000, reason: .appBundle)]
        )
        let appB = UninstallAppPlan(
            app: makeApp(bundlePath: "/Applications/Other.app"),
            items: [item(path: "/Applications/Other.app", bytes: 2_000, reason: .appBundle)]
        )
        let plan = UninstallPlan(id: "y", apps: [appA, appB])

        #expect(plan.totalSelectedItems == 2)
        #expect(plan.totalSelectedBytes == 3_000)
    }
}

import Foundation
import Testing
@testable import Purge

/// The uninstaller checks the helper before sending it a move. A helper that never
/// answers must be reported as not ready, or the move waits out its five-minute
/// timeout while the cleaning screen sits frozen.
@MainActor
@Suite("Privileged helper reconcile")
struct HelperReconcilerTests {
    /// Scripted helper: each probe returns the next answer, `nil` for silence.
    final class FakeHelper {
        var answers: [String?]
        /// Whether macOS reports the helper as enabled, before and after a reload.
        var enabledBeforeReload: Bool
        var enabledAfterReload: Bool
        var probes = 0
        var reloads = 0

        init(answers: [String?], enabledBeforeReload: Bool = true, enabledAfterReload: Bool = true) {
            self.answers = answers
            self.enabledBeforeReload = enabledBeforeReload
            self.enabledAfterReload = enabledAfterReload
        }

        var isEnabled: Bool { reloads == 0 ? enabledBeforeReload : enabledAfterReload }

        func probe() -> String? {
            probes += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    private func reconcile(_ helper: FakeHelper, mayReload: Bool = true) async -> HelperReconcileOutcome {
        await HelperReconciler.reconcile(
            isEnabled: { helper.isEnabled },
            expectedVersion: "7",
            probe: { helper.probe() },
            reload: mayReload ? { helper.reloads += 1 } : nil
        )
    }

    @Test("A helper that stays silent after a reload is not ready")
    func silentAfterReloadIsUnresponsive() async {
        let helper = FakeHelper(answers: [nil, nil])
        #expect(await reconcile(helper) == .unresponsive)
        #expect(helper.reloads == 1)
        #expect(helper.probes == 2)
    }

    @Test("A helper that answers after a reload is ready")
    func answersAfterReloadIsReady() async {
        let helper = FakeHelper(answers: [nil, "7"])
        #expect(await reconcile(helper) == .ready)
        #expect(helper.reloads == 1)
    }

    @Test("A current helper is ready without a reload")
    func currentHelperIsReady() async {
        let helper = FakeHelper(answers: ["7"])
        #expect(await reconcile(helper) == .ready)
        #expect(helper.reloads == 0)
        #expect(helper.probes == 1)
    }

    @Test("A disabled helper is never probed")
    func disabledHelperIsNotProbed() async {
        let helper = FakeHelper(answers: ["7"], enabledBeforeReload: false)
        #expect(await reconcile(helper) == .notEnabled)
        #expect(helper.probes == 0)
    }

    @Test("An old helper is reloaded and confirmed")
    func staleHelperIsReloaded() async {
        let helper = FakeHelper(answers: ["6", "7"])
        #expect(await reconcile(helper) == .ready)
        #expect(helper.reloads == 1)
    }

    @Test("An old helper that survives the reload is not ready")
    func staleHelperThatStaysIsNotReady() async {
        let helper = FakeHelper(answers: ["6", "6"])
        #expect(await reconcile(helper) == .staleVersion)
    }

    @Test("A helper that goes silent after reloading an old version is unresponsive")
    func silentAfterStaleReloadIsUnresponsive() async {
        let helper = FakeHelper(answers: ["6", nil])
        #expect(await reconcile(helper) == .unresponsive)
    }

    @Test("A reload that loses the approval asks for setup, not a retry")
    func reloadThatLosesApprovalIsNotEnabled() async {
        let helper = FakeHelper(answers: [nil, "7"], enabledAfterReload: false)
        #expect(await reconcile(helper) == .notEnabled)
        #expect(helper.reloads == 1)
        // The setup screen takes over, so there is no point asking again.
        #expect(helper.probes == 1)
    }

    @Test("Only one reload per check, so a dead helper costs two probes at most")
    func atMostOneReload() async {
        let helper = FakeHelper(answers: [nil, nil, nil, nil])
        _ = await reconcile(helper)
        #expect(helper.reloads == 1)
        #expect(helper.probes == 2)
    }

    @Test("A copy that may not reload reports the problem and leaves the helper alone")
    func noReloadWhenNotAllowed() async {
        let silent = FakeHelper(answers: [nil, "7"])
        #expect(await reconcile(silent, mayReload: false) == .unresponsive)
        #expect(silent.reloads == 0)
        #expect(silent.probes == 1)

        let stale = FakeHelper(answers: ["6", "7"])
        #expect(await reconcile(stale, mayReload: false) == .staleVersion)
        #expect(stale.reloads == 0)
    }

    // MARK: Which copy may repair the registration

    private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    private func mayRepair(_ path: String, environment: [String: String] = [:]) -> Bool {
        PrivilegedHelperManager.mayRepairRegistration(
            bundleURL: URL(fileURLWithPath: path, isDirectory: true),
            homeDirectory: home,
            environment: environment
        )
    }

    @Test("Only an installed copy may re-register the helper by itself")
    func onlyInstalledCopyRepairs() {
        #expect(mayRepair("/Applications/Purge.app"))
        #expect(mayRepair("/Applications/Utilities/Purge.app"))
        #expect(mayRepair("/Users/example/Applications/Purge.app"))

        // Each of these would tie the root helper to a copy that later disappears.
        #expect(!mayRepair("/Users/example/Library/Developer/Xcode/DerivedData/purge-abc/Build/Products/Debug/Purge.app"))
        #expect(!mayRepair("/Volumes/Purge/Purge.app"))
        #expect(!mayRepair("/private/var/folders/xy/T/AppTranslocation/1234/d/Purge.app"))
        #expect(!mayRepair("/Users/example/Downloads/Purge.app"))
        #expect(!mayRepair("/ApplicationsBackup/Purge.app"))
    }

    @Test("The unit-test host never re-registers the helper")
    func testHostNeverRepairs() {
        #expect(!mayRepair("/Applications/Purge.app", environment: ["XCTestConfigurationFilePath": "/tmp/x"]))
    }
}


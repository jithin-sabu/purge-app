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
        var probes = 0
        var reloads = 0
        var reinstalls = 0

        init(answers: [String?]) { self.answers = answers }

        func probe() -> String? {
            probes += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    private func reconcile(_ helper: FakeHelper, isEnabled: Bool = true) async -> HelperReconcileOutcome {
        await HelperReconciler.reconcile(
            isEnabled: isEnabled,
            expectedVersion: "7",
            probe: { helper.probe() },
            reload: { helper.reloads += 1 },
            reinstall: { helper.reinstalls += 1 }
        )
    }

    @Test("A helper that stays silent after a reload is not ready")
    func silentAfterReloadIsUnresponsive() async {
        let helper = FakeHelper(answers: [nil, nil])
        #expect(await reconcile(helper) == .unresponsive)
        #expect(helper.reloads == 1)
        #expect(helper.probes == 2)
        #expect(helper.reinstalls == 0)
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
        let helper = FakeHelper(answers: ["7"])
        #expect(await reconcile(helper, isEnabled: false) == .notEnabled)
        #expect(helper.probes == 0)
    }

    @Test("An old helper is reinstalled and confirmed")
    func staleHelperIsReinstalled() async {
        let helper = FakeHelper(answers: ["6", "7"])
        #expect(await reconcile(helper) == .ready)
        #expect(helper.reinstalls == 1)
    }

    @Test("An old helper that survives reinstalling is not ready")
    func staleHelperThatStaysIsNotReady() async {
        let helper = FakeHelper(answers: ["6", "6"])
        #expect(await reconcile(helper) == .staleVersion)
    }

    @Test("A helper that goes silent after reinstalling is unresponsive")
    func silentAfterReinstallIsUnresponsive() async {
        let helper = FakeHelper(answers: ["6", nil])
        #expect(await reconcile(helper) == .unresponsive)
    }

    @Test("An old helper found after a reload is still reinstalled")
    func staleAfterReloadIsReinstalled() async {
        let helper = FakeHelper(answers: [nil, "6", "7"])
        #expect(await reconcile(helper) == .ready)
        #expect(helper.reloads == 1)
        #expect(helper.reinstalls == 1)
    }
}

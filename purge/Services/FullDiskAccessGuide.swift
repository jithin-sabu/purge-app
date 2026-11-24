import Foundation

/// Opens Full Disk Access in System Settings with the guide panel beside it, and
/// waits for the grant (#450). Every place that asks for access goes through
/// here: Look Deeper in onboarding and in the main window, and a clean that
/// failed for lack of access.
///
/// macOS grants access to a running process without telling it, so the only way
/// to notice is to keep probing. The probe runs off the main actor, once a
/// second, for at most `wait`. On a grant the guide shows its check and each
/// caller's `onGranted` runs once. Not Now on the guide, or `cancel()`, ends the
/// wait without running them.
@MainActor
final class FullDiskAccessGuide {
    static let shared = FullDiskAccessGuide(
        panel: .shared,
        probe: { await Task.detached(priority: .utility) { PermissionChecker().hasFullDiskAccess() }.value },
        openPane: openFullDiskAccessSettings
    )

    /// As long as the other guides wait (`AppleIntelligenceModelStore.settingsWait`).
    nonisolated static let wait: TimeInterval = 10 * 60

    private let panel: SettingsGuidePanel
    private let probe: @Sendable () async -> Bool
    private let openPane: () -> Void
    private let pollInterval: Duration
    private let limit: TimeInterval
    private var task: Task<Void, Never>?
    private var grantHandlers: [() -> Void] = []

    init(
        panel: SettingsGuidePanel,
        probe: @escaping @Sendable () async -> Bool,
        openPane: @escaping () -> Void,
        pollInterval: Duration = .seconds(1),
        limit: TimeInterval = wait
    ) {
        self.panel = panel
        self.probe = probe
        self.openPane = openPane
        self.pollInterval = pollInterval
        self.limit = limit
    }

    var isWaiting: Bool { task != nil }

    /// Opens the pane and shows the guide. A second call while one wait runs adds
    /// its `onGranted` to the same wait.
    func open(onGranted: @escaping () -> Void = {}) {
        openPane()
        grantHandlers.append(onGranted)
        panel.show(.fullDiskAccess) { [weak self] in self?.stopWaiting(hideGuide: false) }
        guard task == nil else { return }
        task = Task { [weak self] in await self?.waitForGrant() }
    }

    /// The asking screen went away: stop waiting and close the guide.
    func cancel() {
        guard isWaiting else { return }
        stopWaiting(hideGuide: true)
    }

    private func waitForGrant() async {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            let granted = await probe()
            guard !Task.isCancelled else { return }
            if granted {
                let handlers = grantHandlers
                grantHandlers = []
                task = nil
                panel.finish(.fullDiskAccess)
                handlers.forEach { $0() }
                return
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
        }
        stopWaiting(hideGuide: true)
    }

    private func stopWaiting(hideGuide: Bool) {
        task?.cancel()
        task = nil
        grantHandlers = []
        if hideGuide { panel.hide(.fullDiskAccess) }
    }
}

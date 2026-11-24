import Foundation

/// Opens Full Disk Access in System Settings with the guide panel beside it, and
/// waits for the grant (#450). Every place that asks for access goes through
/// here: Look Deeper in onboarding and in the main window, and a clean that
/// failed for lack of access.
///
/// macOS grants access to a running process without telling it, so the only way
/// to notice is to keep probing. The probe runs off the main actor, once a
/// second, for at most `wait`. On a grant the guide shows its check and each
/// caller's `onGranted` runs once. Not Now on the guide ends the wait without
/// running them. Each caller cancels only its own request: the wait and the
/// guide end with the last one.
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
    private var grantHandlers: [(request: Request, run: () -> Void)] = []

    /// One caller's place in the wait, for `cancel(_:)`.
    struct Request: Hashable {
        let id = UUID()
    }

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
    @discardableResult
    func open(onGranted: @escaping () -> Void = {}) -> Request {
        openPane()
        let request = Request()
        grantHandlers.append((request, onGranted))
        panel.show(.fullDiskAccess, owner: self) { [weak self] in self?.stopWaiting(hideGuide: false) }
        if task == nil {
            task = Task { [weak self] in await self?.waitForGrant() }
        }
        return request
    }

    /// The screen that made `request` went away: its `onGranted` never runs.
    /// When no other caller waits, the wait stops and the guide closes. A
    /// request that already ran or ended does nothing.
    func cancel(_ request: Request) {
        guard let index = grantHandlers.firstIndex(where: { $0.request == request }) else { return }
        grantHandlers.remove(at: index)
        if grantHandlers.isEmpty { stopWaiting(hideGuide: true) }
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
                panel.finish(.fullDiskAccess, owner: self)
                handlers.forEach { $0.run() }
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
        if hideGuide { panel.hide(.fullDiskAccess, owner: self) }
    }
}

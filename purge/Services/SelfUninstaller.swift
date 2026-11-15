import Combine
import Foundation

/// The background parts Uninstall Purge turns off (#330). Each is listed only
/// when it is on, read from macOS when the sheet opens.
enum SelfUninstallPart: String, CaseIterable, Sendable {
    case deletedAppsWatcher
    case adminHelper
    case finderService
    case cleanupReminder
    case loginItem
}

/// One background part, behind a seam so tests never touch `SMAppService`,
/// launchd, pbs or the notification center.
@MainActor
protocol SelfUninstallPartControl {
    var part: SelfUninstallPart { get }
    /// Whether the part is on. `thorough` is the check after turning it off: it
    /// may take a few seconds (the watcher waits for a ping to go unanswered).
    func isOn(thorough: Bool) async -> Bool
    func turnOff() async
}

/// Moves Purge's own files, through `SelfUninstallPolicy`.
@MainActor
protocol SelfUninstallFileMover {
    /// Moves the data folders and a copy of the preferences. True when nothing failed.
    func moveData() async -> SelfUninstallDataMove
    /// Why the app would not move, read from disk without moving it. Checked
    /// before the data, so a copy that can't move itself keeps its data too.
    func appRefusal() async -> SelfUninstallPolicy.Refusal?
    func moveApp() async -> SelfUninstallAppMove
}

/// How the data step ended. The folders move all or nothing: on a failure the
/// ones that already went are put back.
nonisolated enum SelfUninstallDataMove: Equatable, Sendable {
    case moved
    /// Another copy of Purge turned up, so the shared data stays.
    case keptForOtherCopy
    /// Nothing moved, or what moved was put back.
    case failed
    /// Some folders are in the Trash and could not be put back.
    case failedPartly
}

nonisolated enum SelfUninstallAppMove: Equatable, Sendable {
    case moved
    case refused(SelfUninstallPolicy.Refusal)
    /// The gate passed, but macOS refused the move (an app owned by an administrator).
    case failed
}

/// Why the app could not move itself, for the last screen.
enum SelfUninstallMoveProblem: Equatable {
    case readOnlyVolume
    case translocated
    case notThisApp
    case refusedByMacOS
}

/// Runs Uninstall Purge: turns each part off and reads it again, then moves the
/// data (when asked) and the app. A part still on stops the run before anything
/// moves, unless the user picks Uninstall Anyway.
@MainActor
final class SelfUninstaller: ObservableObject, Identifiable {
    enum Phase: Equatable {
        /// Reading which parts are on.
        case reading
        case confirm
        case working
        /// A step failed; nothing after it ran.
        case stepFailed
        case done
        case couldNotMove(SelfUninstallMoveProblem)
    }

    enum StepKind: Hashable {
        case part(SelfUninstallPart)
        case data
        case app
    }

    enum StepState: Equatable {
        case pending
        case working
        case done
        case failed
        /// Not run because an earlier step failed.
        case skipped
    }

    struct Step: Identifiable, Equatable {
        let kind: StepKind
        var state: StepState
        var id: StepKind { kind }
    }

    @Published private(set) var phase: Phase = .reading
    @Published private(set) var partsOn: [SelfUninstallPart] = []
    @Published private(set) var steps: [Step] = []
    /// The "Also move settings and history" box. Read when the run starts.
    @Published var movesData = false
    /// True between Cancel and the end of the step running when it was pressed.
    @Published private(set) var isStopping = false
    /// True once the moves have started; Cancel is gone from then on.
    @Published private(set) var hasStartedMoving = false
    /// True when the data step ran and finished.
    @Published private(set) var movedData = false
    /// True when part of the data is in the Trash and could not be put back.
    /// Going back to normal running would then make a new, empty data folder
    /// beside the old one, so Cancel is gone and only Try Again or Uninstall
    /// Anyway remain.
    @Published private(set) var dataIsSplit = false
    /// Other copies of Purge on this Mac. They share the settings and history,
    /// so the box is off while any exists: an Xcode build once took the data of
    /// the installed copy this way.
    @Published private(set) var otherCopies: [URL] = []
    var mayMoveData: Bool { otherCopies.isEmpty }

    private let parts: [SelfUninstallPart: SelfUninstallPartControl]
    private let mover: SelfUninstallFileMover
    /// Holds scans, cleans and reviews while the run is going (`PurgeStore`).
    private let setRunning: (Bool) -> Void
    private let findOtherCopies: () async -> [URL]
    private var stopRequested = false

    init(
        parts: [SelfUninstallPartControl],
        mover: SelfUninstallFileMover,
        setRunning: @escaping (Bool) -> Void = { _ in },
        otherCopies: @escaping () async -> [URL] = { [] }
    ) {
        self.parts = Dictionary(parts.map { ($0.part, $0) }, uniquingKeysWith: { first, _ in first })
        self.mover = mover
        self.setRunning = setRunning
        self.findOtherCopies = otherCopies
    }

    /// Reads which parts are on, in the order the sheet lists them.
    func load() async {
        phase = .reading
        var on: [SelfUninstallPart] = []
        for part in SelfUninstallPart.allCases {
            guard let control = parts[part] else { continue }
            if await control.isOn(thorough: false) { on.append(part) }
        }
        partsOn = on
        otherCopies = await findOtherCopies()
        if !mayMoveData { movesData = false }
        phase = .confirm
    }

    func start() async {
        guard phase == .confirm else { return }
        var planned = partsOn.map { Step(kind: .part($0), state: .pending) }
        if movesData, mayMoveData { planned.append(Step(kind: .data, state: .pending)) }
        planned.append(Step(kind: .app, state: .pending))
        steps = planned
        stopRequested = false
        isStopping = false
        setRunning(true)
        phase = .working
        await runParts()
    }

    /// Runs the failed steps again, then whatever had not run.
    func retry() async {
        guard phase == .stepFailed else { return }
        for index in steps.indices where steps[index].state == .failed || steps[index].state == .skipped {
            steps[index].state = .pending
        }
        stopRequested = false
        phase = .working
        await runParts()
    }

    /// Moves on with the failed parts still on. A data move that failed cleanly
    /// runs again; one that left data split between here and the Trash is not
    /// repeated, and the app moves on its own.
    func uninstallAnyway() async {
        guard phase == .stepFailed else { return }
        for index in steps.indices {
            switch (steps[index].kind, steps[index].state) {
            case (.data, .failed):
                // Split data stays as it is and keeps its row on the done screen.
                if !dataIsSplit { steps[index].state = .pending }
            case (_, .skipped):
                steps[index].state = .pending
            default:
                break
            }
        }
        phase = .working
        await runMoves()
    }

    /// Whether the sheet may close back into a running Purge.
    var mayCancel: Bool { !dataIsSplit }

    /// Stops after the step running now. Parts already off stay off.
    func requestStop() {
        guard phase == .working, !hasStartedMoving else { return }
        stopRequested = true
        isStopping = true
    }

    /// The sheet closed without uninstalling: lets scans and cleans run again.
    func dismissed() {
        guard !hasStartedMoving || phase == .stepFailed, mayCancel else { return }
        setRunning(false)
    }

    var failedSteps: [Step] { steps.filter { $0.state == .failed } }

    // MARK: Running

    private func runParts() async {
        for index in steps.indices {
            guard case .part(let part) = steps[index].kind, steps[index].state == .pending else { continue }
            if stopRequested { return finishStop() }
            steps[index].state = .working
            if let control = parts[part] {
                await control.turnOff()
                steps[index].state = await control.isOn(thorough: true) ? .failed : .done
            } else {
                steps[index].state = .failed
            }
        }
        if stopRequested { return finishStop() }
        if !failedSteps.isEmpty { return failRemaining() }
        await runMoves()
    }

    private func runMoves() async {
        hasStartedMoving = true
        isStopping = false
        if let index = steps.firstIndex(where: { $0.kind == .data && $0.state == .pending }) {
            // The app first: data must not go when the app then stays put.
            if let refusal = await mover.appRefusal(), refusal != .alreadyInTrash {
                steps[index].state = .skipped
                if let app = steps.firstIndex(where: { $0.kind == .app }) { steps[app].state = .failed }
                phase = .couldNotMove(Self.problem(for: refusal))
                return
            }
            steps[index].state = .working
            // Read again: a copy can appear while the sheet is open.
            let others = await findOtherCopies()
            let result: SelfUninstallDataMove = others.isEmpty ? await mover.moveData() : .keptForOtherCopy
            switch result {
            case .moved:
                steps[index].state = .done
                movedData = true
                dataIsSplit = false
            case .keptForOtherCopy:
                if !others.isEmpty { otherCopies = others }
                steps[index].state = .skipped
            case .failed:
                steps[index].state = .failed
                return failRemaining()
            case .failedPartly:
                steps[index].state = .failed
                dataIsSplit = true
                return failRemaining()
            }
        }
        guard let index = steps.firstIndex(where: { $0.kind == .app }) else { return }
        steps[index].state = .working
        switch await mover.moveApp() {
        case .moved, .refused(.alreadyInTrash):
            steps[index].state = .done
            phase = .done
        case .refused(let refusal):
            steps[index].state = .failed
            phase = .couldNotMove(Self.problem(for: refusal))
        case .failed:
            steps[index].state = .failed
            phase = .couldNotMove(.refusedByMacOS)
        }
    }

    private func failRemaining() {
        for index in steps.indices where steps[index].state == .pending {
            steps[index].state = .skipped
        }
        phase = .stepFailed
    }

    private func finishStop() {
        stopRequested = false
        isStopping = false
        setRunning(false)
        // Back to the start, with what is still on read from the steps that ran.
        partsOn = steps.compactMap { step in
            guard case .part(let part) = step.kind, step.state != .done else { return nil }
            return part
        }
        steps = []
        phase = .confirm
    }

    static func problem(for refusal: SelfUninstallPolicy.Refusal) -> SelfUninstallMoveProblem {
        switch refusal {
        case .readOnlyVolume: return .readOnlyVolume
        case .translocated: return .translocated
        case .missing, .notAnApp, .notThisApp: return .notThisApp
        // Handled as moved by the caller; listed so a new case fails the build here.
        case .alreadyInTrash: return .notThisApp
        }
    }
}

import SwiftUI

/// Why a scan tab has nothing to list yet. An empty list only means "nothing
/// found" once the tab's scan has finished; before that the tab says which of
/// these it is, so a scan waiting its turn never reads as an empty Mac.
enum ScanWaitStatus: Equatable {
    case scanning
    /// Queued behind another scan; `behind` is the one running now.
    case waiting(behind: ScanStep?)
    /// Not running and not queued, for example after Stop.
    case notScanned
}

extension PurgeStore {
    /// `isScanning` is the tab's own flag. The queue's active step counts too, for
    /// the moment between the queue starting a step and the step raising its flag.
    func scanWaitStatus(for step: ScanStep, isScanning: Bool) -> ScanWaitStatus {
        if isScanning || scanQueue.active == step { return .scanning }
        if isScanQueued(step) { return .waiting(behind: scanQueue.active) }
        return .notScanned
    }

    /// Large Files has listed nothing and no scan has finished this session.
    var isAwaitingFirstLargeFileScan: Bool {
        largeFiles.isEmpty && !hasSessionResults(for: .largeFiles)
    }

    /// Dev Tools has listed nothing and no cache scan has finished this session.
    var isAwaitingFirstDevToolsScan: Bool {
        projectGroups.isEmpty && devTools.isEmpty && simulatorDevices.isEmpty
            && runningSimulatorDevices.isEmpty && !hasSessionCacheScan
    }
}

/// The words each scan tab uses for its wait states.
struct ScanWaitCopy {
    /// What a tab shows while its own scan runs with nothing listed yet.
    struct Scanning {
        /// The symbol the scanning ring turns around: the tab's own icon.
        let symbol: String
        let title: String
        let detail: String
    }

    /// Nil for a tab whose scan lists its first results as soon as it starts
    /// (Large Files, the uninstaller): there the scanning state would only
    /// flash, so the tab keeps its waiting state until rows arrive.
    let scanning: Scanning?
    let waitingTitle: String
    let notScannedTitle: String
    let notScannedDetail: String

    static let largeFiles = ScanWaitCopy(
        scanning: nil,
        waitingTitle: String(localized: "Waiting to look for large files"),
        notScannedTitle: String(localized: "Large files not scanned yet"),
        notScannedDetail: String(localized: "Use Scan to look for large files.")
    )

    static let apps = ScanWaitCopy(
        scanning: nil,
        waitingTitle: String(localized: "Waiting to find your apps"),
        notScannedTitle: String(localized: "Apps not scanned yet"),
        notScannedDetail: String(localized: "Use Rescan to find your apps.")
    )

    static let devTools = ScanWaitCopy(
        scanning: Scanning(
            symbol: "hammer",
            title: String(localized: "Looking for developer folders"),
            detail: String(localized: "Purge is checking tool caches, simulators, and your projects.")
        ),
        waitingTitle: String(localized: "Waiting to look for developer folders"),
        notScannedTitle: String(localized: "Dev Tools not scanned yet"),
        notScannedDetail: String(localized: "Use Scan to look for developer folders.")
    )

    /// The state the tab shows: a tab with no scanning state keeps waiting
    /// while its own scan starts.
    func shown(_ status: ScanWaitStatus) -> ScanWaitStatus {
        if status == .scanning, scanning == nil { return .waiting(behind: nil) }
        return status
    }
}

/// The middle of a scan tab before its first results: a clock with moving hands
/// while it waits its turn (and, on Dev Tools, a ring turning around the tab's
/// icon while it scans), what is happening, and why. No
/// controls, since there is nothing to act on yet.
struct ScanStatusPlaceholder: View {
    let status: ScanWaitStatus
    let copy: ScanWaitCopy

    /// The page subtitle while the tab waits, in place of a count of nothing.
    static func subtitle(for status: ScanWaitStatus, copy: ScanWaitCopy) -> String {
        switch copy.shown(status) {
        case .scanning: return String(localized: "Scanning…")
        case .waiting: return ScanQueueLabels.queued
        case .notScanned: return String(localized: "Not scanned yet")
        }
    }

    private var shown: ScanWaitStatus { copy.shown(status) }

    var body: some View {
        VStack(spacing: 10) {
            symbol
                .frame(width: 60, height: 60)
            Text(title)
                .font(AppStyle.Typography.sectionTitle.weight(.regular))
            Text(detail)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
            if case .waiting = shown {
                WaitingDots()
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var symbol: some View {
        switch shown {
        case .scanning:
            ScanningRing(symbol: copy.scanning?.symbol ?? "magnifyingglass")
        case .waiting:
            WaitingClock()
        case .notScanned:
            Image(systemName: "magnifyingglass")
                .font(.system(size: 38))
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    private var title: String {
        switch shown {
        case .scanning: return copy.scanning?.title ?? copy.waitingTitle
        case .waiting: return copy.waitingTitle
        case .notScanned: return copy.notScannedTitle
        }
    }

    private var detail: String {
        switch shown {
        case .scanning:
            return copy.scanning?.detail ?? ""
        case .waiting(let behind):
            guard let behind else { return String(localized: "Starts in a moment.") }
            let name = behind.displayName
            return String(localized: "Starts after Purge finishes scanning \(name).")
        case .notScanned:
            return copy.notScannedDetail
        }
    }
}

/// A short arc turning around the tab's icon while its scan runs. Still with
/// Reduce Motion: the arc stops at the top.
private struct ScanningRing: View {
    let symbol: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period: TimeInterval = 1.1
    private static let lineWidth: CGFloat = 2.5

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            ZStack {
                Circle()
                    .stroke(AppColors.borderStrong, lineWidth: Self.lineWidth)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(AppColors.textSecondary, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(reduceMotion ? -90 : angle(at: context.date) - 90))
                Image(systemName: symbol)
                    .font(.system(size: 24))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(Self.lineWidth / 2)
        }
    }

    /// Eased within each turn, so the arc speeds up and settles like the system spinner.
    private func angle(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
        let eased = phase < 0.5 ? 2 * phase * phase : 1 - pow(-2 * phase + 2, 2) / 2
        return (0.35 * phase + 0.65 * eased) * 360
    }
}

/// A clock whose hands keep turning while the tab waits its turn: the long hand
/// in 6 seconds, the short one in 36. Still with Reduce Motion.
private struct WaitingClock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let seconds = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .stroke(AppColors.textSecondary, lineWidth: 2.5)
                    .padding(10)
                hand(length: 15, degrees: 90 + seconds.truncatingRemainder(dividingBy: 6) / 6 * 360)
                hand(length: 10, degrees: seconds.truncatingRemainder(dividingBy: 36) / 36 * 360)
            }
        }
    }

    private func hand(length: CGFloat, degrees: Double) -> some View {
        Capsule()
            .fill(AppColors.textSecondary)
            .frame(width: 2.5, height: length)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(degrees))
    }
}

/// Three dots that pulse in turn under the waiting title.
private struct WaitingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(AppColors.textSecondary)
                        .frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.6 : opacity(at: time, index: index))
                }
            }
        }
    }

    private func opacity(at time: TimeInterval, index: Int) -> Double {
        let phase = (time / 1.2 - Double(index) * 0.17) * 2 * .pi
        return 0.25 + 0.75 * (0.5 + 0.5 * sin(phase))
    }
}

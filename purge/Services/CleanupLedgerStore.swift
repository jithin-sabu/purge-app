import Foundation

/// The permanent record of every clean, one JSON line per clean in a file per
/// calendar year (`ledger/2026.jsonl`).
///
/// `CleanupHistoryStore` keeps only the last 100 cleans, which can be a few weeks
/// for a heavy user, so it cannot answer "what did this year add up to". The
/// ledger is append-only and never trimmed: a clean writes one line, nothing is
/// rewritten, and a line torn by a crash is skipped on read without losing the
/// rest of the file.
///
/// Users reach the ledger from any older version, so it never assumes it saw
/// every clean. On each launch it copies in whatever History has that it lacks,
/// and the first time it runs it keeps a `CleanupLedgerBaseline` of the older
/// counters, so cleans History had already dropped still count toward the year.
@MainActor
final class CleanupLedgerStore {
    static let shared = CleanupLedgerStore(directory: defaultDirectory())

    private static let baselineName = "baseline.json"

    private let directory: URL
    private let homePath: String
    private let calendar: Calendar
    private let resolveBundleID: @Sendable (String) -> String?
    private var pendingReconcile: Task<Void, Never>?
    /// Bumped by `clear()`, so an import already running cannot write cleared
    /// cleans back.
    private var generation = 0

    init(
        directory: URL,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        calendar: Calendar = .current,
        resolveBundleID: @escaping @Sendable (String) -> String? = { appDisplayName(forBundleID: $0) }
    ) {
        self.directory = directory
        self.homePath = homePath
        self.calendar = calendar
        self.resolveBundleID = resolveBundleID
    }

    private static func defaultDirectory() -> URL {
        // Tests run inside a hosted copy of the app. A clean a test drives must
        // never land in the user's permanent record, so they get a scratch folder.
        if TestHost.isActive() {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("PurgeTestLedger-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("io.getpurge.app", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ledger", isDirectory: true)
    }

    // MARK: - Recording

    /// Appends one clean. A run that removed nothing is not recorded.
    func record(_ report: DeletionReport, id: UUID, trigger: CleanupTrigger, source: CleanupSource) {
        guard let session = session(from: report, id: id, trigger: trigger, source: source) else { return }
        append([session])
    }

    func session(
        from report: DeletionReport,
        id: UUID,
        trigger: CleanupTrigger,
        source: CleanupSource
    ) -> CleanupLedgerSession? {
        guard !report.deletedItems.isEmpty else { return nil }
        let items = report.deletedItems.map { item in
            let path = Self.homeRelative(item.path, home: homePath)
            let name = item.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CleanupLedgerItem(
                path: path,
                bytes: item.sizeBytes,
                label: (name?.isEmpty == false ? name : nil)
                    ?? CleanupLedgerLabel.derive(fromPath: path, resolveBundleID: resolveBundleID),
                movedToTrash: item.movedToTrash
            )
        }
        return CleanupLedgerSession(
            id: id,
            date: report.timestamp,
            trigger: trigger,
            source: source,
            bytesMovedToTrash: report.bytesMovedToTrash,
            bytesRemovedDirectly: report.bytesRemovedDirectly,
            bytesReclaimedOnVolume: report.reportableBytesReclaimedOnVolume,
            skippedForSafetyCount: report.skippedItems.filter(\.isUserVisible).count,
            failedCount: report.failedItems.count,
            importedFromHistory: false,
            items: items
        )
    }

    // MARK: - Reconciling with History

    /// What older versions left on disk, read at launch before any clean runs.
    struct LegacyRecord {
        var history: [CleanupHistoryEntry]
        /// `totalRecoveredBytes`.
        var lifetimeMovedBytes: Int64
        var firstSeenAt: Date?
        var firstSeenVersion: String?
        var appVersion: String
        var now = Date()
    }

    /// Run at every launch. The first time, saves the baseline. Every time, copies
    /// in History cleans the ledger lacks: all of them on first run, and after
    /// that only cleans an older version made following a downgrade, or a ledger
    /// write that failed. History lines share their id with the ledger, so nothing
    /// is counted twice. Reading and naming run off the main thread.
    @discardableResult
    func reconcile(with legacy: LegacyRecord) -> Task<Void, Never> {
        captureBaselineIfNeeded(legacy)

        let snapshot = legacy.history.map(HistorySnapshot.init)
        let directory = directory
        let calendar = calendar
        let homePath = homePath
        let resolve = resolveBundleID
        let previous = pendingReconcile
        let startGeneration = generation
        let task = Task { [weak self] in
            await previous?.value
            let missing = await Self.sessionsMissing(
                from: snapshot, directory: directory, calendar: calendar, homePath: homePath, resolve: resolve
            )
            guard let self, self.generation == startGeneration else { return }
            self.append(missing)
        }
        pendingReconcile = task
        return task
    }

    /// The baseline is only meaningful at the moment the ledger starts: later, the
    /// counter and History both include cleans the ledger already holds, and a
    /// baseline taken then would count them twice. So it is never retaken once any
    /// ledger file exists. A missing baseline undercounts, which is the safe side.
    private func captureBaselineIfNeeded(_ legacy: LegacyRecord) {
        let url = directory.appendingPathComponent(Self.baselineName)
        guard !FileManager.default.fileExists(atPath: url.path), yearFiles().isEmpty else { return }
        writeBaseline(CleanupLedgerBaseline(
            capturedAt: legacy.now,
            appVersion: legacy.appVersion,
            lifetimeMovedBytes: legacy.lifetimeMovedBytes,
            historyEntryCount: legacy.history.count,
            historyMovedBytes: legacy.history.reduce(0) { $0 + $1.bytesMovedToTrash },
            historyOldestDate: legacy.history.map(\.date).min(),
            firstSeenAt: legacy.firstSeenAt,
            firstSeenVersion: legacy.firstSeenVersion
        ))
    }

    private func writeBaseline(_ baseline: CleanupLedgerBaseline) {
        let url = directory.appendingPathComponent(Self.baselineName)
        guard ensureDirectory(), let data = try? Self.encoder().encode(baseline) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Clearing History in Settings promises to remove every saved cleanup record,
    /// so the ledger goes too. An import still running is dropped rather than
    /// awaited: its snapshot is of the History just cleared.
    ///
    /// The baseline is replaced with an empty one, not deleted. With no baseline
    /// and no ledger files, the next launch would take a new one from the lifetime
    /// counter and bring every cleared byte back as "before the record".
    func clear(now: Date = Date()) {
        generation += 1
        for file in yearFiles() {
            try? FileManager.default.removeItem(at: file)
        }
        writeBaseline(CleanupLedgerBaseline(
            capturedAt: now,
            appVersion: FirstRunGate.currentAppVersion(),
            lifetimeMovedBytes: 0,
            historyEntryCount: 0,
            historyMovedBytes: 0,
            historyOldestDate: nil,
            firstSeenAt: nil,
            firstSeenVersion: nil
        ))
    }

    func baseline() -> CleanupLedgerBaseline? {
        let url = directory.appendingPathComponent(Self.baselineName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder().decode(CleanupLedgerBaseline.self, from: data)
    }

    /// A History entry reduced to what the import needs, so it can cross to a
    /// background task.
    nonisolated struct HistorySnapshot: Sendable {
        let id: UUID
        let date: Date
        let trigger: CleanupTrigger
        let bytesMovedToTrash: Int64
        let bytesReclaimedOnVolume: Int64?
        let skippedForSafetyCount: Int
        let items: [(path: String, bytes: Int64)]

        init(_ entry: CleanupHistoryEntry) {
            id = entry.id
            date = entry.date
            trigger = entry.trigger
            bytesMovedToTrash = entry.bytesMovedToTrash
            bytesReclaimedOnVolume = entry.bytesReclaimedOnVolume
            skippedForSafetyCount = entry.skippedItems.filter(\.isUserVisible).count
            items = entry.deletedItems.map { ($0.path, $0.sizeBytes) }
        }
    }

    @concurrent
    nonisolated private static func sessionsMissing(
        from snapshot: [HistorySnapshot],
        directory: URL,
        calendar: Calendar,
        homePath: String,
        resolve: @escaping @Sendable (String) -> String?
    ) async -> [CleanupLedgerSession] {
        let candidates = snapshot.filter { !$0.items.isEmpty }
        guard !candidates.isEmpty else { return [] }

        let years = Set(candidates.flatMap { entry -> [Int] in
            let year = calendar.component(.year, from: entry.date)
            return [year - 1, year, year + 1]
        })
        let known = Set(years.flatMap { loadSessions(fileURL(forYear: $0, in: directory)) }.map(\.id))

        // One lookup per bundle ID: History repeats the same folders clean after clean.
        var names: [String: String?] = [:]
        let cachedResolve: (String) -> String? = { bundleID in
            if let cached = names[bundleID] { return cached }
            let name = resolve(bundleID)
            names[bundleID] = name
            return name
        }

        return candidates
            .filter { !known.contains($0.id) }
            .sorted { $0.date < $1.date }
            .map { importedSession($0, homePath: homePath, resolve: cachedResolve) }
    }

    nonisolated private static func importedSession(
        _ entry: HistorySnapshot,
        homePath: String,
        resolve: (String) -> String?
    ) -> CleanupLedgerSession {
        let items = entry.items.map { item in
            let path = homeRelative(item.path, home: homePath)
            return CleanupLedgerItem(
                path: path,
                bytes: item.bytes,
                label: CleanupLedgerLabel.derive(fromPath: path, resolveBundleID: resolve),
                movedToTrash: true
            )
        }
        // History does not say which screen a clean came from. A removed app
        // means the uninstaller; anything else is counted as a regular clean.
        let source: CleanupSource = items.contains { CleanupLedgerLabel.isAppBundle(path: $0.path) }
            ? .uninstall : .clean
        return CleanupLedgerSession(
            id: entry.id,
            date: entry.date,
            trigger: entry.trigger,
            source: source,
            bytesMovedToTrash: entry.bytesMovedToTrash,
            bytesRemovedDirectly: 0,
            bytesReclaimedOnVolume: entry.bytesReclaimedOnVolume,
            skippedForSafetyCount: entry.skippedForSafetyCount,
            failedCount: 0,
            importedFromHistory: true,
            items: items
        )
    }

    // MARK: - Reading

    /// The year's cleans, including any filed under a neighbouring year because
    /// the time zone changed since they were written.
    func sessions(inYear year: Int) -> [CleanupLedgerSession] {
        Self.loadYear(year, directory: directory, calendar: calendar)
    }

    /// The year's totals, once any History import still running has finished.
    func yearTotals(_ year: Int) async -> CleanupYearTotals {
        await pendingReconcile?.value
        let baseline = baseline()
        return await Self.computeTotals(year: year, directory: directory, baseline: baseline, calendar: calendar)
    }

    @concurrent
    nonisolated private static func computeTotals(
        year: Int,
        directory: URL,
        baseline: CleanupLedgerBaseline?,
        calendar: Calendar
    ) async -> CleanupYearTotals {
        CleanupYearTotals.compute(
            year: year,
            sessions: loadYear(year, directory: directory, calendar: calendar),
            baseline: baseline,
            calendar: calendar
        )
    }

    func fileURL(forYear year: Int) -> URL {
        Self.fileURL(forYear: year, in: directory)
    }

    nonisolated private static func fileURL(forYear year: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("\(year).jsonl", isDirectory: false)
    }

    private func yearFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
    }

    nonisolated private static func loadYear(_ year: Int, directory: URL, calendar: Calendar) -> [CleanupLedgerSession] {
        var seen = Set<UUID>()
        return [year - 1, year, year + 1]
            .flatMap { loadSessions(fileURL(forYear: $0, in: directory)) }
            .filter { calendar.component(.year, from: $0.date) == year && seen.insert($0.id).inserted }
    }

    nonisolated private static func loadSessions(_ url: URL) -> [CleanupLedgerSession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = decoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(CleanupLedgerSession.self, from: Data($0))
        }
    }

    // MARK: - Writing

    private func append(_ sessions: [CleanupLedgerSession]) {
        guard !sessions.isEmpty, ensureDirectory() else { return }
        let encoder = Self.encoder()
        let byYear = Dictionary(grouping: sessions) { calendar.component(.year, from: $0.date) }
        for (year, yearSessions) in byYear {
            var lines = Data()
            for session in yearSessions {
                guard let line = try? encoder.encode(session) else { continue }
                lines.append(line)
                lines.append(UInt8(ascii: "\n"))
            }
            appendLines(lines, to: fileURL(forYear: year))
        }
    }

    private func appendLines(_ lines: Data, to url: URL) {
        guard !lines.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? lines.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            var payload = lines
            // A crash mid-write can leave a last line with no newline. Starting on
            // a fresh line keeps the torn one from swallowing this clean too.
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data([UInt8(ascii: "\n")]) {
                    payload.insert(UInt8(ascii: "\n"), at: 0)
                }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: payload)
        } catch {
            return
        }
    }

    private func ensureDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    nonisolated private static func homeRelative(_ path: String, home homePath: String) -> String {
        let home = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        let remainder = path.dropFirst(home.count)
        if remainder.isEmpty { return "~" }
        // `/Users/alice2` must not become `~2`: only a match on a path boundary counts.
        guard remainder.hasPrefix("/") else { return path }
        return "~" + remainder
    }
}

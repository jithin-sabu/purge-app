import Foundation

/// The permanent record of every clean, one JSON line per clean in a file per
/// Gregorian year (`ledger/2026.jsonl`), whatever calendar the Mac is set to.
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
        timeZone: TimeZone = .current,
        resolveBundleID: @escaping @Sendable (String) -> String? = { appDisplayName(forBundleID: $0) }
    ) {
        self.directory = directory
        self.homePath = homePath
        // Never `Calendar.current`: on the Islamic calendar that named the file
        // `1448.jsonl` and imported all of History into it a second time (#461).
        self.calendar = CleanupLedgerCalendar.gregorian(in: timeZone)
        self.resolveBundleID = resolveBundleID
    }

    private static func defaultDirectory() -> URL {
        AppSupportFolder.url().appendingPathComponent("ledger", isDirectory: true)
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

    /// Run at every launch. The first time, saves the baseline. Every time, moves
    /// cleans out of files an older build named by the Mac's own calendar, then
    /// copies in History cleans the ledger lacks: all of them on first run, and
    /// after that only cleans an older version made following a downgrade, or a
    /// ledger write that failed. History lines share their id with the ledger, so
    /// nothing is counted twice. Reading and naming run off the main thread.
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
            let strays = await Self.strayFiles(in: directory, calendar: calendar)
            guard let self, self.generation == startGeneration else { return }
            if !strays.files.isEmpty {
                self.append(strays.missing)
                let merged = await Self.filesFullyMerged(strays.files, directory: directory, calendar: calendar)
                guard self.generation == startGeneration else { return }
                for file in merged {
                    try? FileManager.default.removeItem(at: file)
                }
            }

            let missing = await Self.sessionsMissing(
                from: snapshot, directory: directory, calendar: calendar, homePath: homePath, resolve: resolve
            )
            guard self.generation == startGeneration else { return }
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

    /// Clearing History in Settings removes every saved cleanup record, so the
    /// ledger's cleans go too: what was removed, from where, and when. The total
    /// stays, as the lifetime counter always has: the baseline is retaken from it,
    /// so the year's recap still has its headline, and its breakdowns start from
    /// the clear. The total is one undated number and says nothing the counter
    /// does not already show.
    ///
    /// An import still running is dropped rather than awaited: its snapshot is of
    /// the History just cleared.
    func clear(keepingTotal lifetimeMovedBytes: Int64, firstSeenAt: Date?, now: Date = Date()) {
        generation += 1
        let previous = baseline()
        for file in yearFiles() {
            try? FileManager.default.removeItem(at: file)
        }
        writeBaseline(CleanupLedgerBaseline(
            capturedAt: now,
            appVersion: FirstRunGate.currentAppVersion(),
            lifetimeMovedBytes: lifetimeMovedBytes,
            historyEntryCount: 0,
            historyMovedBytes: 0,
            historyOldestDate: nil,
            firstSeenAt: firstSeenAt ?? previous?.firstSeenAt,
            firstSeenVersion: previous?.firstSeenVersion
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
        /// Zero for entries written before #303, which did not keep failures.
        let failedCount: Int
        let items: [(path: String, bytes: Int64)]
        /// False for entries whose items are not files moved to the Trash, so the
        /// import never files them as a clean.
        let belongsInLedger: Bool

        init(_ entry: CleanupHistoryEntry) {
            id = entry.id
            date = entry.date
            trigger = entry.trigger
            bytesMovedToTrash = entry.bytesMovedToTrash
            bytesReclaimedOnVolume = entry.bytesReclaimedOnVolume
            skippedForSafetyCount = entry.skippedItems.filter(\.isUserVisible).count
            failedCount = entry.failedItems.count
            items = entry.deletedItems.map { ($0.path, $0.sizeBytes) }
            belongsInLedger = Self.importsIntoLedger(entry.kind)
        }

        /// An Apple Intelligence removal lists model sets by name, each with
        /// Apple's record sum, which overstates what went (#133). Imported as a
        /// clean, those names and sums would lead the recap's labels and biggest
        /// item as if they had been moved to the Trash, so they stay in History only.
        static func importsIntoLedger(_ kind: CleanupHistoryKind?) -> Bool {
            switch kind {
            case nil:
                return true
            case .appleIntelligenceModels?:
                return false
            // Nothing was cleaned: the files are still in iCloud, and the
            // recap counts what went to the Trash.
            case .iCloudDownloadsRemoved?:
                return false
            }
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
        let candidates = snapshot.filter { $0.belongsInLedger && !$0.items.isEmpty }
        guard !candidates.isEmpty else { return [] }

        let known = knownIDs(near: candidates.map(\.date), directory: directory, calendar: calendar)

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

    /// Ids of every clean in the year files that could hold one dated `dates`:
    /// each date's year and the years either side, for time-zone changes.
    nonisolated private static func knownIDs(near dates: [Date], directory: URL, calendar: Calendar) -> Set<UUID> {
        let years = Set(dates.flatMap { date -> [Int] in
            let year = calendar.component(.year, from: date)
            return [year - 1, year, year + 1]
        })
        return Set(years.flatMap { loadSessions(fileURL(forYear: $0, in: directory)) }.map(\.id))
    }

    // MARK: - Files named by another calendar

    /// Builds before #461 named each file by the Mac's own calendar year, so a
    /// Mac on the Islamic calendar wrote `1447.jsonl` and `1448.jsonl`, and one
    /// on the Buddhist calendar `2569.jsonl`. Those files are never read, and for
    /// such a user they hold every clean since the ledger shipped.
    ///
    /// A file is stray when every clean in it falls more than a year from its
    /// name in the Gregorian calendar. Within a year is a time-zone change, which
    /// `loadYear` already reads across, so those files are left alone. `missing`
    /// is the stray cleans the Gregorian files lack, once each: the same History
    /// import can sit in two stray files.
    @concurrent
    nonisolated private static func strayFiles(
        in directory: URL,
        calendar: Calendar
    ) async -> (files: [URL], missing: [CleanupLedgerSession]) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var files: [URL] = []
        var strays: [CleanupLedgerSession] = []
        for url in urls where url.pathExtension == "jsonl" {
            guard let namedYear = Int(url.deletingPathExtension().lastPathComponent) else { continue }
            let sessions = loadSessions(url)
            let isStray = !sessions.isEmpty && sessions.allSatisfy {
                abs(calendar.component(.year, from: $0.date) - namedYear) > 1
            }
            guard isStray else { continue }
            files.append(url)
            strays.append(contentsOf: sessions)
        }
        guard !files.isEmpty else { return ([], []) }

        let known = knownIDs(near: strays.map(\.date), directory: directory, calendar: calendar)
        var seen = Set<UUID>()
        let missing = strays
            .sorted { $0.date < $1.date }
            .filter { !known.contains($0.id) && seen.insert($0.id).inserted }
        return (files, missing)
    }

    /// The stray files whose every clean is now in a Gregorian file, read back
    /// from disk. A file with a clean that did not land stays for the next launch.
    @concurrent
    nonisolated private static func filesFullyMerged(
        _ files: [URL],
        directory: URL,
        calendar: Calendar
    ) async -> [URL] {
        files.filter { file in
            let sessions = loadSessions(file)
            let known = knownIDs(near: sessions.map(\.date), directory: directory, calendar: calendar)
            return sessions.allSatisfy { known.contains($0.id) }
        }
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
            failedCount: entry.failedCount,
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
            timeZone: calendar.timeZone
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
        abbreviatingHome(in: path, home: homePath)
    }
}

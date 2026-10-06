import Foundation

/// The permanent record of every clean, one JSON line per clean in a file per
/// calendar year (`ledger/2026.jsonl`).
///
/// `CleanupHistoryStore` keeps only the last 100 cleans, which can be a few weeks
/// for a heavy user, so it cannot answer "what did this year add up to". The
/// ledger is append-only and never trimmed: a clean writes one line, nothing is
/// rewritten, and a line torn by a crash is skipped on read without losing the
/// rest of the file.
@MainActor
final class CleanupLedgerStore {
    static let shared = CleanupLedgerStore(directory: defaultDirectory())

    /// Marks that `cleanup_history.json` has been copied in, so launch does not
    /// read every year file again just to find nothing new.
    private static let importMarkerName = ".history-imported"

    private let directory: URL
    private let homePath: String
    private let calendar: Calendar
    private let resolveBundleID: (String) -> String?

    init(
        directory: URL,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        calendar: Calendar = .current,
        resolveBundleID: @escaping (String) -> String? = { appDisplayName(forBundleID: $0) }
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
            let path = homeRelative(item.path)
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

    // MARK: - Importing history

    /// Copies cleans from `cleanup_history.json` that the ledger does not have
    /// yet. Runs once; history entries share their id with the ledger line, so a
    /// repeat would add nothing anyway.
    func importHistoryIfNeeded(_ entries: [CleanupHistoryEntry]) {
        let marker = directory.appendingPathComponent(Self.importMarkerName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        let known = Set(allSessions().map(\.id))
        let imported = entries
            .filter { !known.contains($0.id) && !$0.deletedItems.isEmpty }
            .sorted { $0.date < $1.date }
            .map(importedSession)
        append(imported)

        guard ensureDirectory() else { return }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
    }

    private func importedSession(_ entry: CleanupHistoryEntry) -> CleanupLedgerSession {
        let items = entry.deletedItems.map { item in
            let path = homeRelative(item.path)
            return CleanupLedgerItem(
                path: path,
                bytes: item.sizeBytes,
                label: CleanupLedgerLabel.derive(fromPath: path, resolveBundleID: resolveBundleID),
                movedToTrash: true
            )
        }
        // History does not say which screen a clean came from. A removed .app
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
            skippedForSafetyCount: entry.skippedItems.filter(\.isUserVisible).count,
            failedCount: 0,
            importedFromHistory: true,
            items: items
        )
    }

    // MARK: - Reading

    func sessions(inYear year: Int) -> [CleanupLedgerSession] {
        load(fileURL(forYear: year))
    }

    func totals(forYear year: Int) -> CleanupYearTotals {
        CleanupYearTotals.compute(year: year, sessions: sessions(inYear: year), calendar: calendar)
    }

    func fileURL(forYear year: Int) -> URL {
        directory.appendingPathComponent("\(year).jsonl", isDirectory: false)
    }

    private func allSessions() -> [CleanupLedgerSession] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.flatMap(load)
    }

    private func load(_ url: URL) -> [CleanupLedgerSession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(CleanupLedgerSession.self, from: Data($0))
        }
    }

    // MARK: - Writing

    private func append(_ sessions: [CleanupLedgerSession]) {
        guard !sessions.isEmpty, ensureDirectory() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

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
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
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

    private func homeRelative(_ path: String) -> String {
        let home = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        let remainder = path.dropFirst(home.count)
        if remainder.isEmpty { return "~" }
        // `/Users/alice2` must not become `~2`: only a match on a path boundary counts.
        guard remainder.hasPrefix("/") else { return path }
        return "~" + remainder
    }
}

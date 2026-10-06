import Foundation
import Testing
@testable import Purge

@MainActor
@Suite("Yearly cleanup ledger")
struct CleanupLedgerTests {
    private static let home = "/Users/me"

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private static func makeStore(_ directory: URL) -> CleanupLedgerStore {
        CleanupLedgerStore(
            directory: directory,
            homePath: home,
            calendar: utc,
            resolveBundleID: { ["company.thebrowser.dia": "Dia", "ru.keepcoder.Telegram": "Telegram"][$0] }
        )
    }

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanupLedgerTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func report(
        _ items: [DeletedItem],
        on date: Date,
        skipped: [SkippedDeletionItem] = []
    ) -> DeletionReport {
        DeletionReport(
            bytesMovedToTrash: items.filter(\.movedToTrash).reduce(0) { $0 + $1.sizeBytes },
            bytesRemovedDirectly: items.filter { !$0.movedToTrash }.reduce(0) { $0 + $1.sizeBytes },
            deletedItems: items,
            failedItems: [],
            skippedItems: skipped,
            capacityBefore: nil,
            capacityAfter: nil,
            timestamp: date
        )
    }

    // MARK: - Labels

    @Test
    func labelsComeFromTheOwningFolder() {
        let resolve: (String) -> String? = { $0 == "company.thebrowser.dia" ? "Dia" : nil }
        func label(_ path: String) -> String {
            CleanupLedgerLabel.derive(fromPath: path, resolveBundleID: resolve)
        }
        #expect(label("~/Library/Caches/company.thebrowser.dia/Cache") == "Dia")
        #expect(label("~/Library/Caches/Dia") == "Dia")
        #expect(label("~/Library/Developer/Xcode/DerivedData") == "Xcode")
        #expect(label("~/Library/Group Containers/6N38VWS5BX.company.thebrowser.dia") == "Dia")
        #expect(label("~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared") == "shared")
        #expect(label("~/.npm/_cacache") == "npm")
        #expect(label("~/.cache/huggingface/hub") == "huggingface")
        #expect(label("/Applications/Slack.app") == "Slack")
        #expect(label("~/Library/Caches/io.getpurge.app") == "getpurge")
        #expect(label("~/Downloads/installer.dmg") == "installer.dmg")
    }

    /// An app that is gone can't be looked up, but its bundle ID's last part is
    /// still a better name than the reverse-DNS string.
    @Test
    func uninstalledBundleIDFallsBackToItsLastPart() {
        let label = CleanupLedgerLabel.derive(
            fromPath: "~/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt",
            resolveBundleID: { _ in nil }
        )
        #expect(label == "ShipIt")
    }

    /// Purge's own cache folder is named after its bundle ID, `io.getpurge.app`.
    /// Treating it as an app turned ordinary cleans into uninstalls.
    @Test
    func bundleIDFolderEndingInAppIsNotAnApp() {
        #expect(CleanupLedgerLabel.isAppBundle(path: "/Applications/Microsoft Teams.app"))
        #expect(CleanupLedgerLabel.isAppBundle(path: "~/Applications/Xcode.app"))
        #expect(!CleanupLedgerLabel.isAppBundle(path: "~/Library/Caches/io.getpurge.app"))
        #expect(!CleanupLedgerLabel.isAppBundle(path: "~/Library/Caches/.app"))
    }

    // MARK: - Recording

    @Test
    func recordStoresHomeRelativePathsAndRowNames() throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Self.makeStore(directory)

        store.record(
            Self.report(
                [
                    DeletedItem(path: "/Users/me/Library/Caches/company.thebrowser.dia", sizeBytes: 900, displayName: "Dia"),
                    DeletedItem(path: "/Users/me/Library/Caches/ru.keepcoder.Telegram", sizeBytes: 100),
                    DeletedItem(path: "/Users/me2/Library/Caches/x", sizeBytes: 1),
                ],
                on: Self.date(2026, 3, 4),
                skipped: [
                    SkippedDeletionItem(path: "/a", displayName: nil, reason: "r", isUserVisible: true),
                    SkippedDeletionItem(path: "/b", displayName: nil, reason: "r", isUserVisible: false),
                ]
            ),
            id: UUID(),
            trigger: .manual,
            source: .clean
        )

        let sessions = store.sessions(inYear: 2026)
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.items.map(\.path) == [
            "~/Library/Caches/company.thebrowser.dia",
            "~/Library/Caches/ru.keepcoder.Telegram",
            "/Users/me2/Library/Caches/x",
        ])
        #expect(session.items.map(\.label) == ["Dia", "Telegram", "x"])
        #expect(session.skippedForSafetyCount == 1)
        #expect(session.source == .clean)
        #expect(!session.importedFromHistory)
    }

    @Test
    func cleanThatRemovedNothingIsNotRecorded() {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Self.makeStore(directory)

        store.record(Self.report([], on: Self.date(2026, 1, 1)), id: UUID(), trigger: .scheduled, source: .clean)

        #expect(store.sessions(inYear: 2026).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(forYear: 2026).path))
    }

    @Test
    func sessionsLandInTheirOwnYearFile() {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Self.makeStore(directory)
        let item = DeletedItem(path: "/Users/me/.npm", sizeBytes: 10)

        store.record(Self.report([item], on: Self.date(2025, 12, 31)), id: UUID(), trigger: .manual, source: .clean)
        store.record(Self.report([item], on: Self.date(2026, 1, 1)), id: UUID(), trigger: .manual, source: .clean)

        #expect(store.sessions(inYear: 2025).count == 1)
        #expect(store.sessions(inYear: 2026).count == 1)
    }

    /// A crash mid-write leaves a torn last line. The next clean must start on a
    /// fresh line so it stays readable, and the torn line is skipped.
    @Test
    func tornLastLineDoesNotSwallowTheNextClean() throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Self.makeStore(directory)
        let item = DeletedItem(path: "/Users/me/.npm", sizeBytes: 10)

        store.record(Self.report([item], on: Self.date(2026, 2, 1)), id: UUID(), trigger: .manual, source: .clean)
        let url = store.fileURL(forYear: 2026)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"torn".utf8))
        try handle.close()

        store.record(Self.report([item], on: Self.date(2026, 2, 2)), id: UUID(), trigger: .manual, source: .clean)

        #expect(store.sessions(inYear: 2026).count == 2)
    }

    // MARK: - Reconciling with older versions

    private static func legacy(
        _ history: [CleanupHistoryEntry],
        lifetime: Int64,
        firstSeenAt: Date? = nil
    ) -> CleanupLedgerStore.LegacyRecord {
        CleanupLedgerStore.LegacyRecord(
            history: history,
            lifetimeMovedBytes: lifetime,
            firstSeenAt: firstSeenAt,
            firstSeenVersion: firstSeenAt == nil ? nil : "1.2.7",
            appVersion: "1.9.0",
            now: date(2026, 12, 2)
        )
    }

    private static func historyEntry(
        id: UUID = UUID(),
        _ date: Date,
        _ items: [(String, Int64)],
        trigger: CleanupTrigger = .manual
    ) -> CleanupHistoryEntry {
        CleanupHistoryEntry(
            id: id,
            date: date,
            trigger: trigger,
            bytesMovedToTrash: items.reduce(0) { $0 + $1.1 },
            deletedItems: items.map { CleanupHistoryDeletedItemDTO(path: $0.0, sizeBytes: $0.1) }
        )
    }

    @Test
    func reconcileImportsHistoryOnceAndSkipsCleansAlreadyRecorded() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Self.makeStore(directory)

        let sharedID = UUID()
        let entries = [
            Self.historyEntry(id: sharedID, Self.date(2026, 5, 20), [("/Users/me/.npm", 10)]),
            Self.historyEntry(Self.date(2026, 5, 19), [
                ("/Applications/Slack.app", 400),
                ("/Users/me/Library/Caches/com.tinyspeck.slackmacgap", 100),
            ]),
            CleanupHistoryEntry(date: Self.date(2026, 5, 21), trigger: .scheduled, bytesMovedToTrash: 0, deletedItems: []),
        ]
        await store.reconcile(with: Self.legacy(entries, lifetime: 510)).value
        store.record(
            Self.report([DeletedItem(path: "/Users/me/.npm", sizeBytes: 10)], on: Self.date(2026, 5, 22)),
            id: UUID(),
            trigger: .manual,
            source: .clean
        )
        await store.reconcile(with: Self.legacy(entries, lifetime: 520)).value

        let sessions = store.sessions(inYear: 2026)
        #expect(sessions.count == 3)
        let imported = sessions.filter(\.importedFromHistory)
        #expect(imported.count == 2)
        #expect(imported.first { $0.source == .uninstall }?.items.map(\.label) == ["Slack", "slackmacgap"])
    }

    /// Someone who rolls back to an older version keeps cleaning into History
    /// only. Those cleans arrive on the next launch of a ledger version.
    @Test
    func cleansFromADowngradeArriveOnTheNextLaunch() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Self.makeStore(directory)
        let first = Self.historyEntry(Self.date(2026, 8, 1), [("/Users/me/.npm", 100)])
        await store.reconcile(with: Self.legacy([first], lifetime: 100)).value
        let baseline = store.baseline()

        let madeByOldVersion = Self.historyEntry(Self.date(2026, 9, 1), [("/Users/me/.gradle", 50)])
        await store.reconcile(with: Self.legacy([madeByOldVersion, first], lifetime: 150)).value

        #expect(store.sessions(inYear: 2026).map(\.bytesMovedToTrash).sorted() == [50, 100])
        #expect(store.baseline() == baseline)
        #expect(await store.yearTotals(2026).headlineBytes == 150)
    }

    /// The case the recap is for: a user who never ran a ledger version until the
    /// recap release. History holds only its last 100 cleans; the lifetime
    /// counter holds the rest, and every byte of it is from 2026.
    @Test
    func userComingStraightFromAnOldVersionGetsTheWholeYear() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Self.makeStore(directory)
        let history = [
            Self.historyEntry(Self.date(2026, 11, 20), [("/Users/me/Library/Caches/company.thebrowser.dia", 600)]),
            Self.historyEntry(Self.date(2026, 10, 2), [("/Users/me/Library/Developer/Xcode/DerivedData", 400)]),
        ]

        await store.reconcile(with: Self.legacy(history, lifetime: 51_000, firstSeenAt: Self.date(2026, 7, 13))).value
        let totals = await store.yearTotals(2026)

        #expect(totals.bytesCleared == 1_000)
        #expect(totals.bytesBeforeRecord == 50_000)
        #expect(!totals.bytesBeforeRecordIsEstimate)
        #expect(totals.headlineBytes == 51_000)
        #expect(totals.labels.map(\.label) == ["Dia", "Xcode"])
        #expect(totals.firstRecordedDate == Self.date(2026, 10, 2))
        #expect(totals.includesImportedHistory)
        #expect(await store.yearTotals(2025).headlineBytes == 0)
        let baseline = try #require(store.baseline())
        #expect(baseline.untrackedWindow.start == Self.date(2026, 7, 13))
        #expect(baseline.untrackedWindow.end == Self.date(2026, 10, 2))
    }

    /// Once the ledger holds cleans, the counter and History both include them,
    /// so a baseline taken then would count them twice. It is never retaken.
    @Test
    func baselineIsNotTakenOnceTheLedgerHasCleans() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Self.makeStore(directory)
        store.record(
            Self.report([DeletedItem(path: "/Users/me/.npm", sizeBytes: 10)], on: Self.date(2026, 6, 1)),
            id: UUID(),
            trigger: .manual,
            source: .clean
        )

        await store.reconcile(with: Self.legacy([], lifetime: 9_999)).value

        #expect(store.baseline() == nil)
        #expect(await store.yearTotals(2026).headlineBytes == 10)
    }

    @Test
    func freshInstallHasAnEmptyYear() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Self.makeStore(directory)

        await store.reconcile(with: Self.legacy([], lifetime: 0)).value
        let totals = await store.yearTotals(2026)

        #expect(totals.headlineBytes == 0)
        #expect(totals.cleanCount == 0)
        #expect(store.baseline()?.untrackedBytes == 0)
    }

    /// A user who skips every ledger release until a recap in 2027: untracked
    /// bytes span the new year, so they are split by days and marked an estimate.
    @Test
    func untrackedBytesAcrossANewYearAreSplitByDays() {
        let baseline = CleanupLedgerBaseline(
            capturedAt: Self.date(2027, 12, 1),
            appVersion: "2.0",
            lifetimeMovedBytes: 1_000_000,
            historyEntryCount: 100,
            historyMovedBytes: 0,
            historyOldestDate: Self.date(2027, 3, 1),
            firstSeenAt: Self.date(2026, 11, 1),
            firstSeenVersion: "1.9"
        )

        let in2026 = baseline.untrackedBytes(inYear: 2026, calendar: Self.utc)
        let in2027 = baseline.untrackedBytes(inYear: 2027, calendar: Self.utc)

        #expect(in2026.isEstimate && in2027.isEstimate)
        #expect(abs(in2026.bytes + in2027.bytes - 1_000_000) <= 1)
        // Nov 1 to Mar 1: 61 days in 2026 and 59 in 2027.
        #expect(in2026.bytes > in2027.bytes)
    }

    // MARK: - History file from older versions

    /// 1.0 wrote `totalFreedBytes`. One unreadable entry must not cost the rest,
    /// since a file that fails to load is overwritten by the next clean.
    @Test
    func historyFileSkipsAnUnreadableEntryAndReadsTheOldFormat() throws {
        let json = """
        {"entries": [
          {"id": "4EB0ED77-9878-441E-A66C-2747DD315B74", "date": "2026-05-20T10:00:00Z", "trigger": "manual",
           "totalFreedBytes": 42, "deletedItems": [{"path": "/Users/me/.npm", "sizeBytes": 42}]},
          {"id": "not-a-uuid", "date": "yesterday"},
          {"id": "5EB0ED77-9878-441E-A66C-2747DD315B74", "date": "2026-05-21T10:00:00Z", "trigger": "scheduled",
           "bytesMovedToTrash": 7, "deletedItems": [], "skippedItems": []}
        ]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let file = try decoder.decode(CleanupHistoryFile.self, from: Data(json.utf8))

        #expect(file.entries.map(\.bytesMovedToTrash) == [42, 7])
    }

    // MARK: - Totals

    @Test
    func totalsAddUpTheYear() {
        func session(
            _ date: Date,
            _ source: CleanupSource,
            trigger: CleanupTrigger = .manual,
            imported: Bool = false,
            items: [(String, String, Int64)]
        ) -> CleanupLedgerSession {
            let ledgerItems = items.map {
                CleanupLedgerItem(path: $0.0, bytes: $0.2, label: $0.1, movedToTrash: true)
            }
            return CleanupLedgerSession(
                id: UUID(),
                date: date,
                trigger: trigger,
                source: source,
                bytesMovedToTrash: ledgerItems.reduce(0) { $0 + $1.bytes },
                bytesRemovedDirectly: 0,
                bytesReclaimedOnVolume: nil,
                skippedForSafetyCount: 1,
                failedCount: 0,
                importedFromHistory: imported,
                items: ledgerItems
            )
        }

        let sessions = [
            session(Self.date(2026, 3, 2), .clean, trigger: .scheduled, items: [("~/Library/Caches/Dia", "Dia", 300)]),
            session(Self.date(2026, 1, 10), .clean, imported: true, items: [
                ("~/Library/Developer/Xcode/DerivedData", "Xcode", 1_000),
                ("~/Library/Caches/Dia", "Dia", 200),
            ]),
            session(Self.date(2026, 3, 2), .uninstall, items: [
                ("/Applications/Slack.app", "Slack", 700),
                ("~/Library/Caches/com.tinyspeck.slackmacgap", "Slack", 50),
            ]),
            session(Self.date(2025, 12, 30), .clean, items: [("~/.npm", "npm", 9_999)]),
        ]

        let totals = CleanupYearTotals.compute(year: 2026, sessions: sessions, calendar: Self.utc)

        #expect(totals.cleanCount == 3)
        #expect(totals.scheduledCleanCount == 1)
        #expect(totals.manualCleanCount == 2)
        #expect(totals.activeDayCount == 2)
        #expect(totals.itemCount == 5)
        #expect(totals.bytesCleared == 2_250)
        #expect(totals.skippedForSafetyCount == 3)
        #expect(totals.firstRecordedDate == Self.date(2026, 1, 10))
        #expect(totals.includesImportedHistory)
        #expect(totals.bytesByMonth[0] == 1_200)
        #expect(totals.bytesByMonth[2] == 1_050)
        #expect(totals.bytesBySource[.uninstall] == 750)
        #expect(totals.labels.map(\.label) == ["Xcode", "Slack", "Dia"])
        #expect(totals.labels.first { $0.label == "Dia" }?.itemCount == 2)
        #expect(totals.biggestItem?.label == "Xcode")
        #expect(totals.biggestClean?.bytes == 1_200)
        #expect(totals.uninstalledApps == ["Slack"])
    }
}

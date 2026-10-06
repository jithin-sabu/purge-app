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

    // MARK: - Importing history

    @Test
    func historyImportRunsOnceAndSkipsCleansAlreadyRecorded() {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Self.makeStore(directory)

        let sharedID = UUID()
        store.record(
            Self.report([DeletedItem(path: "/Users/me/.npm", sizeBytes: 10)], on: Self.date(2026, 5, 2)),
            id: sharedID,
            trigger: .manual,
            source: .clean
        )

        let entries = [
            CleanupHistoryEntry(
                id: sharedID,
                date: Self.date(2026, 5, 2),
                trigger: .manual,
                bytesMovedToTrash: 10,
                deletedItems: [CleanupHistoryDeletedItemDTO(path: "/Users/me/.npm", sizeBytes: 10)]
            ),
            CleanupHistoryEntry(
                date: Self.date(2026, 5, 1),
                trigger: .manual,
                bytesMovedToTrash: 500,
                deletedItems: [
                    CleanupHistoryDeletedItemDTO(path: "/Applications/Slack.app", sizeBytes: 400),
                    CleanupHistoryDeletedItemDTO(path: "/Users/me/Library/Caches/com.tinyspeck.slackmacgap", sizeBytes: 100),
                ]
            ),
            CleanupHistoryEntry(date: Self.date(2026, 5, 3), trigger: .scheduled, bytesMovedToTrash: 0, deletedItems: []),
        ]

        store.importHistoryIfNeeded(entries)
        store.importHistoryIfNeeded(entries)

        let sessions = store.sessions(inYear: 2026)
        #expect(sessions.count == 2)
        let imported = sessions.filter(\.importedFromHistory)
        #expect(imported.count == 1)
        #expect(imported.first?.source == .uninstall)
        #expect(imported.first?.items.map(\.label) == ["Slack", "slackmacgap"])
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

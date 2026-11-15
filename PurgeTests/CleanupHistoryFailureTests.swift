import Foundation
import Testing
@testable import Purge

/// Cleanup History keeps what a clean couldn't remove and why, so a clean where
/// everything failed is not an empty entry that reads "0 items to trash" (#303).
/// The paths do not exist on disk and nothing reaches the engine.
@MainActor
@Suite("Cleanup History failed items")
struct CleanupHistoryFailureTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private var cachePath: String {
        home.appendingPathComponent("Library/Caches/com.example.app").path
    }

    private func report(deleted: [DeletedItem] = [], failed: [FailedDeletionItem]) -> DeletionReport {
        DeletionReport(
            bytesMovedToTrash: deleted.reduce(0) { $0 + $1.sizeBytes },
            bytesRemovedDirectly: 0,
            deletedItems: deleted,
            failedItems: failed,
            skippedItems: [],
            capacityBefore: nil,
            capacityAfter: nil,
            timestamp: Date()
        )
    }

    private func roundTrip(_ entry: CleanupHistoryEntry) throws -> CleanupHistoryEntry {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CleanupHistoryEntry.self, from: encoder.encode(entry))
    }

    /// The case from the issue: an uninstall of root-owned App Store apps where
    /// every item failed.
    @Test func aCleanWhereEverythingFailedKeepsEachItemAndItsReason() {
        let entry = CleanupHistoryStore.entry(id: UUID(), trigger: .manual, report: report(failed: [
            FailedDeletionItem(path: "/Applications/Pages.app", displayName: "Pages", reason: .needsAdministrator, sizeBytes: 600_000_000),
            FailedDeletionItem(path: "/Applications/Numbers.app", displayName: "Numbers", reason: .needsAdministratorAccount, sizeBytes: 500_000_000),
            FailedDeletionItem(path: cachePath, displayName: nil, reason: .inUse),
        ]))

        #expect(entry.deletedItems.isEmpty)
        #expect(entry.failedItems.map(\.path) == ["/Applications/Pages.app", "/Applications/Numbers.app", cachePath])
        #expect(entry.failedItems.map(\.failureReason) == [.needsAdministrator, .needsAdministratorAccount, .inUse])
        #expect(entry.failedItems.map(\.sizeBytes) == [600_000_000, 500_000_000, 0])
    }

    @Test func aCleanWhereEverythingFailedSaysSoInsteadOfZeroToTrash() {
        let entry = CleanupHistoryStore.entry(id: UUID(), trigger: .manual, report: report(failed: [
            FailedDeletionItem(path: "/Applications/Pages.app", displayName: "Pages", reason: .needsAdministrator),
            FailedDeletionItem(path: "/Applications/Numbers.app", displayName: "Numbers", reason: .needsAdministrator),
        ]))
        let row = CleanupHistorySummaryRow(entry: entry)

        #expect(row.detailText == String(localized: "\(2) items couldn't be cleaned"))
    }

    @Test func oneFailureUsesTheSingular() {
        let entry = CleanupHistoryStore.entry(id: UUID(), trigger: .manual, report: report(failed: [
            FailedDeletionItem(path: cachePath, displayName: nil, reason: .unknown),
        ]))

        #expect(CleanupHistorySummaryRow(entry: entry).detailText == String(localized: "1 item couldn't be cleaned"))
    }

    @Test func aPartlyFailedCleanNamesBoth() {
        let entry = CleanupHistoryStore.entry(id: UUID(), trigger: .manual, report: report(
            deleted: [DeletedItem(path: cachePath, sizeBytes: 2_000)],
            failed: [FailedDeletionItem(path: "/Applications/Pages.app", displayName: "Pages", reason: .inUse)]
        ))
        let toTrash = String(localized: "\(1) \(String(localized: "item")) to trash")
        let failures = String(localized: "1 item couldn't be cleaned")

        #expect(CleanupHistorySummaryRow(entry: entry).detailText == String(localized: "\(toTrash), \(failures)"))
    }

    @Test func aCleanWithNoFailuresReadsAsBefore() {
        let entry = CleanupHistoryStore.entry(id: UUID(), trigger: .manual, report: report(
            deleted: [DeletedItem(path: cachePath, sizeBytes: 2_000)],
            failed: []
        ))

        #expect(CleanupHistorySummaryRow(entry: entry).detailText == String(localized: "\(1) \(String(localized: "item")) to trash"))
    }

    @Test func failedItemsSurviveSavingAndLoading() throws {
        let entry = CleanupHistoryStore.entry(id: UUID(), trigger: .manual, report: report(failed: [
            FailedDeletionItem(path: "/Applications/Pages.app", displayName: "Pages", reason: .needsAdministrator, sizeBytes: 600_000_000),
        ]))

        let loaded = try roundTrip(entry)

        #expect(loaded.failedItems == entry.failedItems)
        #expect(loaded.failedItems.first?.failureReason == .needsAdministrator)
    }

    /// Entries saved before #303 have no `failedItems` key.
    @Test func olderEntriesLoadWithNoFailures() throws {
        let json = """
        {"id":"\(UUID().uuidString)","date":"2026-10-31T22:45:53Z","trigger":"manual",
         "bytesMovedToTrash":0,"skippedItems":[],"deletedItems":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entry = try decoder.decode(CleanupHistoryEntry.self, from: Data(json.utf8))

        #expect(entry.failedItems.isEmpty)
    }

    /// A reason only a newer version knows still loads, and reads as unknown.
    @Test func anUnknownReasonReadsAsUnknown() throws {
        let json = """
        {"id":"\(UUID().uuidString)","date":"2026-10-31T22:45:53Z","trigger":"manual",
         "bytesMovedToTrash":0,"skippedItems":[],"deletedItems":[],
         "failedItems":[{"path":"\(cachePath)","sizeBytes":10,"reason":"someFutureReason"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entry = try decoder.decode(CleanupHistoryEntry.self, from: Data(json.utf8))

        #expect(entry.failedItems.first?.failureReason == .unknown)
    }

    @Test func theLedgerImportCountsTheFailures() {
        let entry = CleanupHistoryStore.entry(id: UUID(), trigger: .manual, report: report(
            deleted: [DeletedItem(path: cachePath, sizeBytes: 2_000)],
            failed: [
                FailedDeletionItem(path: "/Applications/Pages.app", displayName: "Pages", reason: .inUse),
                FailedDeletionItem(path: "/Applications/Numbers.app", displayName: "Numbers", reason: .inUse),
            ]
        ))

        #expect(CleanupLedgerStore.HistorySnapshot(entry).failedCount == 2)
    }
}

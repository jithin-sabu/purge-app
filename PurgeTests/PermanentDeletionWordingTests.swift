import Foundation
import Testing
@testable import Purge

/// Simulators and runtimes are deleted permanently through `simctl`, never moved to
/// the Trash. The confirm sheet lists them on their own, and History records them as
/// deleted, so neither promises they can be put back (#170). The paths do not exist
/// on disk and nothing reaches the engine.
@MainActor
@Suite("Permanent deletion in the confirm sheet")
struct DeletionConfirmSheetPermanentTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private func candidate(_ url: URL, level: SafetyLevel = .medium) -> PurgeStore.DeletionCandidate {
        PurgeStore.DeletionCandidate(
            title: url.lastPathComponent,
            path: url,
            sizeBytes: 1,
            safetyInfo: SafetyInfo(level: level, headline: url.lastPathComponent, explanation: "", recoverySteps: "", reinstallCommand: nil),
            reinstallCommand: nil,
            subtitle: nil,
            reinstallSafety: .notApplicable,
            gitStatus: .clean
        )
    }

    private func cacheFolder() -> URL {
        home.appendingPathComponent("Library/Caches/PurgePermanentSheetTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func deviceFolder() -> URL {
        home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(UUID().uuidString)", isDirectory: true)
    }

    private func runtime() -> SimulatorRuntime {
        SimulatorRuntime(
            id: "7AE1D6B6-5524-4FAD-B793-1D1C911E5269",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-3",
            platformName: "iOS",
            version: "26.3.1",
            build: "23D8133",
            kind: "Patchable Cryptex Disk Image",
            state: "Ready",
            sizeBytes: 8_393_503_393,
            lastUsedAt: nil,
            deviceCount: 0,
            locationURL: URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes/iOS_26.3.1", isDirectory: true),
            safetyInfo: SimulatorRuntime.safetyInfo(
                platformName: "iOS", version: "26.3.1", state: "Ready", sizeBytes: 8_393_503_393,
                lastUsedAt: nil, deviceCount: 0, isXcodeDefault: false
            )
        )
    }

    private func sheet(_ store: PurgeStore, _ picks: [PurgeStore.DeletionCandidate]) -> DeletionConfirmSheet {
        DeletionConfirmSheet(
            candidates: picks,
            permanentIDs: store.permanentlyDeletedCandidateIDs(in: picks),
            onCancel: {},
            onConfirm: {}
        )
    }

    @Test func trashOnlyKeepsTheTrashWording() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()

        let confirm = sheet(store, [candidate(cacheFolder(), level: .safe), candidate(cacheFolder())])

        #expect(confirm.permanentCandidates.isEmpty)
        #expect(confirm.title == String(localized: "Move selected items to Trash?"))
        #expect(confirm.primaryButtonTitle == String(localized: "Move \(2) to Trash"))
        #expect(confirm.sizeLine == String(localized: "Moving \(formatBytes(2)) to Trash"))
    }

    @Test func simulatorIsListedAsDeletedPermanently() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()
        let device = candidate(deviceFolder())

        let confirm = sheet(store, [candidate(cacheFolder(), level: .safe), device])

        #expect(confirm.permanentCandidates.map(\.id) == [device.id])
        #expect(confirm.title == String(localized: "Clean selected items?"))
        #expect(confirm.primaryButtonTitle == String(localized: "Clean \(2) Items"))
        #expect(confirm.message != String(localized: "Purge moves these to Trash. You can put anything back if you change your mind."))
        #expect(confirm.sizeLine == String(localized: "Moving \(formatBytes(1)) to Trash, freeing \(formatBytes(1))"))
    }

    @Test func runtimeIsListedAsDeletedPermanently() async {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let row = runtime()
        scans.developerEvents = [.simulatorRuntimeFound(row)]
        let store = scans.makeStore()
        await store.scanDeveloper()
        let runtimePick = candidate(row.locationURL)

        let confirm = sheet(store, [candidate(cacheFolder(), level: .safe), runtimePick])

        #expect(confirm.permanentCandidates.map(\.id) == [runtimePick.id])
    }

    /// A folder at a runtime-like path that no scanned runtime owns goes to the
    /// Trash like any other, so the sheet must not call it permanent.
    @Test func unknownRuntimePathIsNotPermanent() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()

        let confirm = sheet(store, [candidate(runtime().locationURL)])

        #expect(confirm.permanentCandidates.isEmpty)
    }

    @Test func onlySimulatorsSayDeletePermanently() {
        let scans = FakeScans()
        defer { scans.cleanUp() }
        let store = scans.makeStore()

        let confirm = sheet(store, [candidate(deviceFolder())])

        #expect(confirm.permanentCandidates.count == 1)
        #expect(confirm.title == String(localized: "Delete selected items permanently?"))
        #expect(confirm.primaryButtonTitle == String(localized: "Delete \(1) Permanently"))
        #expect(confirm.sizeLine == String(localized: "Freeing \(formatBytes(1))"))
    }
}

@MainActor
@Suite("Permanent deletion in Cleanup History")
struct CleanupHistoryPermanentTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private var devicePath: String {
        home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(UUID().uuidString)").path
    }

    private var cachePath: String {
        home.appendingPathComponent("Library/Caches/com.example.app").path
    }

    private func report(_ items: [DeletedItem]) -> DeletionReport {
        DeletionReport(
            bytesMovedToTrash: items.filter(\.movedToTrash).reduce(0) { $0 + $1.sizeBytes },
            bytesRemovedDirectly: items.filter { !$0.movedToTrash }.reduce(0) { $0 + $1.sizeBytes },
            deletedItems: items,
            failedItems: [],
            skippedItems: [],
            capacityBefore: nil,
            capacityAfter: nil,
            timestamp: Date()
        )
    }

    @Test func aCleanRecordsWhereEachItemWent() {
        let device = devicePath
        let entry = CleanupHistoryStore.entry(id: UUID(), trigger: .manual, report: report([
            DeletedItem(path: cachePath, sizeBytes: 2_000),
            DeletedItem(path: device, sizeBytes: 6_000_000_000, movedToTrash: false),
        ]))

        #expect(entry.trashedItems.map(\.path) == [cachePath])
        #expect(entry.permanentlyDeletedItems.map(\.path) == [device])
        #expect(entry.bytesMovedToTrash == 2_000)
        #expect(entry.bytesDeletedPermanently == 6_000_000_000)
    }

    /// The summary used to show "Zero KB · 1 item to trash" for a clean that only
    /// deleted a simulator.
    @Test func simulatorOnlyCleanIsNotDescribedAsTrash() {
        let entry = CleanupHistoryStore.entry(id: UUID(), trigger: .manual, report: report([
            DeletedItem(path: devicePath, sizeBytes: 6_000_000_000, movedToTrash: false),
        ]))
        let row = CleanupHistorySummaryRow(entry: entry)

        #expect(row.primaryFigure == formatBytes(6_000_000_000))
        #expect(row.detailText == String(localized: "\(1) deleted permanently"))
    }

    @Test func mixedCleanNamesBoth() {
        let entry = CleanupHistoryStore.entry(id: UUID(), trigger: .manual, report: report([
            DeletedItem(path: cachePath, sizeBytes: 2_000),
            DeletedItem(path: devicePath, sizeBytes: 3_000, movedToTrash: false),
        ]))
        let row = CleanupHistorySummaryRow(entry: entry)
        let toTrash = String(localized: "\(1) \(String(localized: "item")) to trash")
        let deleted = String(localized: "\(1) deleted permanently")

        #expect(row.primaryFigure == formatBytes(5_000))
        #expect(row.detailText == String(localized: "\(toTrash), \(deleted)"))
    }

    @Test func theFlagSurvivesSavingAndLoading() throws {
        let entry = CleanupHistoryStore.entry(id: UUID(), trigger: .manual, report: report([
            DeletedItem(path: devicePath, sizeBytes: 1, movedToTrash: false),
        ]))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let loaded = try decoder.decode(CleanupHistoryEntry.self, from: encoder.encode(entry))

        #expect(loaded.deletedItems.first?.movedToTrash == false)
    }

    /// Entries saved before #170 have no flag. Simulator device folders and system
    /// runtime volumes still read as deleted; everything else as moved to the Trash.
    @Test func olderEntriesAreReadFromThePath() throws {
        let json = """
        {"id":"\(UUID().uuidString)","date":"2026-10-09T21:00:00Z","trigger":"manual",
         "bytesMovedToTrash":2000,"skippedItems":[],
         "deletedItems":[{"path":"\(cachePath)","sizeBytes":2000},
                         {"path":"\(devicePath)","sizeBytes":3000},
                         {"path":"/Library/Developer/CoreSimulator/Volumes/iOS_22E238","sizeBytes":8825558354}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entry = try decoder.decode(CleanupHistoryEntry.self, from: Data(json.utf8))

        #expect(entry.deletedItems.allSatisfy { $0.movedToTrash == nil })
        #expect(entry.trashedItems.map(\.path) == [cachePath])
        #expect(entry.permanentlyDeletedItems.count == 2)
        #expect(entry.bytesDeletedPermanently == 8_825_561_354)
    }
}

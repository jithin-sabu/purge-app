import Foundation
import Testing
@testable import Purge

/// Nothing on the Everything else screens can reach `FileDeleter` (#159, #220).
///
/// Two checks. The source audit reads every file the feature is made of and
/// refuses any mention of the delete engine, the delete sheets, the selection
/// sets the Clean buttons read, or a checkbox: the screens are read only by
/// design, and a later change that adds a delete path has to fail here first.
/// The store check drives every action the screens expose against a store with
/// a fake walk and real folders, and sees that no deletion started and the
/// folders are still there.
@Suite("Everything else reaches no delete path")
struct EverythingElseNoDeleteTests {
    /// Every file that makes up the feature. A new file joins this list.
    /// The Overview's row lives in `EverythingElseView.swift` so it is read here.
    static let featureFiles = [
        "purge/Views/EverythingElseView.swift",
        "purge/Services/PurgeStore+EverythingElse.swift",
        "purge/Services/EverythingElseMeasurer.swift",
        "purge/Models/EverythingElseGroup.swift",
        "purge/Models/EverythingElseMeasurement.swift",
        "purge/Models/EverythingElseSections.swift",
        "purge/Models/EverythingElseFolderHint.swift",
        "purge/Models/TreemapLayout.swift"
    ]

    /// Anything that moves a file, opens a delete sheet, or feeds a Clean button.
    static let forbidden = [
        "FileDeleter",
        "deleteItems",
        "deleteUserSelectedFiles",
        "trashItem",
        "removeItem",
        "moveItem",
        "unlink",
        "rmdir",
        "Process(",
        "DeletionCandidate",
        "DeletionSession",
        "showDeletionSheet",
        "showLargeFileDeletionSheet",
        "pendingUnknownDeletion",
        "scanSelection",
        "largeFileSelection",
        "selectedAppIDs",
        "orphanSelectedIDs",
        "Toggle(",
        "toggleStyle(.checkbox)",
        "Move to Trash",
        "cleanSafeItems",
        "performSafeCleanup",
        "confirmLargeFileDeletion",
        "confirmUninstallPlan",
        "uninstallPlan",
        "NSWorkspace.shared.recycle",
        "simctl",
        "tmutil"
    ]

    /// Whole-word: `onExpand()` is not `Toggle(`, but `Toggle(` and `.Toggle(` are.
    private static func mentions(_ word: String, in code: String) -> Bool {
        var searchRange = code.startIndex..<code.endIndex
        while let range = code.range(of: word, range: searchRange) {
            let before = range.lowerBound == code.startIndex ? nil : code[code.index(before: range.lowerBound)]
            if before == nil || !(before!.isLetter || before!.isNumber || before! == "_") {
                return true
            }
            searchRange = range.upperBound..<code.endIndex
        }
        return false
    }

    private static var repoRoot: URL {
        // PurgeTests/EverythingElseNoDeleteTests.swift sits one folder under the root.
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func theFeatureFilesNeverMentionADeletePath() throws {
        for relative in Self.featureFiles {
            let url = Self.repoRoot.appendingPathComponent(relative)
            let source = try #require(try? String(contentsOf: url, encoding: .utf8), "missing \(relative)")
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                // Comments may say "no Move to Trash here"; the code may not.
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                for word in Self.forbidden where Self.mentions(word, in: code) {
                    Issue.record("\(relative):\(number + 1) mentions \(word): \(code)")
                }
            }
        }
    }

    @Test func theOnlyWayOffTheScreensIsTheExcludedPathsList() throws {
        // The store extension the screens call: its surface is the walk, the
        // breakdown, navigation, hints and excluding. Pinned here so a new
        // method has to be added to this list on purpose. Every `func` counts,
        // whatever comes before it on the line.
        let url = Self.repoRoot.appendingPathComponent("purge/Services/PurgeStore+EverythingElse.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8))
        let pattern = try NSRegularExpression(pattern: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let functions = pattern.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
        #expect(Set(functions) == [
            "showEverythingElsePage",
            "showOverviewSummary",
            "measureEverythingElseAgain",
            "stopEverythingElse",
            "measureEverythingElse",
            "everythingElseBreakdown",
            "hideFromEverythingElse",
            "everythingElseOwningApp",
            "everythingElseFolderHint",
            "performEverythingElseHint",
            "droppingFolders"
        ])
        // The views add nothing to the store of their own.
        for relative in Self.featureFiles where relative != "purge/Services/PurgeStore+EverythingElse.swift" {
            let file = try #require(try? String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8))
            #expect(!file.contains("extension PurgeStore"), Comment(rawValue: relative))
        }
    }

    @MainActor
    @Test func everyActionLeavesTheFoldersAndStartsNoDeletion() async throws {
        let fake = FakeScans()
        fake.hasAccess = true
        let store = fake.makeStore()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("purge-ee-nodelete-\(UUID().uuidString)", isDirectory: true)
        let support = base.appendingPathComponent("Application Support", isDirectory: true)
        let big = support.appendingPathComponent("Big", isDirectory: true)
        let small = support.appendingPathComponent("Small", isDirectory: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
        try Data(count: 10).write(to: big.appendingPathComponent("keep.bin"))
        defer {
            try? FileManager.default.removeItem(at: base)
            ExcludedPathsStore.remove(path: big)
        }

        let root = EverythingElseMeasureRoot(group: .appData, url: support, kind: .children, isLockedWithoutAccess: false)
        fake.everythingElseEvents = [
            .planned([root]),
            .measured(EverythingElseMeasuredRoot(root: root, folders: [
                OverviewSizedItem(path: big.path, bytes: 5_000_000_000),
                OverviewSizedItem(path: small.path, bytes: 1_000)
            ], looseFileBytes: 0)),
            .macOS(14_000_000_000)
        ]
        let safeBefore = store.safeRecoverableBytes

        store.showEverythingElsePage()
        #expect(await eventually { store.everythingElsePhase == .ready })
        let breakdown = try #require(store.everythingElseBreakdown(totalBytes: 500_000_000_000, freeBytes: 100_000_000_000, trashBytes: 0))
        _ = EverythingElseSection.sections(for: breakdown)
        _ = EverythingElseSection.sections(for: breakdown, onlyGroup: .appData)
        let folder = try #require(breakdown[.appData]?.folders.first)

        // The walk feeds no category and nothing to Clean Safe Items.
        #expect(store.safeRecoverableBytes == safeBefore)
        #expect(ScanStep.everythingElse.categories.isEmpty)
        for category in OverviewCategory.allCases {
            #expect(category.step != .everythingElse)
        }

        // Every store action the screens can call, short of opening another app.
        store.performEverythingElseHint(.showInDevTools)
        store.performEverythingElseHint(.showInLargeFiles)
        _ = store.everythingElseFolderHint(for: folder)
        _ = store.everythingElseOwningApp(for: folder)
        store.hideFromEverythingElse(folder)
        store.showOverviewSummary()
        store.measureEverythingElseAgain()
        #expect(await eventually { store.everythingElsePhase == .ready })
        store.stopEverythingElse()

        #expect(!store.isDeleting)
        #expect(!store.showDeletionSheet)
        #expect(!store.showLargeFileDeletionSheet)
        #expect(store.deletionSheetCandidates == nil)
        #expect(store.pendingUnknownDeletion == nil)
        #expect(store.manualDeletionSession == nil)
        #expect(store.interactiveSafeCleanupSession == nil)
        #expect(store.uninstallPlan == nil)
        #expect(store.orphanCleanupPlan == nil)
        #expect(store.lastDeletionReport == nil)
        #expect(FileManager.default.fileExists(atPath: big.appendingPathComponent("keep.bin").path))
        #expect(FileManager.default.fileExists(atPath: small.path))
        // Hiding adds to the Excluded Paths list and moves nothing.
        #expect(ExcludedPathsStore.isExcluded(big))
        #expect(store.selectedTab == .largeFiles)
        fake.cleanUp()
    }

    private func eventually(timeout: TimeInterval = 30, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

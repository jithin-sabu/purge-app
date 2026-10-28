import Foundation
import Testing
@testable import Purge

/// The removal sheets said "Freeing X" for moves to the Trash, which free
/// nothing until the Trash is emptied (#191). Only what is deleted permanently
/// may be called freed.
@MainActor
@Suite("Removal sheets call only permanent deletes freed")
struct RemovalSizeLineTests {
    @Test
    func trashOnlyIsNotFreed() {
        let line = RemovalSizeLine.text(toTrash: 2_000_000)
        #expect(line == String(localized: "Moving \(formatBytes(2_000_000)) to Trash"))
        #expect(!line.contains("Freeing"))
    }

    @Test
    func permanentOnlyIsFreed() {
        #expect(RemovalSizeLine.text(toTrash: nil, permanently: 3_000_000)
            == String(localized: "Freeing \(formatBytes(3_000_000))"))
    }

    @Test
    func mixedNamesBoth() {
        #expect(RemovalSizeLine.text(toTrash: 2_000_000, permanently: 3_000_000)
            == String(localized: "Moving \(formatBytes(2_000_000)) to Trash, freeing \(formatBytes(3_000_000))"))
    }

    /// A pick with no measured size still goes somewhere, so an empty total is
    /// `nil` only when nothing goes that way.
    @Test
    func totalsAreNilOnlyForAnEmptyList() {
        #expect(RemovalSizeLine.total([Int64](), { $0 }) == nil)
        #expect(RemovalSizeLine.total([Int64(0)], { $0 }) == 0)
        #expect(RemovalSizeLine.total([Int64(2), 3], { $0 }) == 5)
    }

    /// Script installs go to the Trash. A package manager deletes its tools
    /// permanently, so only those are freed. Nothing here runs or exists on disk.
    @Test
    func commandLineToolsSplitTrashFromManagers() {
        let script = StandaloneCommandLineTool(
            install: CommandLineToolInstall(
                name: "tool",
                folder: URL(fileURLWithPath: "/nonexistent/PurgeRemovalSizeLineTests/.tool", isDirectory: true),
                shims: [], launchAgents: [], kept: [], source: .shim
            ),
            sizeBytes: 2_000_000,
            settingsFiles: []
        )
        let managed = PackageManagerTool(
            manager: .homebrew, name: "jq",
            locations: [URL(fileURLWithPath: "/nonexistent/PurgeRemovalSizeLineTests/jq", isDirectory: true)],
            context: nil, executable: nil, arguments: [], environment: [:], sizeBytes: 3_000_000
        )

        #expect(CommandLineToolReviewSheet.sizeLine(for: CommandLineToolRemovalPlan(tools: [script], managed: []))
            == String(localized: "Moving \(formatBytes(2_000_000)) to Trash"))
        #expect(CommandLineToolReviewSheet.sizeLine(for: CommandLineToolRemovalPlan(tools: [], managed: [managed]))
            == String(localized: "Freeing \(formatBytes(3_000_000))"))
        #expect(CommandLineToolReviewSheet.sizeLine(for: CommandLineToolRemovalPlan(tools: [script], managed: [managed]))
            == String(localized: "Moving \(formatBytes(2_000_000)) to Trash, freeing \(formatBytes(3_000_000))"))
    }
}

/// The wording checks below read the English text. The test host runs in the
/// Mac's language, so on a Mac set to Simplified Chinese they are skipped.
private nonisolated let testHostRunsInEnglish = Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? false

/// The auto-clean info said "Your actual work is never deleted", a promise no
/// cleaner can make, and never said where the items go (#191).
@MainActor
@Suite("Auto-clean info says where items go")
struct ScheduleSummaryWordingTests {
    @Test
    func summaryStartsWithHowOften() {
        let every = String(localized: "Every week")
        #expect(SettingsView.scheduleSummary(every: every).hasPrefix(every))
    }

    @Test(.enabled(if: testHostRunsInEnglish, "Reads the English wording"))
    func summaryNamesTheTrashAndMakesNoGuarantee() {
        let text = SettingsView.scheduleSummary(every: "Every week")
        #expect(text.contains("to the Trash"))
        #expect(text.contains("Check First"))
        // Scheduled cleans take dependency folders like node_modules too, not only build output.
        #expect(text.contains("dependency folders"))
        #expect(!text.contains("never deleted"))
    }
}

import Testing
@testable import Purge

/// The Run now alert in Settings says why nothing ran. "Nothing matched your safe
/// settings" used to cover a run skipped for another clean or an open review,
/// and a run that failed (#173).
@Suite("Run now message")
@MainActor
struct RunNowMessageTests {
    private typealias Summary = PurgeStore.ScheduledCleaningSummary

    @Test("Each way a run can end gets its own message")
    func eachOutcomeHasItsOwnMessage() {
        let off = SettingsView.scheduledCleanNowMessage(for: nil)
        let nothingMatched = SettingsView.scheduledCleanNowMessage(
            for: Summary(deletedCount: 0, bytesMovedToTrash: 0)
        )
        let skipped = SettingsView.scheduledCleanNowMessage(
            for: Summary(deletedCount: 0, bytesMovedToTrash: 0, skippedForAnotherClean: true)
        )
        let failed = SettingsView.scheduledCleanNowMessage(
            for: Summary(deletedCount: 0, bytesMovedToTrash: 0, failed: true)
        )
        let moved = SettingsView.scheduledCleanNowMessage(
            for: Summary(deletedCount: 2, bytesMovedToTrash: 1_024)
        )

        let messages = [off, nothingMatched, skipped, failed, moved]
        #expect(Set(messages).count == messages.count)
        #expect(messages.allSatisfy { !$0.isEmpty })
    }
}

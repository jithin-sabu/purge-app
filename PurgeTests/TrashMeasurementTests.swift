import Foundation
import Testing
@testable import Purge

private typealias Reading = TrashStore.TrashReading
private typealias Location = TrashStore.LocationReading

/// The trash total is sized by shelling out to `du`, which reports 0 both for an empty
/// trash and for a measurement that failed or was starved — and starvation is routine
/// during scans and deletions, where many `du` processes run at once. These tests pin the
/// rules that keep a failed pass from resetting the "In Trash" count to zero.
@Suite("Trash measurement resolution")
struct TrashMeasurementTests {
    private func reading(entries: Int, measured: Int64?) -> Reading {
        Reading(listing: .counted(entries: entries), measuredBytes: measured)
    }

    @Test func permissionDenialReportsUnreadable() {
        #expect(
            TrashStore.resolveMeasurement(Reading(listing: .permissionDenied, measuredBytes: nil))
                == .unreadable
        )
    }

    @Test func emptyTrashPublishesZero() {
        // The one case where 0 is the truth, not a failed measurement.
        #expect(TrashStore.resolveMeasurement(reading(entries: 0, measured: 0)) == .apply(bytes: 0))
    }

    @Test func nonEmptyTrashWithRealSizePublishesIt() {
        #expect(
            TrashStore.resolveMeasurement(reading(entries: 12, measured: 5_000_000_000))
                == .apply(bytes: 5_000_000_000)
        )
    }

    /// A regression this feature exists to prevent: a non-empty trash that measured 0
    /// bytes is a starved `du`, not an empty trash. It must not overwrite the known total.
    @Test func nonEmptyTrashThatMeasuredZeroIsKeptAndRetried() {
        #expect(TrashStore.resolveMeasurement(reading(entries: 12, measured: 0)) == .keepAndRetry)
    }

    /// `du` producing no reading at all is not a measurement of zero: it means the run was
    /// refused or starved, so it cannot zero a trash that listed entries either.
    @Test func nonEmptyTrashWithNoMeasurementIsKeptAndRetried() {
        #expect(TrashStore.resolveMeasurement(reading(entries: 12, measured: nil)) == .keepAndRetry)
    }

    /// The other regression: a directory listing that failed under load (file-descriptor
    /// exhaustion during a clean, say) says nothing about the trash. Treating it as "no
    /// Full Disk Access" would zero the total and cancel the retry, sticking at zero.
    @Test func transientReadFailureIsKeptAndRetried() {
        #expect(
            TrashStore.resolveMeasurement(Reading(listing: .failed, measuredBytes: nil))
                == .keepAndRetry
        )
    }
}

/// "The Trash" the user sees in Finder is not one directory. A file that lives in iCloud
/// Drive — which covers Desktop and Documents when "Desktop & Documents Folders" is on — is
/// trashed to `~/Library/Mobile Documents/.Trash`, not `~/.Trash`. Counting only the latter is
/// what made "In trash" report 152 KB of Purge's own cleaned caches while Finder showed
/// 749 MB, and what made it ignore everything the user deleted in Finder. These tests pin how
/// the directories fold into one figure.
@Suite("Trash location aggregation")
struct TrashLocationAggregationTests {
    @Test func sizesFromEveryTrashAreSummed() {
        let combined = TrashStore.combine([
            .counted(entries: 15, bytes: 155_648),
            .counted(entries: 90, bytes: 749_113_344)
        ])
        #expect(combined == Reading(listing: .counted(entries: 105), measuredBytes: 749_268_992))
        #expect(TrashStore.resolveMeasurement(combined) == .apply(bytes: 749_268_992))
    }

    /// The reported bug in miniature: the home trash holds a few KB of cleaned caches and the
    /// iCloud trash holds everything the user deleted. Reporting only the first is the failure.
    @Test func iCloudTrashDominatesTheTotal() {
        let combined = TrashStore.combine([
            .counted(entries: 15, bytes: 155_648),
            .counted(entries: 90, bytes: 749_113_344)
        ])
        #expect(combined.measuredBytes ?? 0 > 700_000_000)
    }

    /// iCloud Drive turned off, or simply nothing ever deleted from it: that directory does not
    /// exist. It holds nothing and hides nothing, so it must neither block the pass nor make it
    /// retry — an absent directory retried every 1.2 s would never settle.
    @Test func missingTrashContributesNothingAndStillResolves() {
        let combined = TrashStore.combine([.counted(entries: 15, bytes: 155_648), .missing])
        #expect(combined == Reading(listing: .counted(entries: 15), measuredBytes: 155_648))
        #expect(TrashStore.resolveMeasurement(combined) == .apply(bytes: 155_648))
    }

    @Test func allTrashesMissingReadsAsEmpty() {
        let combined = TrashStore.combine([.missing, .missing])
        #expect(TrashStore.resolveMeasurement(combined) == .apply(bytes: 0))
    }

    /// One trash refused while another counts fine must not publish the half it could see: a
    /// total that silently omits a directory is a wrong number, which is worse than admitting
    /// the trash cannot be counted.
    @Test func aDenialAnywhereMakesTheWholeTotalUnreadable() {
        let combined = TrashStore.combine([
            .permissionDenied,
            .counted(entries: 90, bytes: 749_113_344)
        ])
        #expect(combined.listing == .permissionDenied)
        #expect(TrashStore.resolveMeasurement(combined) == .unreadable)
    }

    /// Same reasoning for a transient failure, except that one keeps the last good total
    /// instead of claiming the trash is off limits.
    @Test func aFailureAnywhereKeepsTheLastGoodTotal() {
        let combined = TrashStore.combine([.failed, .counted(entries: 90, bytes: 749_113_344)])
        #expect(TrashStore.resolveMeasurement(combined) == .keepAndRetry)
    }

    /// One trash measured, one starved: the sum would be an understatement, so the pass keeps
    /// the previous total and tries again rather than publishing a dip.
    @Test func oneStarvedMeasurementInvalidatesTheSum() {
        let combined = TrashStore.combine([
            .counted(entries: 15, bytes: 155_648),
            .counted(entries: 90, bytes: nil)
        ])
        #expect(combined.measuredBytes == nil)
        #expect(TrashStore.resolveMeasurement(combined) == .keepAndRetry)
    }

    /// The directories the store actually watches: the home trash and the iCloud trash, in
    /// that order, both on this volume. Other volumes' trashes are deliberately excluded —
    /// their bytes are not on this volume.
    @Test func trashDirectoriesCoverHomeAndICloud() {
        let paths = TrashStore.trashDirectories().map(\.path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(paths == ["\(home)/.Trash", "\(home)/Library/Mobile Documents/.Trash"])
    }
}

/// Only a genuine permission error may put the store in `.unreadable` — that state zeroes
/// the published total, so misclassifying a transient failure resets "In Trash" to zero.
@Suite("Trash read-error classification")
struct TrashPermissionDenialTests {
    @Test func cocoaNoPermissionErrorIsDenial() {
        let error = CocoaError(.fileReadNoPermission)
        #expect(TrashStore.isPermissionDenial(error))
    }

    @Test func posixPermissionErrorsAreDenial() {
        #expect(TrashStore.isPermissionDenial(POSIXError(.EACCES)))
        #expect(TrashStore.isPermissionDenial(POSIXError(.EPERM)))
    }

    /// The shape TCC denials actually arrive in: a Cocoa wrapper with the POSIX code
    /// buried one level down as the underlying error.
    @Test func nestedUnderlyingPermissionErrorIsDenial() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        #expect(TrashStore.isPermissionDenial(wrapped))
    }

    @Test func exhaustionAndInterruptionAreNotDenial() {
        #expect(!TrashStore.isPermissionDenial(POSIXError(.EMFILE)))
        #expect(!TrashStore.isPermissionDenial(POSIXError(.EINTR)))
        #expect(!TrashStore.isPermissionDenial(CocoaError(.fileReadUnknown)))
    }
}

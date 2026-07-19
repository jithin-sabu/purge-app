import Foundation
import Testing
@testable import Purge

/// The trash total is sized by shelling out to `du`, which reports 0 both for an empty
/// trash and for a measurement that failed or was starved — and starvation is routine
/// during scans and deletions, where many `du` processes run at once. These tests pin the
/// rules that keep a failed pass from resetting the "In Trash" count to zero.
@Suite("Trash measurement resolution")
struct TrashMeasurementTests {
    @Test func permissionDenialReportsUnreadable() {
        #expect(TrashStore.resolveMeasurement(.permissionDenied) == .unreadable)
    }

    @Test func emptyTrashPublishesZero() {
        // The one case where 0 is the truth, not a failed measurement.
        #expect(TrashStore.resolveMeasurement(.empty) == .apply(bytes: 0))
    }

    @Test func nonEmptyTrashWithRealSizePublishesIt() {
        #expect(
            TrashStore.resolveMeasurement(.nonEmpty(measuredBytes: 5_000_000_000))
                == .apply(bytes: 5_000_000_000)
        )
    }

    /// A regression this feature exists to prevent: a non-empty trash that measured 0
    /// bytes is a starved `du`, not an empty trash. It must not overwrite the known total.
    @Test func nonEmptyTrashThatMeasuredZeroIsKeptAndRetried() {
        #expect(TrashStore.resolveMeasurement(.nonEmpty(measuredBytes: 0)) == .keepAndRetry)
    }

    /// The other regression: a directory listing that failed under load (file-descriptor
    /// exhaustion during a clean, say) says nothing about the trash. Treating it as "no
    /// Full Disk Access" would zero the total and cancel the retry, sticking at zero.
    @Test func transientReadFailureIsKeptAndRetried() {
        #expect(TrashStore.resolveMeasurement(.readFailed) == .keepAndRetry)
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

import Foundation
import Testing
@testable import Purge

@Suite("CleanFailureReason error mapping")
struct CleanFailureReasonTests {
    @Test func dropsFileNotFoundPOSIX() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        #expect(CleanFailureReason.from(error: error) == nil)
    }

    @Test func dropsFileNotFoundCocoa() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        #expect(CleanFailureReason.from(error: error) == nil)
    }

    @Test(arguments: [
        (NSPOSIXErrorDomain, Int(EACCES), CleanFailureReason.needsFullDiskAccess),
        (NSPOSIXErrorDomain, Int(EPERM), CleanFailureReason.needsFullDiskAccess),
        (NSPOSIXErrorDomain, Int(EBUSY), CleanFailureReason.inUse),
        (NSPOSIXErrorDomain, Int(EROFS), CleanFailureReason.systemProtected),
        (NSCocoaErrorDomain, NSFileWriteNoPermissionError, CleanFailureReason.needsFullDiskAccess),
        (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError, CleanFailureReason.systemProtected),
    ])
    func mapsKnownErrors(domain: String, code: Int, expected: CleanFailureReason) {
        let error = NSError(domain: domain, code: code)
        #expect(CleanFailureReason.from(error: error) == expected)
    }

    @Test func mapsUnknownErrors() {
        let error = NSError(domain: "TestDomain", code: 999)
        #expect(CleanFailureReason.from(error: error) == .unknown)
    }

    @Test(arguments: [
        (NSPOSIXErrorDomain, Int(EACCES)),
        (NSPOSIXErrorDomain, Int(EPERM)),
        (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
    ])
    func upgradesPermissionErrorsWhenFullDiskAccessGranted(domain: String, code: Int) {
        let error = NSError(domain: domain, code: code)
        #expect(CleanFailureReason.from(error: error) == .needsFullDiskAccess)
        #expect(
            CleanFailureReason.resolved(from: error, fullDiskAccessGranted: true)
                == .systemProtected
        )
        #expect(
            CleanFailureReason.resolved(from: error, fullDiskAccessGranted: false)
                == .needsFullDiskAccess
        )
    }

    @Test func preservesNonPermissionReasonsWhenFullDiskAccessGranted() {
        let busy = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        #expect(
            CleanFailureReason.resolved(from: busy, fullDiskAccessGranted: true) == .inUse
        )
    }
}

@Suite("TimeTagline fact part")
struct TimeTaglineFactPartTests {
    @Test func selectionExposesFactAndQuip() {
        let defaults = UserDefaults(suiteName: "TimeTaglineTests.fact")!
        defaults.removePersistentDomain(forName: "TimeTaglineTests.fact")

        let selection = TimeTagline.select(for: 2, defaults: defaults)
        #expect(selection.factPart == "done in 2 seconds")
        #expect(selection.line == "\(selection.factPart) · \(selection.quip)")
        #expect(TimeTagline.quips(for: 2).contains(selection.quip))
    }
}

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
    func permissionErrorOnAnOrdinaryFileIsUnknownWhenFullDiskAccessGranted(
        domain: String,
        code: Int
    ) throws {
        let error = NSError(domain: domain, code: code)
        let file = try Self.makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(CleanFailureReason.from(error: error) == .needsFullDiskAccess)
        // An ordinary user file is not protected by macOS, so we must not say it is.
        #expect(
            CleanFailureReason.resolved(from: error, path: file.path, fullDiskAccessGranted: true)
                == .unknown
        )
        #expect(
            CleanFailureReason.resolved(from: error, path: file.path, fullDiskAccessGranted: false)
                == .needsFullDiskAccess
        )
    }

    @Test func immutableFileIsReportedAsSystemProtected() throws {
        let file = try Self.makeTemporaryFile()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: file)
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)

        #expect(FileProtection.blocksRemoval(file))
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        #expect(
            CleanFailureReason.resolved(from: error, path: file.path, fullDiskAccessGranted: true)
                == .systemProtected
        )
    }

    @Test func ordinaryFileIsNotTreatedAsProtected() throws {
        let file = try Self.makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!FileProtection.blocksRemoval(file))
    }

    @Test func preservesNonPermissionReasonsWhenFullDiskAccessGranted() {
        let busy = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        #expect(
            CleanFailureReason.resolved(from: busy, path: "/tmp/none", fullDiskAccessGranted: true)
                == .inUse
        )
    }

    @Test func safetySkipsAreNotDescribedAsSystemProtection() {
        let skipped = SkippedDeletionItem(
            path: "/tmp/example",
            displayName: "example",
            reason: "This file was skipped for safety",
            isUserVisible: true
        )
        #expect(CleanFailureItem(skipped: skipped).reason == .safetySkipped)
    }

    private static func makeTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-protection-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        return url
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

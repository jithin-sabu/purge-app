import Foundation
import Testing
@testable import Purge

/// The rule that decides whether `macOS Install Data` holds leftovers from a finished
/// update (#127). Every test builds its own folder and system file with set dates.
@Suite("macOS install leftovers")
struct MacOSInstallLeftoversTests {
    private final class Fixture {
        let base: URL
        let root: URL
        let systemVersionFile: URL
        let systemDate: Date

        /// The rule also reads change times, which can't be set back, and a file made
        /// now has a change time of now. So the system file is dated a day ahead,
        /// unless a test needs it in the past.
        init(systemDate: Date = Date().addingTimeInterval(24 * 3600)) throws {
            self.systemDate = systemDate
            let fm = FileManager.default
            base = fm.temporaryDirectory
                .appendingPathComponent("MacOSInstallLeftoversTests-\(UUID().uuidString)", isDirectory: true)
            root = base.appendingPathComponent("macOS Install Data", isDirectory: true)
            systemVersionFile = base.appendingPathComponent("SystemVersion.plist")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            fm.createFile(atPath: systemVersionFile.path, contents: Data())
            try setDate(systemDate, at: systemVersionFile)
        }

        deinit {
            try? FileManager.default.removeItem(at: base)
        }

        var older: Date { systemDate.addingTimeInterval(-30 * 24 * 3600) }
        var newer: Date { systemDate.addingTimeInterval(24 * 3600) }

        @discardableResult
        func makeEntry(_ name: String, folder: Bool = true, date: Date? = nil) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: folder)
            if folder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
            }
            try setDate(date ?? older, at: url)
            return url
        }

        /// Adding entries bumps the folder's own date, so tests set it last.
        func setRootDate(_ date: Date) throws {
            try setDate(date, at: root)
        }

        func setDate(_ date: Date, at url: URL) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        func isLeftover() -> Bool {
            MacOSInstallLeftovers.isLeftover(root: root, systemVersionFile: systemVersionFile)
        }
    }

    @Test
    func oldFolderIsALeftover() throws {
        let fixture = try Fixture()
        try fixture.makeEntry("UpdateBundle")
        try fixture.makeEntry("InstallInfo.plist", folder: false)
        try fixture.setRootDate(fixture.older)
        #expect(fixture.isLeftover())
    }

    @Test
    func folderNewerThanTheSystemIsNot() throws {
        let fixture = try Fixture()
        try fixture.makeEntry("UpdateBundle")
        try fixture.setRootDate(fixture.newer)
        #expect(!fixture.isLeftover())
    }

    /// The folder's date moves only when entries are added or removed. An entry
    /// rewritten in place leaves it old, so each entry is checked too.
    @Test
    func anyNewerEntryMeansAnUpdateIsWaiting() throws {
        let fixture = try Fixture()
        try fixture.makeEntry("UpdateBundle")
        try fixture.makeEntry("Staged", date: fixture.newer)
        try fixture.setRootDate(fixture.older)
        #expect(!fixture.isLeftover())
    }

    /// `Locked Files` is never offered, but an update could be staged into it, so its
    /// date still counts. So do hidden items.
    @Test(arguments: [MacOSInstallLeftovers.lockedFilesName, ".staged"])
    func unofferedItemsStillCountForTheDate(name: String) throws {
        let fixture = try Fixture()
        try fixture.makeEntry("UpdateBundle")
        try fixture.makeEntry(name, date: fixture.newer)
        try fixture.setRootDate(fixture.older)
        #expect(!fixture.isLeftover())
    }

    /// Writing deep inside an entry leaves the folders above it with old dates.
    @Test
    func aNewerFileDeepInsideCounts() throws {
        let fixture = try Fixture()
        let bundle = try fixture.makeEntry("UpdateBundle")
        let nested = bundle.appendingPathComponent("Payload/Deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("chunk.pkg")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        try fixture.setDate(fixture.newer, at: file)
        for folder in [nested, nested.deletingLastPathComponent(), bundle] {
            try fixture.setDate(fixture.older, at: folder)
        }
        try fixture.setRootDate(fixture.older)
        #expect(!fixture.isLeftover())
    }

    /// Old modification dates are not enough: a file copied or unpacked with its
    /// original dates still has a fresh change time, newer than this system file.
    @Test
    func aFreshChangeTimeCountsEvenWithOldDates() throws {
        let fixture = try Fixture(systemDate: Date().addingTimeInterval(-3600))
        try fixture.makeEntry("UpdateBundle", date: Date().addingTimeInterval(-90 * 24 * 3600))
        try fixture.setRootDate(Date().addingTimeInterval(-90 * 24 * 3600))
        #expect(!fixture.isLeftover())
    }

    @Test
    func unreadableFolderInsideIsNot() throws {
        let fixture = try Fixture()
        let bundle = try fixture.makeEntry("UpdateBundle")
        let sealed = bundle.appendingPathComponent("Sealed", isDirectory: true)
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        try fixture.setDate(fixture.older, at: sealed)
        try fixture.setDate(fixture.older, at: bundle)
        try fixture.setRootDate(fixture.older)
        #expect(fixture.isLeftover())
        chmod(sealed.path, 0)
        defer { chmod(sealed.path, 0o755) }
        #expect(!fixture.isLeftover())
    }

    @Test
    func onlyLockedFilesIsNothingToOffer() throws {
        let fixture = try Fixture()
        try fixture.makeEntry(MacOSInstallLeftovers.lockedFilesName)
        try fixture.setRootDate(fixture.older)
        #expect(!fixture.isLeftover())
        #expect(MacOSInstallLeftovers.entries(root: fixture.root).isEmpty)
    }

    @Test
    func missingSystemFileOrFolderIsNot() throws {
        let fixture = try Fixture()
        try fixture.makeEntry("UpdateBundle")
        try fixture.setRootDate(fixture.older)
        let missing = fixture.base.appendingPathComponent("nope.plist")
        #expect(!MacOSInstallLeftovers.isLeftover(root: fixture.root, systemVersionFile: missing))
        let noFolder = fixture.base.appendingPathComponent("no folder", isDirectory: true)
        #expect(!MacOSInstallLeftovers.isLeftover(root: noFolder, systemVersionFile: fixture.systemVersionFile))
    }

    @Test
    func symlinkedFolderIsNot() throws {
        let fixture = try Fixture()
        try fixture.makeEntry("UpdateBundle")
        try fixture.setRootDate(fixture.older)
        let link = fixture.base.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        #expect(!MacOSInstallLeftovers.isLeftover(root: link, systemVersionFile: fixture.systemVersionFile))
    }

    @Test
    func entriesSkipLockedFilesAndHiddenItems() throws {
        let fixture = try Fixture()
        try fixture.makeEntry("UpdateBundle")
        try fixture.makeEntry("InstallInfo.plist", folder: false)
        try fixture.makeEntry(MacOSInstallLeftovers.lockedFilesName)
        try fixture.makeEntry(".DS_Store", folder: false)
        let names = MacOSInstallLeftovers.entries(root: fixture.root).map(\.lastPathComponent)
        #expect(names == ["InstallInfo.plist", "UpdateBundle"])
    }

    @Test
    func entryPathIsOneLevelDownOnly() {
        let root = MacOSInstallLeftovers.root.path
        #expect(MacOSInstallLeftovers.isEntryPath("\(root)/UpdateBundle"))
        #expect(!MacOSInstallLeftovers.isEntryPath(root))
        #expect(!MacOSInstallLeftovers.isEntryPath("\(root)/"))
        #expect(!MacOSInstallLeftovers.isEntryPath("\(root)/UpdateBundle/Payload"))
        #expect(!MacOSInstallLeftovers.isEntryPath("\(root)/Locked Files"))
        #expect(!MacOSInstallLeftovers.isEntryPath("\(root)/Locked Files/x"))
        #expect(!MacOSInstallLeftovers.isEntryPath("\(root)/.hidden"))
        #expect(!MacOSInstallLeftovers.isEntryPath("\(root)/.."))
        #expect(!MacOSInstallLeftovers.isEntryPath("\(root) Extra/UpdateBundle"))
        #expect(!MacOSInstallLeftovers.isEntryPath("/macOS Install Data/UpdateBundle"))
    }
}

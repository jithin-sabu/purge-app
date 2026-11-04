import Darwin
import Foundation
import Testing
@testable import Purge

/// The rule the root helper uses before it moves an item and before it hands each
/// file back to the user (#314). Any account can hard-link a root-owned file it can
/// read, such as a plist in `/Library/LaunchDaemons`, into a folder it owns. Moving
/// that link and changing its owner as root would give the account the original
/// file. Every case here is a real file in a temporary folder, read with `lstat`, as
/// the helper reads its open descriptor.
@Suite("The helper never hands back a file with a second name")
struct HelperLinkPolicyTests {
    private let fm = FileManager.default

    private func makeFolder() throws -> URL {
        let folder = fm.temporaryDirectory
            .appendingPathComponent("HelperLinkPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func info(_ url: URL) throws -> stat {
        var result = stat()
        try #require(lstat(url.path, &result) == 0)
        return result
    }

    @Test func aFileWithOneNameMovesAndIsHandedBack() throws {
        let folder = try makeFolder()
        defer { try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent("com.example.plist")
        try Data("x".utf8).write(to: file)

        let stat = try info(file)
        #expect(HelperLinkPolicy.refusal(forSourceMode: stat.st_mode, linkCount: stat.st_nlink, isAppBundlePath: false) == nil)
        #expect(HelperLinkPolicy.mayChangeOwner(mode: stat.st_mode, linkCount: stat.st_nlink))
    }

    /// The attack from the review: a leftover-looking name that is a second name for
    /// another file. It is refused as a source, and inside a moved folder it keeps
    /// its owner.
    @Test func aHardLinkIsNeverMovedOrHandedBack() throws {
        let folder = try makeFolder()
        defer { try? fm.removeItem(at: folder) }
        let original = folder.appendingPathComponent("com.vendor.daemon.plist")
        try Data("x".utf8).write(to: original)
        let link = folder.appendingPathComponent("com.example.plist")
        try #require(Darwin.link(original.path, link.path) == 0)

        let stat = try info(link)
        #expect(stat.st_nlink == 2)
        #expect(HelperLinkPolicy.refusal(forSourceMode: stat.st_mode, linkCount: stat.st_nlink, isAppBundlePath: false) == EMLINK)
        #expect(!HelperLinkPolicy.mayChangeOwner(mode: stat.st_mode, linkCount: stat.st_nlink))
    }

    /// A folder's link count includes its subfolders, so a real app bundle has more
    /// than one and must still move and be handed back.
    @Test func aFolderWithSubfoldersMovesAndIsHandedBack() throws {
        let folder = try makeFolder()
        defer { try? fm.removeItem(at: folder) }
        let bundle = folder.appendingPathComponent("Example.app", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)

        let stat = try info(bundle.appendingPathComponent("Contents"))
        #expect(stat.st_nlink > 1)
        #expect(HelperLinkPolicy.refusal(forSourceMode: stat.st_mode, linkCount: stat.st_nlink, isAppBundlePath: true) == nil)
        #expect(HelperLinkPolicy.mayChangeOwner(mode: stat.st_mode, linkCount: stat.st_nlink))
    }

    /// A path named like an app must be a folder. A file under that name is refused,
    /// even with one name.
    @Test func aFileNamedLikeAnAppIsRefused() throws {
        let folder = try makeFolder()
        defer { try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Example.app")
        try Data("x".utf8).write(to: file)

        let stat = try info(file)
        #expect(HelperLinkPolicy.refusal(forSourceMode: stat.st_mode, linkCount: stat.st_nlink, isAppBundlePath: true) == EFTYPE)
    }

    @Test func aFIFOOrSymlinkIsRefused() throws {
        let folder = try makeFolder()
        defer { try? fm.removeItem(at: folder) }
        let fifo = folder.appendingPathComponent("pipe")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        let symlink = folder.appendingPathComponent("link")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: folder)

        for url in [fifo, symlink] {
            let stat = try info(url)
            #expect(HelperLinkPolicy.refusal(forSourceMode: stat.st_mode, linkCount: stat.st_nlink, isAppBundlePath: false) == EFTYPE)
        }
    }
}

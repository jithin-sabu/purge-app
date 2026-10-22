import Foundation
import Testing
@testable import Purge

/// The default APFS volume ignores case, so `Developer` and `developer` open one
/// folder. On a case-sensitive volume they are two folders, with nothing to merge.
private let temporaryVolumeIgnoresCase: Bool = {
    let values = try? FileManager.default.temporaryDirectory
        .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    return values?.volumeSupportsCaseSensitiveNames == false
}()

@Suite("Each project is listed once, however its folder is spelled (#175)")
struct ProjectDiscoveryDedupeTests {
    private func kept(_ projects: [URL]) -> [String] {
        DevScanner.firstOfEachProject(projects.map { ($0, [ProjectType.node]) }).map { $0.0.path }
    }

    @Test(
        "Developer and developer are one folder, listed under the first spelling",
        .enabled(if: temporaryVolumeIgnoresCase, "only a case-insensitive volume makes the two spellings one folder")
    )
    func twoSpellings() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let upper = home.appendingPathComponent("Developer/app", isDirectory: true)
        try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: true)
        let lower = home.appendingPathComponent("developer/app", isDirectory: true)

        #expect(kept([upper, lower]) == [upper.path])
    }

    @Test("a root that links into another reaches the same project once")
    func linkAndTarget() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let real = home.appendingPathComponent("Developer/app", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("code"),
            withDestinationURL: home.appendingPathComponent("Developer")
        )
        let linked = home.appendingPathComponent("code/app", isDirectory: true)

        #expect(kept([real, linked]) == [real.path])
        #expect(kept([linked, real]) == [linked.path])
    }

    @Test("different projects are all kept, in the order found")
    func distinctProjects() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = home.appendingPathComponent("Developer/app", isDirectory: true)
        let second = home.appendingPathComponent("Developer/app-2", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        #expect(kept([first, second, first]) == [first.path, second.path])
    }

    @Test("a project whose folder can't be read is kept once, as before")
    func unreadableFolderKept() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let gone = home.appendingPathComponent("gone/app", isDirectory: true)
        let alsoGone = home.appendingPathComponent("also-gone/app", isDirectory: true)

        #expect(kept([gone, gone, alsoGone]) == [gone.path, alsoGone.path])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectDiscoveryDedupeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

import Foundation
import Testing
@testable import Purge

/// The Full Disk Access probe reads one entry of each folder rather than the whole
/// listing (#190). It must still fail wherever the full listing failed.
@Suite("Full Disk Access probe")
struct PermissionProbeTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-permission-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func folderWithEntriesPasses() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a", "b", "c"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        }
        #expect(PermissionChecker.canList(folder))
    }

    @Test func emptyFolderPasses() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(PermissionChecker.canList(folder))
    }

    @Test func missingFolderFails() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!PermissionChecker.canList(folder.appendingPathComponent("missing", isDirectory: true)))
    }

    /// The same refusal macOS gives a protected folder without access.
    @Test func unreadableFolderFails() throws {
        let folder = try makeFolder()
        let locked = folder.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: locked.appendingPathComponent("x").path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: folder)
        }
        #expect(throws: (any Error).self) {
            try FileManager.default.contentsOfDirectory(at: locked, includingPropertiesForKeys: nil)
        }
        #expect(!PermissionChecker.canList(locked))
    }

    @Test func fileIsNotAFolder() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("file.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        #expect(throws: (any Error).self) {
            try FileManager.default.contentsOfDirectory(at: file, includingPropertiesForKeys: nil)
        }
        #expect(!PermissionChecker.canList(file))
    }
}

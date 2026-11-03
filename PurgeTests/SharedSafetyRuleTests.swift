import Foundation
import Testing
@testable import Purge

/// The checks #185 moved out of the deletion gates into one place each. Every
/// gate now reads these, so a slip here reaches all of them.
@Suite("Shared safety rules")
struct SharedSafetyRuleTests {
    @Test("Containment needs a / boundary")
    func containmentNeedsABoundary() {
        #expect(PathContainment.isInside("/Users/a/Library/Caches", "/Users/a/Library"))
        #expect(!PathContainment.isInside("/Users/a/Library2/Caches", "/Users/a/Library"))
        #expect(!PathContainment.isInside("/Users/a/Library", "/Users/a/Library"))
        #expect(PathContainment.isSameOrInside("/Users/a/Library", "/Users/a/Library"))
        #expect(!PathContainment.isSameOrInside("/Users/alice2", "/Users/alice"))
        // A root written with a trailing slash means the same folder.
        #expect(PathContainment.isInside("/Users/a/Library/Caches", "/Users/a/Library/"))
    }

    @Test("A link anywhere below home counts, and so does a path outside home")
    func symlinkComponents() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("containment-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let real = home.appendingPathComponent("real/inner", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("real"))

        #expect(!PathContainment.containsSymlinkComponent(real, home: home.path))
        #expect(PathContainment.containsSymlinkComponent(link.appendingPathComponent("inner"), home: home.path))
        #expect(PathContainment.containsSymlinkComponent(URL(fileURLWithPath: "/tmp/elsewhere"), home: home.path))

        let root = home.appendingPathComponent("real").path
        #expect(PathContainment.staysInside(root: root, url: real, home: home.path))
        #expect(!PathContainment.staysInside(root: root, url: URL(fileURLWithPath: root), home: home.path))
        #expect(PathContainment.staysInside(root: root, url: URL(fileURLWithPath: root), home: home.path, includingRoot: true))
        // A root reached through a link is refused outright.
        #expect(!PathContainment.staysInside(root: link.path, url: link.appendingPathComponent("inner"), home: home.path))
    }

    @Test("Every orphan root is one of the uninstaller's leftover roots")
    func orphanRootsComeFromTheLeftoverRoots() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let orphan = OrphanLeftoverScanPolicy.orphanRoots(home: home)
        let leftover = AppUninstallScanPolicy.leftoverSearchRoots(home: home)
        #expect(Set(orphan.map(\.url.lastPathComponent)) == OrphanLeftoverScanPolicy.orphanRootNames)
        #expect(orphan.count == OrphanLeftoverScanPolicy.orphanRootNames.count)
        for root in orphan {
            #expect(root.url.deletingLastPathComponent().path == "/Users/someone/Library")
            #expect(leftover.contains { $0.url == root.url && $0.category == root.category })
        }
    }

    @Test("The git warning skips exactly the folders the policy allows by name")
    func gitWarningUsesThePolicyFolderNames() {
        for name in DeletionSafetyPolicy.whitelistedFolderNames {
            #expect(GitWarningPolicy.isRebuildableFolder(URL(fileURLWithPath: "/p/\(name)")), "\(name)")
        }
        #expect(GitWarningPolicy.isRebuildableFolder(URL(fileURLWithPath: "/p/.dart_tool")))
        #expect(!GitWarningPolicy.isRebuildableFolder(URL(fileURLWithPath: "/p/src")))
    }
}

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

    @Test("Each orphan root keeps its category")
    func orphanRootCategories() {
        let roots = OrphanLeftoverScanPolicy.orphanRoots(home: URL(fileURLWithPath: "/Users/someone", isDirectory: true))
        let categories = Dictionary(uniqueKeysWithValues: roots.map { ($0.url.lastPathComponent, $0.category) })
        #expect(categories == [
            "Application Support": .applicationSupport,
            "Containers": .containers,
            "Group Containers": .groupContainers,
            "HTTPStorages": .caches,
            "Saved Application State": .savedState,
        ])
    }

    /// Read as `Bundle(url:)` reads them, so an iPhone or iPad app wrapped for the
    /// Mac still claims the container it shares with a Mac app of the same id.
    @Test("Bundle ids come from every layout Bundle reads")
    func bundleIDLayouts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-ids-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, plistAt relative: String?, id: String?) throws -> URL {
            let bundle = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            guard let relative else { return bundle }
            let plist = bundle.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleName": name]
            if let id { info["CFBundleIdentifier"] = id }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
            return bundle
        }

        let mac = try app("Mac.app", plistAt: "Contents/Info.plist", id: "com.example.mac")
        let flat = try app("Flat.app", plistAt: "Info.plist", id: "com.example.flat")
        let wrapped = try app("Wrapped.app", plistAt: "Wrapper/Inner.app/Info.plist", id: "com.example.ipad")
        // Relative, as in a real wrapped app.
        try FileManager.default.createSymbolicLink(
            atPath: wrapped.appendingPathComponent("WrappedBundle").path,
            withDestinationPath: "Wrapper/Inner.app"
        )
        let noID = try app("NoID.app", plistAt: "Contents/Info.plist", id: nil)
        let empty = try app("Empty.app", plistAt: nil, id: nil)

        #expect(AppBundleReach.bundleID(at: mac) == "com.example.mac")
        #expect(AppBundleReach.bundleID(at: flat) == "com.example.flat")
        #expect(AppBundleReach.bundleID(at: wrapped) == "com.example.ipad")
        #expect(AppBundleReach.bundleID(at: noID) == nil)
        #expect(AppBundleReach.bundleID(at: empty) == nil)
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

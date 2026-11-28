import Darwin
import Foundation
import Testing
@testable import Purge

/// Claude's Cowork VM disk (#468): only `rootfs.img` and its origin file, only
/// when the compressed cache can rebuild it, Claude is quit and nothing has it
/// open. Every test builds its own home in a temporary folder.
@Suite("Claude Cowork VM disk (#468)")
struct CoworkVMImageScanPolicyTests {
    typealias Policy = CoworkVMImageScanPolicy

    static let version = "37817e321a4a5cfd1b8a667aa82bff9a55fb8f3b"

    /// A home with a bundle laid out the way Claude 1.6 writes it.
    static func makeHome() throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("cowork-vm-\(UUID().uuidString)", isDirectory: true)
        let bundle = URL(fileURLWithPath: Policy.bundleFolder(home: home.path), isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: bundle.appendingPathComponent(name))
        }
        try write("rootfs.img", "disk")
        try write("rootfs.img.zst", "compressed")
        try write(".rootfs.img.origin", version)
        try write(".rootfs.img.zst.origin", version)
        for name in ["vmlinuz", "initrd", "initrd-micro"] {
            try write(name, "boot")
            try write(".\(name).origin", version)
        }
        try write("efivars.fd", "vars")
        try write("sessiondata.img", "sessions")
        try write(".cowork-adopted", version)
        try write("machineIdentifier", "id")
        return home
    }

    static func bundle(_ home: URL) -> URL {
        URL(fileURLWithPath: Policy.bundleFolder(home: home.path), isDirectory: true)
    }

    static func image(_ home: URL) -> String { bundle(home).appendingPathComponent("rootfs.img").path }
    static func origin(_ home: URL) -> String { bundle(home).appendingPathComponent(".rootfs.img.origin").path }

    /// Claude quit, and an `lsof` listing with one unrelated open file.
    static func context(running: Bool = false, lsof: String? = "p1\ncFinder\nn/System/Library/foo\n") -> Policy.Context {
        Policy.Context(isClaudeRunning: { running }, openFiles: { lsof })
    }

    /// A listing in which the VM process has the image open.
    static func holding(_ home: URL) -> String {
        "p42\ncVirtualization\nn\(image(home))\n"
    }

    static func offered(
        _ path: String,
        _ home: URL,
        _ context: Policy.Context = context(),
        _ check: NvmNodeVersionPolicy.Check = .scan
    ) -> Bool {
        Policy.isOffered(path, home: home.path, context: context, check: check)
    }

    // MARK: Offered

    @Test
    func imageAndOriginAreOfferedWhenTheCacheMatches() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for check in [NvmNodeVersionPolicy.Check.quick, .scan] {
            #expect(Self.offered(Self.image(home), home, Self.context(), check))
            #expect(Self.offered(Self.origin(home), home, Self.context(), check))
        }
        #expect(Self.offered(Self.image(home), home, Self.context(), .move))
    }

    @Test
    func theScanListsTheImageThenItsOrigin() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let rows = Policy.definitions(home: home.path, context: Self.context())
        #expect(rows.count == 1)
        #expect(rows.first?.label == Policy.label)
        #expect(rows.first?.paths.map(\.path) == [Self.image(home), Self.origin(home)])
    }

    @Test
    func versionsMayDifferOnlyInSurroundingWhitespace() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("\(Self.version)\n".utf8).write(to: URL(fileURLWithPath: Self.origin(home)))
        #expect(Self.offered(Self.image(home), home))
    }

    // MARK: Refused

    /// Each way the rebuild would not be local, or the files are not what Claude wrote.
    @Test(arguments: [
        "cache missing", "cache empty", "cache a folder", "cache a link",
        "cache origin missing", "cache origin differs", "cache origin empty",
        "image origin missing", "image origin empty", "image origin too big",
    ])
    func refusedWhenTheRebuildIsNotLocal(change: String) throws {
        let fm = FileManager.default
        let home = try Self.makeHome()
        defer { try? fm.removeItem(at: home) }
        let bundle = Self.bundle(home)
        let cache = bundle.appendingPathComponent("rootfs.img.zst")
        let cacheOrigin = bundle.appendingPathComponent(".rootfs.img.zst.origin")
        let imageOrigin = URL(fileURLWithPath: Self.origin(home))
        switch change {
        case "cache missing": try fm.removeItem(at: cache)
        case "cache empty": try Data().write(to: cache)
        case "cache a folder":
            try fm.removeItem(at: cache)
            try fm.createDirectory(at: cache, withIntermediateDirectories: false)
        case "cache a link":
            let elsewhere = home.appendingPathComponent("elsewhere.zst")
            try Data("compressed".utf8).write(to: elsewhere)
            try fm.removeItem(at: cache)
            try fm.createSymbolicLink(at: cache, withDestinationURL: elsewhere)
        case "cache origin missing": try fm.removeItem(at: cacheOrigin)
        case "cache origin differs": try Data("0000000000000000000000000000000000000000".utf8).write(to: cacheOrigin)
        case "cache origin empty": try Data("\n".utf8).write(to: cacheOrigin)
        case "image origin missing": try fm.removeItem(at: imageOrigin)
        case "image origin empty": try Data().write(to: imageOrigin)
        case "image origin too big":
            let big = String(repeating: "a", count: Policy.originSizeLimit + 1)
            try Data(big.utf8).write(to: imageOrigin)
            try Data(big.utf8).write(to: cacheOrigin)
        default: Issue.record("unknown change \(change)")
        }
        for check in [NvmNodeVersionPolicy.Check.quick, .scan, .move] {
            #expect(!Self.offered(Self.image(home), home, Self.context(), check), "\(change) \(check)")
        }
        #expect(Policy.definitions(home: home.path, context: Self.context()).isEmpty)
    }

    @Test
    func refusedWhileClaudeRuns() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let running = Self.context(running: true)
        for check in [NvmNodeVersionPolicy.Check.quick, .scan, .move] {
            #expect(!Self.offered(Self.image(home), home, running, check))
            #expect(!Self.offered(Self.origin(home), home, running, check))
        }
        #expect(Policy.definitions(home: home.path, context: running).isEmpty)
    }

    @Test
    func refusedWhileAProcessHasTheImageOpen() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let busy = Self.context(lsof: Self.holding(home))
        #expect(!Self.offered(Self.image(home), home, busy, .scan))
        #expect(!Self.offered(Self.image(home), home, busy, .move))
        #expect(Policy.definitions(home: home.path, context: busy).isEmpty)
    }

    /// An empty answer is not proof that nothing is open.
    @Test
    func refusedWhenLsofCannotBeRead() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let unreadable = Self.context(lsof: nil)
        #expect(!Self.offered(Self.image(home), home, unreadable, .scan))
        #expect(!Self.offered(Self.image(home), home, unreadable, .move))
        #expect(Policy.definitions(home: home.path, context: unreadable).isEmpty)
    }

    /// The main-thread filter runs `.quick` on every scan flush, so it never
    /// waits for `lsof`.
    @Test
    func theQuickCheckNeverReadsLsof() throws {
        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func add() { lock.lock(); value += 1; lock.unlock() }
            var calls: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let count = Count()
        let context = Policy.Context(isClaudeRunning: { false }, openFiles: { count.add(); return "" })
        #expect(Self.offered(Self.image(home), home, context, .quick))
        #expect(Self.offered(Self.origin(home), home, context, .quick))
        #expect(!Policy.refusesDeletion(URL(fileURLWithPath: Self.image(home)), home: home.path, context: context))
        #expect(count.calls == 0)
        _ = Policy.definitions(home: home.path, context: context)
        #expect(count.calls == 1, "the scan reads lsof once, for the image")
    }

    @Test(arguments: ["link", "hard link", "folder"])
    func refusedWhenTheImageIsNotOneRegularFile(kind: String) throws {
        let fm = FileManager.default
        let home = try Self.makeHome()
        defer { try? fm.removeItem(at: home) }
        let image = URL(fileURLWithPath: Self.image(home))
        switch kind {
        case "link":
            let elsewhere = home.appendingPathComponent("Documents/disk.img")
            try fm.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("disk".utf8).write(to: elsewhere)
            try fm.removeItem(at: image)
            try fm.createSymbolicLink(at: image, withDestinationURL: elsewhere)
        case "hard link":
            #expect(link(image.path, home.appendingPathComponent("second-name.img").path) == 0)
        case "folder":
            try fm.removeItem(at: image)
            try fm.createDirectory(at: image, withIntermediateDirectories: false)
        default:
            Issue.record("unknown kind \(kind)")
        }
        for check in [NvmNodeVersionPolicy.Check.quick, .scan, .move] {
            #expect(!Self.offered(image.path, home, Self.context(), check), "\(kind) \(check)")
            #expect(!Self.offered(Self.origin(home), home, Self.context(), check), "\(kind) \(check)")
        }
    }

    /// A link on the way would point the move somewhere else.
    @Test(arguments: ["Library/Application Support/Claude", "Library/Application Support/Claude/vm_bundles",
                      "Library/Application Support/Claude/vm_bundles/claudevm.bundle"])
    func refusedThroughALinkedFolder(linked: String) throws {
        let fm = FileManager.default
        let home = try Self.makeHome()
        defer { try? fm.removeItem(at: home) }
        let folder = home.appendingPathComponent(linked, isDirectory: true)
        let moved = home.appendingPathComponent("moved-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: folder, to: moved)
        try fm.createSymbolicLink(at: folder, withDestinationURL: moved)
        for check in [NvmNodeVersionPolicy.Check.quick, .scan, .move] {
            #expect(!Self.offered(Self.image(home), home, Self.context(), check), "\(linked) \(check)")
            #expect(!Self.offered(Self.origin(home), home, Self.context(), check), "\(linked) \(check)")
        }
    }

    // MARK: The origin file

    /// Right before its move the origin is refused while the image is still
    /// there, so a refused or failed image move leaves the pair as Claude wrote it.
    @Test
    func theOriginMovesOnlyAfterTheImage() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!Self.offered(Self.origin(home), home, Self.context(), .move))
        try FileManager.default.removeItem(atPath: Self.image(home))
        #expect(Self.offered(Self.origin(home), home, Self.context(), .move))
        #expect(!Self.offered(Self.origin(home), home, Self.context(running: true), .move))
    }

    /// The order `FileDeleter.deleteItems` asks in: `isOfferedForCleanup` (the
    /// `.quick` check behind `refusesDeletion`) and then the move check, for the
    /// image and then for the origin, once the image is in the Trash. Review of
    /// #485 found the origin refused by the `.quick` check at that point.
    @Test
    func aCleanAsksForTheOriginAfterTheImageHasMoved() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let image = URL(fileURLWithPath: Self.image(home))
        let origin = URL(fileURLWithPath: Self.origin(home))
        let context = Self.context()
        #expect(!Policy.refusesDeletion(image, home: home.path, context: context))
        #expect(Policy.passesImmediateTrashBoundary(image, home: home.path, context: context))
        // The image's move failed: the origin stays with it.
        #expect(!Policy.passesImmediateTrashBoundary(origin, home: home.path, context: context))
        // The image moved.
        try FileManager.default.removeItem(at: image)
        #expect(!Policy.refusesDeletion(origin, home: home.path, context: context))
        #expect(Policy.passesImmediateTrashBoundary(origin, home: home.path, context: context))
        // Claude started, or its copy went, in between.
        #expect(Policy.refusesDeletion(origin, home: home.path, context: Self.context(running: true)))
        try FileManager.default.removeItem(at: Self.bundle(home).appendingPathComponent("rootfs.img.zst"))
        #expect(Policy.refusesDeletion(origin, home: home.path, context: context))
        // A scan with no image lists nothing, the origin included.
        #expect(Policy.definitions(home: home.path, context: context).isEmpty)
    }

    // MARK: Shape

    /// Session data, Claude's markers, the boot files, the compressed cache, the
    /// bundle itself, and the same names anywhere else.
    @Test(arguments: [
        "", "/..", "/sessiondata.img", "/sessiondata.img.bak", "/.cowork-adopted", "/machineIdentifier",
        "/efivars.fd", "/vmlinuz", "/initrd", "/initrd-micro", "/.vmlinuz.origin",
        "/rootfs.img.zst", "/.rootfs.img.zst.origin", "/rootfs.img.partial", "/rootfs.img/inner",
        "/ROOTFS.IMG", "/gvisorMacAddress", "/vmIP",
    ])
    func nothingElseInTheBundleIsAnEntry(suffix: String) {
        let home = "/Users/someone"
        let path = Policy.bundleFolder(home: home) + suffix
        #expect(Policy.entry(at: path, home: home) == nil, "\(suffix)")
        #expect(!Policy.isWhitelistedPath(path, home: home), "\(suffix)")
    }

    @Test(arguments: [
        "Library/Application Support/Claude/vm_bundles/rootfs.img",
        "Library/Application Support/Claude/vm_bundles/other.bundle/rootfs.img",
        "Library/Application Support/Claude/vm_bundles/claudevm.bundle/old/rootfs.img",
        "Library/Application Support/Claude/rootfs.img",
        "rootfs.img",
        "Library/Application Support/Claude-3p/vm_bundles/claudevm.bundle/rootfs.img",
    ])
    func theSameNamesElsewhereAreNotEntries(relative: String) {
        #expect(Policy.entry(at: "/Users/someone/\(relative)", home: "/Users/someone") == nil, "\(relative)")
    }

    @Test
    func onlyTheTwoFilesAreEntries() {
        let home = "/Users/someone"
        let bundle = Policy.bundleFolder(home: home)
        #expect(Policy.entry(at: "\(bundle)/rootfs.img", home: home) == .image)
        #expect(Policy.entry(at: "\(bundle)/.rootfs.img.origin", home: home) == .imageOrigin)
    }

    // MARK: Gates in the app

    /// `evaluate` allows the two files by shape, and nothing else in the bundle.
    @Test
    func evaluateAllowsOnlyTheTwoFiles() {
        let bundle = Policy.bundleFolder(home: DeletionSafetyPolicy.cachedHomePath)
        #expect(DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: "\(bundle)/rootfs.img")) == .allow)
        #expect(DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: "\(bundle)/.rootfs.img.origin")) == .allow)
        for name in ["", "/sessiondata.img", "/.cowork-adopted", "/rootfs.img.zst", "/.rootfs.img.zst.origin",
                     "/machineIdentifier", "/efivars.fd", "/vmlinuz", "/.."] {
            #expect(DeletionSafetyPolicy.evaluate(URL(fileURLWithPath: bundle + name)) != .allow, "\(name)")
        }
    }

    /// Paths in a throwaway home are not this rule's, so it leaves them to the others.
    @Test
    func theHooksLeaveOtherPathsAlone() {
        let other = URL(fileURLWithPath: "/Users/someone/Library/Caches/Homebrew")
        #expect(!Policy.refusesDeletion(other, home: "/Users/someone", context: Self.context(running: true)))
        #expect(Policy.passesImmediateTrashBoundary(other, home: "/Users/someone", context: Self.context(lsof: nil)))
    }

    @Test
    func theDefaultMoveCheckRunsTheCoworkRule() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let image = URL(fileURLWithPath: Self.image(home))
        #expect(FileDeleter.defaultImmediateMoveCheck(home: home.path, coworkVMImage: Self.context())(image))
        let running = FileDeleter.defaultImmediateMoveCheck(home: home.path, coworkVMImage: Self.context(running: true))
        #expect(!running(image), "refused while Claude runs")
        let busy = FileDeleter.defaultImmediateMoveCheck(home: home.path, coworkVMImage: Self.context(lsof: Self.holding(home)))
        #expect(!busy(image), "refused while the image is open")
        let unreadable = FileDeleter.defaultImmediateMoveCheck(home: home.path, coworkVMImage: Self.context(lsof: nil))
        #expect(!unreadable(image), "refused when lsof can't be read")
        #expect(unreadable(home.appendingPathComponent("Library/Caches/Homebrew")))
    }

    /// Claude rebuilds it on the next Cowork start, which takes time, and the
    /// row is only worth it when Cowork is rarely used. Clean Safe Items and
    /// scheduled cleans take only Safe rows.
    @Test
    func theRowIsNeverSafe() {
        #expect(DevScanner.automaticSafetyInfo(forDevToolLabel: Policy.label, primaryPath: nil).level == .medium)
        #expect(ExplanationDatabase.record(forKey: Policy.explanationKey)?.safetyLevel == .medium)
    }

    /// No alias or bundle id, so the row never joins the Safe "Claude AI App" row.
    @Test
    func theEntryClaimsNoClaudeName() {
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "vm_bundles") == nil)
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "rootfs.img") == nil)
        #expect(ExplanationDatabase.record(forKey: Policy.explanationKey)?.bundleIds?.isEmpty ?? true)
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: Policy.label)?.safetyLevel != .safe)
        #expect(ExplanationDatabase.matchBundledDatabase(folderName: "claudevm.bundle") == nil)
    }
}

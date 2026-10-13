import Foundation
import Testing
@testable import Purge

@Suite("Large Files labels restore images, VMs and unfinished downloads (#128)")
struct LargeFileKindTests {
    // MARK: - Fixtures

    /// A throwaway home with the scan and VM roots inside it, so nothing here
    /// touches the real `~/Downloads` or `~/Parallels`.
    private struct Home {
        let url: URL
        var downloads: URL { url.appendingPathComponent("Downloads", isDirectory: true) }
        var parallels: URL { url.appendingPathComponent("Parallels", isDirectory: true) }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("purge-kind-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func write(_ relative: String, bytes: Int = 4096) throws {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x01, count: bytes).write(to: file)
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    private func scan(
        _ home: Home,
        minBytes: Int64 = 1,
        installedApps: Set<VirtualMachineApp> = []
    ) async -> [String: LargeFile] {
        let stream = LargeFileScanner().scanStream(
            minBytes: minBytes,
            staleDays: 0,
            roots: [home.downloads],
            virtualMachineRoots: [home.parallels],
            installedApps: installedApps,
            exclusions: ScanExclusions(keys: []),
            isExcluded: { _ in false }
        )
        var found: [String: LargeFile] = [:]
        let marker = home.url.lastPathComponent + "/"
        for await file in stream {
            let path = file.path.path
            guard let range = path.range(of: marker) else { continue }
            found[String(path[range.upperBound...])] = file
        }
        return found
    }

    // MARK: - Scanner

    @Test(arguments: [
        ("Win.pvm", ["Win.pvm/harddisk.hdd/disk.hds", "Win.pvm/config.pvs"], VirtualMachineApp.parallels),
        ("Linux.utm", ["Linux.utm/Data/disk.qcow2", "Linux.utm/config.plist"], .utm),
        ("Old.vmwarevm", ["Old.vmwarevm/disk.vmdk", "Old.vmwarevm/Old.vmx"], .vmwareFusion),
    ])
    func vmBundleIsOneRowAndItsDisksAreNeverListed(
        bundle: String, contents: [String], app: VirtualMachineApp
    ) async throws {
        let home = try Home()
        defer { home.remove() }
        for file in contents { try home.write("Downloads/\(file)") }

        let found = await scan(home, installedApps: [app])

        #expect(Set(found.keys) == ["Downloads/\(bundle)"])
        let row = try #require(found["Downloads/\(bundle)"])
        #expect(row.category == .virtualMachine)
        #expect(row.kind == .virtualMachine(app, appInstalled: true))
        #expect(row.componentPaths.map(\.lastPathComponent) == [bundle])
        #expect(row.sizeBytes >= Int64(4096 * contents.count))
    }

    @Test
    func vmExplanationNamesTheAppOnlyWhenItIsInstalled() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Downloads/Win.pvm/harddisk.hdd/disk.hds")

        let withoutApp = await scan(home)
        let without = try #require(withoutApp["Downloads/Win.pvm"])
        #expect(without.kind == .virtualMachine(.parallels, appInstalled: false))
        #expect(!(without.kind?.explanation.contains("Parallels Desktop") ?? true))

        let withApp = await scan(home, installedApps: [.parallels])
        let with = try #require(withApp["Downloads/Win.pvm"])
        #expect(with.kind?.explanation.contains("Parallels Desktop") == true)
    }

    @Test
    func smallVMBundleListsNothingAtAll() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Downloads/Tiny.pvm/harddisk.hdd/disk.hds", bytes: 4096)

        let found = await scan(home, minBytes: 1_000_000)
        #expect(found.isEmpty)
    }

    @Test
    func restoreImageIsLabelledAndFiledAsAnArchive() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Downloads/UniversalMac_26.0_Restore.ipsw")

        let found = await scan(home)
        let row = try #require(found["Downloads/UniversalMac_26.0_Restore.ipsw"])
        #expect(row.kind == .restoreImage)
        #expect(row.category == .archive)
    }

    @Test
    func unfinishedDownloadsAreLabelled() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Downloads/ParallelsDesktop.dmg.prlupd-part")
        try home.write("Downloads/installer.dmg.crdownload")
        try home.write("Downloads/movie.mkv.part")
        try home.write("Downloads/archive.zip.download/archive.zip")
        try home.write("Downloads/archive.zip.download/Info.plist")

        let found = await scan(home)

        #expect(Set(found.keys) == [
            "Downloads/ParallelsDesktop.dmg.prlupd-part",
            "Downloads/installer.dmg.crdownload",
            "Downloads/movie.mkv.part",
            "Downloads/archive.zip.download",
        ])
        #expect(found.values.allSatisfy { $0.kind == .unfinishedDownload })
    }

    /// Firefox's `.part` is a file. A folder that happens to end in `.part` is
    /// the user's, so it is walked like any folder and never listed whole.
    @Test
    func folderNamedLikeAPartialFileIsNotADownload() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Downloads/Chapter.part/notes.pdf")

        let found = await scan(home)
        #expect(Set(found.keys) == ["Downloads/Chapter.part/notes.pdf"])
        #expect(found["Downloads/Chapter.part/notes.pdf"]?.kind == nil)
    }

    @Test
    func vmRootListsVMBundlesOnly() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Parallels/Win.pvm/harddisk.hdd/disk.hds")
        try home.write("Parallels/Nested/Mac.pvm/harddisk.hdd/disk.hds")
        try home.write("Parallels/screen-recording.mov")
        try home.write("Parallels/archive.zip.download/archive.zip")

        let found = await scan(home)
        #expect(Set(found.keys) == ["Parallels/Win.pvm", "Parallels/Nested/Mac.pvm"])
    }

    // MARK: - Delete check

    @Test
    func vmBundlesAndDownloadBundlesAreEligibleWhole() throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Downloads/Win.pvm/harddisk.hdd/disk.hds")
        try home.write("Downloads/archive.zip.download/archive.zip")
        try home.write("Parallels/Mac.pvm/harddisk.hdd/disk.hds")

        for relative in ["Downloads/Win.pvm", "Downloads/archive.zip.download", "Parallels/Mac.pvm"] {
            let url = home.url.appendingPathComponent(relative)
            #expect(LargeFileScanPolicy.isEligibleForDeletion(url, home: home.url), "\(relative)")
        }
    }

    @Test
    func everythingElseAroundABundleIsRefused() throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Downloads/Project/readme.txt")
        try home.write("Downloads/Tool.app/Contents/Info.plist")
        try home.write("Downloads/Win.pvm/harddisk.hdd/disk.hds")
        try home.write("Downloads/Win.pvm/Inner.pvm/disk.hds")
        try home.write("Downloads/Chapter.part/notes.pdf")
        try home.write("Parallels/screen-recording.mov")
        try home.write("Parallels/archive.zip.download/archive.zip")

        for relative in [
            "Downloads/Project",
            "Downloads/Tool.app",
            "Downloads/Win.pvm/harddisk.hdd/disk.hds",
            "Downloads/Win.pvm/harddisk.hdd",
            "Downloads/Win.pvm/Inner.pvm",
            "Downloads/Chapter.part",
            "Parallels/screen-recording.mov",
            "Parallels/archive.zip.download",
        ] {
            let url = home.url.appendingPathComponent(relative)
            #expect(!LargeFileScanPolicy.isEligibleForDeletion(url, home: home.url), "\(relative)")
        }
    }

    @Test
    func ordinaryFilesInAScanRootStayEligible() throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Downloads/Xcode_26.xip")

        let url = home.downloads.appendingPathComponent("Xcode_26.xip")
        #expect(LargeFileScanPolicy.isEligibleForDeletion(url, home: home.url))
    }

    // MARK: - Labels

    @Test
    func kindFollowsTheExtension() {
        #expect(LargeFileKind.kind(forExtension: "IPSW") == .restoreImage)
        #expect(LargeFileKind.kind(forExtension: "pvm") == .virtualMachine(.parallels, appInstalled: false))
        #expect(LargeFileKind.kind(forExtension: "utm") == .virtualMachine(.utm, appInstalled: false))
        #expect(LargeFileKind.kind(forExtension: "vmwarevm") == .virtualMachine(.vmwareFusion, appInstalled: false))
        #expect(LargeFileKind.kind(forExtension: "prlupd-part") == .unfinishedDownload)
        #expect(LargeFileKind.kind(forExtension: "dmg") == nil)
    }

    @Test
    func searchFindsARowByWhatItIs() {
        let vm = LargeFile(
            path: URL(fileURLWithPath: "/Users/someone/Parallels/Windows 11.pvm"),
            sizeBytes: 40_000_000_000,
            lastUsed: Date(),
            category: .virtualMachine
        )
        #expect(vm.matches(searchQuery: "virtual machine"))
        #expect(vm.matches(searchQuery: "parallels"))
        #expect(!vm.matches(searchQuery: "restore"))
    }
}

import Foundation
import Testing
@testable import Purge

@Suite("Large Files lists VirtualBox and Tart VMs whole (#475)")
struct LargeFileFolderVirtualMachineTests {
    // MARK: - Fixtures

    /// A throwaway home with `VirtualBox VMs` and `.tart/vms` inside it, so
    /// nothing here touches the real folders.
    private struct Home {
        let url: URL
        var documents: URL { url.appendingPathComponent("Documents", isDirectory: true) }
        var virtualBox: URL { url.appendingPathComponent("VirtualBox VMs", isDirectory: true) }
        var tart: URL { url.appendingPathComponent(".tart/vms", isDirectory: true) }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("purge-vmfolder-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        }

        func path(_ relative: String) -> URL { url.appendingPathComponent(relative) }

        func write(_ relative: String, bytes: Int = 4096) throws {
            try write(relative, data: Data(repeating: 0x01, count: bytes))
        }

        func write(_ relative: String, text: String) throws {
            try write(relative, data: Data(text.utf8))
        }

        private func write(_ relative: String, data: Data) throws {
            let file = path(relative)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: file)
        }

        func link(_ relative: String, to target: String) throws {
            let link = path(relative)
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path(target))
        }

        /// A VirtualBox VM: `<name>.vbox`, a disk and a log, as VirtualBox
        /// lays one out. `settings` is the `.vbox` text.
        func virtualBoxVM(_ relative: String, settings: String = "<VirtualBox/>") throws {
            let name = (relative as NSString).lastPathComponent
            try write("VirtualBox VMs/\(relative)/\(name).vbox", text: settings)
            try write("VirtualBox VMs/\(relative)/\(name).vdi", bytes: 8192)
            try write("VirtualBox VMs/\(relative)/Logs/VBox.log")
        }

        /// A Tart VM, as `tart create` lays one out (probe for #475).
        func tartVM(_ name: String) throws {
            try write(".tart/vms/\(name)/config.json", text: "{}")
            try write(".tart/vms/\(name)/disk.img", bytes: 8192)
            try write(".tart/vms/\(name)/nvram.bin")
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    private static let noOpenFiles: OpenFileCheck.Lister = { "" }

    private func scan(
        _ home: Home,
        installedApps: Set<VirtualMachineApp> = [],
        runningApps: Set<String> = [],
        openFiles: @escaping OpenFileCheck.Lister = noOpenFiles
    ) async -> [String: LargeFile] {
        let stream = LargeFileScanner().scanStream(
            minBytes: 1,
            staleDays: 0,
            roots: [home.documents],
            virtualMachineRoots: [],
            folderVirtualMachineRoots: LargeFileScanPolicy.folderVirtualMachineRoots(home: home.url),
            iCloudDriveRoots: [],
            addedFolders: [],
            installedApps: installedApps,
            isAppRunning: { runningApps.contains($0) },
            openFiles: openFiles,
            home: home.url,
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

    private func isEligible(
        _ url: URL,
        _ home: Home,
        runningApps: Set<String> = [],
        openFiles: @escaping OpenFileCheck.Lister = noOpenFiles
    ) -> Bool {
        LargeFileScanPolicy.isEligibleForDeletion(
            url, home: home.url,
            isAppRunning: { runningApps.contains($0) },
            openFiles: openFiles,
            addedRoots: []
        )
    }

    /// An `lsof -F pcn` listing with one process holding `file`.
    private func holding(_ file: URL, command: String) -> OpenFileCheck.Lister {
        let listing = "p4242\nc\(command)\nn\(file.path)\n"
        return { listing }
    }

    // MARK: - Listing

    @Test
    func virtualBoxVMIsOneRowAndNothingInsideIsListed() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.virtualBoxVM("Win")

        let found = await scan(home, installedApps: [.virtualBox])
        #expect(Set(found.keys) == ["VirtualBox VMs/Win"])
        let row = try #require(found["VirtualBox VMs/Win"])
        #expect(row.category == .virtualMachine)
        #expect(row.kind == .virtualMachine(.virtualBox, appInstalled: true))
        #expect(row.sizeBytes >= 8192)
        #expect(isEligible(home.virtualBox.appendingPathComponent("Win"), home))
    }

    /// VirtualBox puts a VM in a group one folder deeper per group. Those are
    /// found too, so no VM is left behind for being one folder down.
    @Test
    func groupedVirtualBoxVMsAreListed() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.virtualBoxVM("Work/Linux/Deb")
        try home.virtualBoxVM("Work/Win")

        let found = await scan(home)
        #expect(Set(found.keys) == ["VirtualBox VMs/Work/Linux/Deb", "VirtualBox VMs/Work/Win"])
        #expect(isEligible(home.path("VirtualBox VMs/Work/Linux/Deb"), home))
        #expect(!isEligible(home.path("VirtualBox VMs/Work"), home))
        #expect(!isEligible(home.path("VirtualBox VMs/Work/Linux"), home))
    }

    /// Only a folder holding its own `<name>.vbox` is a VM. A loose disk, a
    /// folder holding another name's settings, a folder inside a VM and a
    /// hidden group are never listed, and nothing in them is either.
    @Test
    func onlyFoldersWithTheirOwnSettingsAreVMs() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("VirtualBox VMs/loose.vdi", bytes: 8192)
        try home.write("VirtualBox VMs/Stray/Other.vbox", text: "<VirtualBox/>")
        try home.write("VirtualBox VMs/Stray/Other.vdi", bytes: 8192)
        try home.virtualBoxVM("Win")
        try home.virtualBoxVM("Win/Inner")
        try home.virtualBoxVM(".Hidden/Secret")

        let found = await scan(home)
        #expect(Set(found.keys) == ["VirtualBox VMs/Win"])
        for refused in ["VirtualBox VMs/loose.vdi", "VirtualBox VMs/Stray", "VirtualBox VMs/Win/Inner",
                        "VirtualBox VMs/.Hidden/Secret", "VirtualBox VMs/Win/Win.vdi", "VirtualBox VMs"] {
            #expect(!isEligible(home.path(refused), home), "\(refused)")
        }
    }

    @Test
    func tartVMIsOneRowWithTheSameTextInstalledOrNot() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.tartVM("mac")

        let found = await scan(home)
        #expect(Set(found.keys) == [".tart/vms/mac"])
        let row = try #require(found[".tart/vms/mac"])
        #expect(row.category == .virtualMachine)
        #expect(row.kind == .virtualMachine(.tart, appInstalled: false))
        #expect(isEligible(home.tart.appendingPathComponent("mac"), home))
        #expect(LargeFileKind.virtualMachine(.tart, appInstalled: false).explanation
            == LargeFileKind.virtualMachine(.tart, appInstalled: true).explanation)
        #expect(row.kind?.badgeText.contains("Tart") == true)
    }

    /// A Tart VM sits directly in `~/.tart/vms` and holds `config.json` and
    /// `disk.img`. Anything else under `~/.tart`, the image cache included, is
    /// never listed or trashed.
    @Test
    func tartFoldersWithoutTheShapeOrDeeperAreRefused() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(".tart/vms/half/config.json", text: "{}")
        try home.write(".tart/vms/group/inner/config.json", text: "{}")
        try home.write(".tart/vms/group/inner/disk.img", bytes: 8192)
        try home.write(".tart/cache/OCIs/ghcr.io/vm/latest/config.json", text: "{}")
        try home.write(".tart/cache/OCIs/ghcr.io/vm/latest/disk.img", bytes: 8192)
        try home.tartVM("mac")

        let found = await scan(home)
        #expect(Set(found.keys) == [".tart/vms/mac"])
        for refused in [".tart/vms/half", ".tart/vms/group", ".tart/vms/group/inner", ".tart/vms",
                        ".tart/vms/mac/disk.img", ".tart/cache/OCIs/ghcr.io/vm/latest", ".tart"] {
            #expect(!isEligible(home.path(refused), home), "\(refused)")
        }
    }

    // MARK: - In use

    /// A running VM keeps writing its disk inside the Trash. VirtualBox open,
    /// a process holding a file in the folder, or open files that can't be
    /// read, each keeps the VM off the list and refused at delete time.
    @Test
    func virtualBoxVMThatMayBeRunningIsNotListedOrTrashed() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.virtualBoxVM("Win")
        let vm = home.virtualBox.appendingPathComponent("Win")
        let virtualBox = try #require(VirtualMachineApp.virtualBox.bundleID)
        let held = holding(vm.appendingPathComponent("Win.vdi"), command: "VBoxHeadless")
        let unreadable: OpenFileCheck.Lister = { nil }

        #expect(await scan(home, runningApps: [virtualBox]).isEmpty)
        #expect(!isEligible(vm, home, runningApps: [virtualBox]))
        #expect(await scan(home, openFiles: held).isEmpty)
        #expect(!isEligible(vm, home, openFiles: held))
        #expect(await scan(home, openFiles: unreadable).isEmpty)
        #expect(!isEligible(vm, home, openFiles: unreadable))

        // A process holding a file in another folder doesn't count.
        let elsewhere = holding(home.documents.appendingPathComponent("notes.txt"), command: "TextEdit")
        #expect(await scan(home, openFiles: elsewhere).count == 1)
        #expect(isEligible(vm, home, openFiles: elsewhere))
    }

    /// Measured for #475: a running Tart VM shows `tart` holding
    /// `config.json` and Apple's Virtualization process holding `disk.img`.
    @Test(arguments: [("config.json", "tart"), ("disk.img", "com.apple.Virtualization.Virtua")])
    func tartVMThatIsRunningIsNotListedOrTrashed(file: String, command: String) async throws {
        let home = try Home()
        defer { home.remove() }
        try home.tartVM("mac")
        let vm = home.tart.appendingPathComponent("mac")
        let held = holding(vm.appendingPathComponent(file), command: command)

        #expect(await scan(home, openFiles: held).isEmpty)
        #expect(!isEligible(vm, home, openFiles: held))
    }

    // MARK: - Linked clones

    /// A linked clone keeps its base disk in the original VM's folder, so the
    /// original is refused while the clone names that disk, by a relative or
    /// an absolute path. The clone itself can still go.
    @Test(arguments: [true, false])
    func vmWhoseDiskALinkedCloneUsesIsRefused(relative: Bool) async throws {
        let home = try Home()
        defer { home.remove() }
        try home.virtualBoxVM("Base")
        let baseDisk = home.virtualBox.appendingPathComponent("Base/Base.vdi")
        // Relative to the clone's own folder, which sits in a group.
        let location = relative ? "../../Base/Base.vdi" : baseDisk.path
        try home.virtualBoxVM("Work/Clone", settings: """
            <VirtualBox><Machine name="Clone"><MediaRegistry><HardDisks>
            <HardDisk uuid="{1}" location="\(location)" format="VDI" type="Normal">
            <HardDisk uuid="{2}" location="Snapshots/{2}.vdi" format="VDI"/>
            </HardDisk></HardDisks></MediaRegistry></Machine></VirtualBox>
            """)

        let found = await scan(home)
        #expect(Set(found.keys) == ["VirtualBox VMs/Work/Clone"])
        #expect(!isEligible(home.virtualBox.appendingPathComponent("Base"), home))
        #expect(isEligible(home.virtualBox.appendingPathComponent("Work/Clone"), home))
    }

    /// A clone can sit outside `~/VirtualBox VMs`, where VirtualBox's own list
    /// of registered VMs names it, or in the root behind a link. Either way the
    /// VM whose disk it uses is refused.
    @Test(arguments: [true, false])
    func linkedCloneOutsideTheRootStillProtectsItsBase(registered: Bool) async throws {
        let home = try Home()
        defer { home.remove() }
        try home.virtualBoxVM("Base")
        let baseDisk = home.virtualBox.appendingPathComponent("Base/Base.vdi")
        try home.write("Documents/VMs/Clone/Clone.vbox", text: "<HardDisk location=\"\(baseDisk.path)\"/>")
        let clone = home.path("Documents/VMs/Clone/Clone.vbox")
        if registered {
            try home.write("Library/VirtualBox/VirtualBox.xml", text: """
                <VirtualBox><Global><MachineRegistry>
                <MachineEntry uuid="{1}" src="\(clone.path)"/>
                </MachineRegistry></Global></VirtualBox>
                """)
        } else {
            try home.link("VirtualBox VMs/Clone", to: "Documents/VMs/Clone")
        }

        #expect(await scan(home).keys.contains("VirtualBox VMs/Base") == false)
        #expect(!isEligible(home.virtualBox.appendingPathComponent("Base"), home))
    }

    /// Since VirtualBox 4.0 a disk sits in one media registry. A VM that
    /// attaches an existing or shareable disk names it by `uuid` alone, and
    /// the `location` stays in the owning VM's settings or in the global
    /// registry in `VirtualBox.xml`. Either way the owning VM is refused.
    @Test(arguments: [false, true])
    func vmWhoseDiskAnotherVMAttachesByUUIDIsRefused(inGlobalRegistry: Bool) async throws {
        let home = try Home()
        defer { home.remove() }
        if inGlobalRegistry {
            try home.virtualBoxVM("Base", settings: "<VirtualBox><Machine name=\"Base\"/></VirtualBox>")
            try home.write("Library/VirtualBox/VirtualBox.xml", text: """
                <VirtualBox><Global><MediaRegistry><HardDisks>
                <HardDisk uuid="{AAAA-1}" location="../../VirtualBox VMs/Base/data.vdi" format="VDI" type="Shareable"/>
                </HardDisks></MediaRegistry></Global></VirtualBox>
                """)
        } else {
            try home.virtualBoxVM("Base", settings: """
                <VirtualBox><Machine name="Base"><MediaRegistry><HardDisks>
                <HardDisk uuid="{AAAA-1}" location="data.vdi" format="VDI" type="Shareable"/>
                </HardDisks></MediaRegistry></Machine></VirtualBox>
                """)
        }
        try home.write("VirtualBox VMs/Base/data.vdi", bytes: 8192)
        try home.virtualBoxVM("Other", settings: """
            <VirtualBox><Machine uuid="{bbbb-2}" name="Other"><StorageControllers><StorageController name="SATA">
            <AttachedDevice type="HardDisk" port="1"><Image uuid="{aaaa-1}"/></AttachedDevice>
            </StorageController></StorageControllers></Machine></VirtualBox>
            """)

        let found = await scan(home)
        #expect(Set(found.keys) == ["VirtualBox VMs/Other"])
        #expect(!isEligible(home.virtualBox.appendingPathComponent("Base"), home))
        #expect(isEligible(home.virtualBox.appendingPathComponent("Other"), home))
    }

    /// A VM folder renamed in Finder still holds its `.vbox` under the old
    /// name. Its settings are read anyway, so the base it is a linked clone of
    /// is refused. The renamed folder is not offered and not walked.
    @Test
    func renamedCloneFolderStillProtectsItsBase() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.virtualBoxVM("Base")
        let baseDisk = home.virtualBox.appendingPathComponent("Base/Base.vdi")
        try home.write("VirtualBox VMs/Clone-old/Clone.vbox", text: "<HardDisk uuid=\"{1}\" location=\"\(baseDisk.path)\"/>")
        try home.write("VirtualBox VMs/Clone-old/Snapshots/diff.vdi", bytes: 8192)

        let found = await scan(home)
        #expect(found.isEmpty)
        #expect(!isEligible(home.virtualBox.appendingPathComponent("Base"), home))
        #expect(!isEligible(home.path("VirtualBox VMs/Clone-old"), home))
    }

    /// A group folder that can't be listed might hold a clone, so every VM
    /// is refused rather than read as if the folder were empty.
    @Test
    func unreadableGroupFolderRefusesTheVM() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.virtualBoxVM("Win")
        let locked = home.virtualBox.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        #expect(!isEligible(home.virtualBox.appendingPathComponent("Win"), home))
    }

    /// The walk and the gate read a VM's files the same way: without case, as
    /// the default APFS volume does, and only in folders below the root the
    /// walk lists from. A disk in `ubuntu/Ubuntu.vbox`'s folder is neither
    /// listed nor trashed; a movie under a home that holds Tart's files is both.
    @Test
    func walkAndGateAgreeOnFoldersHoldingVMFiles() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Documents/ubuntu/Ubuntu.vbox", text: "<VirtualBox/>")
        try home.write("Documents/ubuntu/disk.vdi", bytes: 8192)
        try home.write("Documents/Renamed/Old Name.vbox", text: "<VirtualBox/>")
        try home.write("Documents/Renamed/Old Name.vdi", bytes: 8192)
        try home.write("config.json", text: "{}")
        try home.write("disk.img", bytes: 8192)
        try home.write("Documents/movie.mov", bytes: 8192)

        let found = await scan(home)
        #expect(Set(found.keys) == ["Documents/movie.mov"])
        #expect(!isEligible(home.path("Documents/ubuntu/disk.vdi"), home))
        #expect(!isEligible(home.path("Documents/Renamed/Old Name.vdi"), home))
        #expect(isEligible(home.path("Documents/movie.mov"), home))
    }

    @Test
    func virtualBoxMediaAndUUIDsAreRead() {
        let settings = """
            <HardDisk uuid="{AbC-1}" location="a.vdi" format="VDI"><HardDisk uuid="{d-2}" location="Snapshots/{d-2}.vdi"/></HardDisk>
            <DVDImage uuid="{e-3}" location="/x.iso"/><Image uuid="{F-4}"/><HardDisk uuid="{g-5}"/>
            """
        let media = LargeFileScanPolicy.virtualBoxMedia(in: settings)
        #expect(media.map(\.uuid) == ["abc-1", "d-2", "e-3"])
        #expect(media.map(\.location) == ["a.vdi", "Snapshots/{d-2}.vdi", "/x.iso"])
        #expect(LargeFileScanPolicy.virtualBoxUUIDs(in: settings) == ["abc-1", "d-2", "e-3", "f-4", "g-5"])
    }

    /// A `VirtualBox.xml` that names only the VM itself refuses nothing.
    @Test
    func registryNamingOnlyTheVMItselfRefusesNothing() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.virtualBoxVM("Win", settings: "<HardDisk location=\"Win.vdi\"/>")
        let settings = home.virtualBox.appendingPathComponent("Win/Win.vbox")
        try home.write("Library/VirtualBox/VirtualBox.xml", text: "<MachineEntry uuid=\"{1}\" src=\"\(settings.path)\"/>")

        #expect(Set(await scan(home).keys) == ["VirtualBox VMs/Win"])
        #expect(isEligible(home.virtualBox.appendingPathComponent("Win"), home))
    }

    /// `walkedFolder` judges a link only at the root itself. A linked
    /// `~/.tart` sits above Tart's root, so Purge lists nothing behind it.
    @Test
    func tartFolderBehindALinkIsNotListedOrTrashed() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Documents/tart-home/vms/mac/config.json", text: "{}")
        try home.write("Documents/tart-home/vms/mac/disk.img", bytes: 8192)
        try home.link(".tart", to: "Documents/tart-home")

        #expect(!(await scan(home).keys.contains(".tart/vms/mac")))
        #expect(!isEligible(home.path(".tart/vms/mac"), home))
    }

    /// A `.vbox` that can't be read might name the disk, so the VM is refused.
    @Test
    func vmIsRefusedWhenAnotherVMsSettingsCantBeRead() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.virtualBoxVM("Win")
        try home.virtualBoxVM("Other")
        let settings = home.virtualBox.appendingPathComponent("Other/Other.vbox")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path) }

        #expect(!isEligible(home.virtualBox.appendingPathComponent("Win"), home))
    }

    @Test
    func virtualBoxLocationsAreDecoded() {
        let settings = """
            <HardDisk location="../A&amp;B/A&amp;B.vdi"/><DVDImage location="/Users/me/ISO/&quot;x&quot;.iso"/>
            <Image location=""/>
            """
        #expect(LargeFileScanPolicy.virtualBoxLocations(in: settings) == ["../A&B/A&B.vdi", "/Users/me/ISO/\"x\".iso"])
        // `src` is matched as a whole attribute name, never inside another.
        #expect(LargeFileScanPolicy.virtualBoxRegisteredSettings(in: "<A imgsrc=\"x\" src=\"y\"/>") == ["y"])
    }

    // MARK: - Elsewhere

    /// A folder shaped like a VM outside its root is never offered, and never
    /// walked for loose files either: its disk trashed alone breaks the VM.
    @Test
    func vmShapedFoldersElsewhereAreNeitherOfferedNorWalked() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Documents/Old/Old.vbox", text: "<VirtualBox/>")
        try home.write("Documents/Old/Old.vdi", bytes: 8192)
        try home.write("Documents/Mac/config.json", text: "{}")
        try home.write("Documents/Mac/disk.img", bytes: 8192)
        try home.write("Documents/movie.mov", bytes: 8192)

        let found = await scan(home)
        #expect(Set(found.keys) == ["Documents/movie.mov"])
        for refused in ["Documents/Old", "Documents/Old/Old.vdi", "Documents/Mac", "Documents/Mac/disk.img"] {
            #expect(!isEligible(home.path(refused), home), "\(refused)")
        }
        #expect(isEligible(home.path("Documents/movie.mov"), home))
    }

    /// A VM reached through a link, as the VM folder or a group folder, is
    /// where the link leads, outside the root, and is refused.
    @Test
    func vmsReachedThroughLinksAreRefused() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("Documents/Linked/Linked.vbox", text: "<VirtualBox/>")
        try home.write("Documents/Group/Inner/Inner.vbox", text: "<VirtualBox/>")
        try home.link("VirtualBox VMs/Linked", to: "Documents/Linked")
        try home.link("VirtualBox VMs/Group", to: "Documents/Group")

        let found = await scan(home)
        #expect(found.keys.allSatisfy { !$0.hasPrefix("VirtualBox VMs") })
        #expect(!isEligible(home.path("VirtualBox VMs/Linked"), home))
        #expect(!isEligible(home.path("VirtualBox VMs/Group/Inner"), home))
    }

    // MARK: - Model

    @Test
    func folderAppsHaveNoBundleExtension() {
        #expect(VirtualMachineApp(bundleExtension: "vbox") == nil)
        #expect(VirtualMachineApp(bundleExtension: "") == nil)
        #expect(LargeFileKind.virtualMachineExtensions == ["pvm", "utm", "vmwarevm"])
        #expect(LargeFileCategory.category(forExtension: "vbox") == .other)
    }

    @Test
    func virtualBoxExplanationNamesTheAppOnlyWhenInstalled() {
        let installed = LargeFileKind.virtualMachine(.virtualBox, appInstalled: true).explanation
        let missing = LargeFileKind.virtualMachine(.virtualBox, appInstalled: false).explanation
        #expect(installed.contains("VirtualBox"))
        #expect(!missing.contains("VirtualBox"))
    }
}

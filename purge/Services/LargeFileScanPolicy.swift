import Foundation

/// Bounds for the Large & Old Files feature. This is deliberately separate from
/// DeletionSafetyPolicy because these are personal files, not cache files.
enum LargeFileScanPolicy {
    nonisolated static func scanRoots(home: URL) -> [URL] {
        [
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Movies", isDirectory: true),
            home.appendingPathComponent("Music", isDirectory: true),
            home.appendingPathComponent("Pictures", isDirectory: true)
        ]
    }

    /// iCloud Drive's own folder. With Desktop & Documents syncing, its Desktop
    /// and Documents entries are links to the home folders, which the walk
    /// doesn't follow, so nothing is listed twice. Walked only with Full Disk
    /// Access, like every other root here, and its files are offered for Remove
    /// Download only, never for the Trash: trashing them removes them from
    /// every device (#106). `isEligibleForDeletion` refuses them, being under
    /// `~/Library`.
    nonisolated static func iCloudDriveRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// Where Parallels Desktop and VMware Fusion keep VMs by default. These are
    /// walked for VM bundles only, never for loose files. UTM keeps its VMs in
    /// its container under `~/Library`, which Large Files stays out of.
    nonisolated static func virtualMachineRoots(home: URL) -> [URL] {
        [
            home.appendingPathComponent("Parallels", isDirectory: true),
            home.appendingPathComponent("Virtual Machines.localized", isDirectory: true)
        ]
    }

    /// A folder whose VMs are plain folders, and the app that owns them (#475).
    nonisolated struct FolderVirtualMachineRoot: Sendable {
        let url: URL
        let app: VirtualMachineApp
    }

    /// Where VirtualBox and Tart keep VMs. VirtualBox keeps each VM in a folder
    /// named after it, holding `<name>.vbox` and its disks, and a VM in a group
    /// one folder deeper per group. Tart keeps each VM in a folder directly in
    /// `~/.tart/vms`, holding `config.json` and `disk.img`. `TART_HOME` can
    /// move Tart's folder; Purge doesn't read it, so such VMs are not listed.
    /// Tart's `~/.tart/cache` holds pulled images and is never walked. Like the
    /// bundle roots, these are walked for VMs only, never for loose files.
    nonisolated static func folderVirtualMachineRoots(home: URL) -> [FolderVirtualMachineRoot] {
        [
            FolderVirtualMachineRoot(url: home.appendingPathComponent("VirtualBox VMs", isDirectory: true), app: .virtualBox),
            FolderVirtualMachineRoot(url: home.appendingPathComponent(".tart/vms", isDirectory: true), app: .tart)
        ]
    }

    /// Whether a folder is a VM of `app` to offer: it holds `<name>.vbox` for
    /// VirtualBox, `config.json` and `disk.img` for Tart, each a regular file,
    /// not a link. Names are compared without case, as the default APFS
    /// volume compares them. The shape alone, wherever the folder is: only a
    /// folder in one of `folderVirtualMachineRoots` is ever offered.
    nonisolated static func isVirtualMachineFolder(named folderName: String, entries: [ListingEntry], app: VirtualMachineApp) -> Bool {
        switch app {
        case .virtualBox:
            let settings = folderName + ".vbox"
            return entries.contains { $0.isRegularFile && $0.name.caseInsensitiveCompare(settings) == .orderedSame }
        case .tart:
            return hasRegularFile("config.json", in: entries) && hasRegularFile("disk.img", in: entries)
        case .parallels, .utm, .vmwareFusion:
            return false
        }
    }

    /// Whether a folder holds a VM's files: any regular `.vbox`, whatever the
    /// folder is called (a VM folder renamed in Finder still holds its disks),
    /// or Tart's `config.json` and `disk.img`. Such a folder is never walked
    /// for loose files and is never a VirtualBox group folder, so a disk in it
    /// is never listed or trashed alone.
    nonisolated static func holdsVirtualMachineFiles(_ entries: [ListingEntry]) -> Bool {
        if entries.contains(where: { $0.isRegularFile && ($0.name as NSString).pathExtension.lowercased() == "vbox" }) {
            return true
        }
        return hasRegularFile("config.json", in: entries) && hasRegularFile("disk.img", in: entries)
    }

    /// `isVirtualMachineFolder` for a folder on disk. False when it can't be listed.
    nonisolated static func hasVirtualMachineShape(_ folder: URL, app: VirtualMachineApp) -> Bool {
        guard let entries = DirectoryListing.entries(of: folder.path) else { return false }
        return isVirtualMachineFolder(named: folder.lastPathComponent, entries: entries, app: app)
    }

    /// `holdsVirtualMachineFiles` for a folder on disk. True when it can't be
    /// listed: what it holds is unknown.
    nonisolated static func holdsVirtualMachineFiles(_ folder: URL) -> Bool {
        guard let entries = DirectoryListing.entries(of: folder.path) else { return true }
        return holdsVirtualMachineFiles(entries)
    }

    private nonisolated static func hasRegularFile(_ name: String, in entries: [ListingEntry]) -> Bool {
        entries.contains { $0.isRegularFile && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A folder a VirtualBox walk goes into looking for VMs: a group folder.
    /// Never a hidden one, a bundle, a VM bundle, or one that holds a VM's
    /// files (`holdsVirtualMachineFiles`).
    nonisolated static func isVirtualBoxGroupFolder(_ folder: URL) -> Bool {
        let name = folder.lastPathComponent
        if name.hasPrefix(".") { return false }
        let ext = folder.pathExtension.lowercased()
        if excludedBundleExtensions.contains(ext) || LargeFileKind.virtualMachineExtensions.contains(ext) { return false }
        return !holdsVirtualMachineFiles(folder)
    }

    /// The folder a VirtualBox or Tart root is walked at: `walkedFolder` for
    /// the root, but nil when any folder above it up to home is a link.
    /// `walkedFolder` judges only a link at the root itself, and `~/.tart` sits
    /// between home and Tart's root, so a linked `~/.tart` would otherwise be
    /// followed wherever it leads (see the link entries of 2026-11 in
    /// `docs/safety-notes.md`). VMs behind such a link are not listed.
    nonisolated static func folderVirtualMachineWalkedFolder(
        for root: URL,
        home: URL,
        volumes: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        isLocalDisk: (URL) -> Bool = { LargeFileScanPolicy.isOnLocalDisk($0) }
    ) -> URL? {
        let parent = root.standardizedFileURL.deletingLastPathComponent()
        if PathContainment.containsSymlinkComponent(parent, home: home.standardizedFileURL.path) { return nil }
        return walkedFolder(for: root, home: home, volumes: volumes, isLocalDisk: isLocalDisk)
    }

    /// The app whose VM this folder is, or nil. The folder must be a real
    /// folder, not a link, with the shape `hasVirtualMachineShape` names, in
    /// the root for its app, matched where it really is against the folder
    /// the root is walked at, as `isEligibleForDeletion` matches the other
    /// roots. A Tart VM sits directly in its root. A VirtualBox VM may sit in
    /// group folders, each of which must pass `isVirtualBoxGroupFolder`, so a
    /// folder inside a VM is never a VM of its own. `roots` is for tests.
    nonisolated static func folderVirtualMachine(
        at url: URL,
        home: URL,
        volumes: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        isLocalDisk: (URL) -> Bool = { LargeFileScanPolicy.isOnLocalDisk($0) },
        roots: [FolderVirtualMachineRoot]? = nil
    ) -> VirtualMachineApp? {
        let std = url.standardizedFileURL
        var info = stat()
        guard lstat(std.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        if std.lastPathComponent.hasPrefix(".") { return nil }
        let real = std.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(std.lastPathComponent).standardizedFileURL
        for root in roots ?? folderVirtualMachineRoots(home: home) {
            guard let walked = folderVirtualMachineWalkedFolder(
                for: root.url, home: home, volumes: volumes, isLocalDisk: isLocalDisk
            ) else { continue }
            let rootPath = walked.resolvingSymlinksInPath().standardizedFileURL.path
            guard PathContainment.isInside(real.path, rootPath) else { continue }
            // A root that holds a VM's files is not walked, so nothing in it
            // is a VM to offer.
            if holdsVirtualMachineFiles(URL(fileURLWithPath: rootPath, isDirectory: true)) { return nil }
            let between = real.path.dropFirst(rootPath.count).split(separator: "/").dropLast()
            switch root.app {
            case .tart:
                guard between.isEmpty else { return nil }
            case .virtualBox:
                var folder = URL(fileURLWithPath: rootPath, isDirectory: true)
                for name in between {
                    folder.appendPathComponent(String(name), isDirectory: true)
                    guard isVirtualBoxGroupFolder(folder) else { return nil }
                }
            case .parallels, .utm, .vmwareFusion:
                return nil
            }
            return hasVirtualMachineShape(real, app: root.app) ? root.app : nil
        }
        return nil
    }

    /// Whether `root`, or any folder between it and `url`, holds a VM's
    /// files. The walk checks the same folders: it skips a root that holds
    /// them and every folder below it that does, so the gate refuses exactly
    /// what the walk leaves out.
    nonisolated static func isInsideFolderHoldingVirtualMachineFiles(_ url: URL, below root: String) -> Bool {
        var folder = url.standardizedFileURL.deletingLastPathComponent()
        while PathContainment.isSameOrInside(folder.path, root) {
            if holdsVirtualMachineFiles(folder) { return true }
            folder = folder.deletingLastPathComponent()
        }
        return false
    }

    /// Managed libraries and bundles we never descend into or offer for deletion.
    nonisolated static let excludedFolderNames: Set<String> = [
        "Photos Library.photoslibrary",
        "Photo Booth Library",
        "iMovie Library.imovielibrary",
        "iMovie Theater.theater",
        "TV Library.tvlibrary",
        "Music Library.musiclibrary",
        "GarageBand"
    ]

    /// Dependency and build folders that belong to a project, not to the person
    /// using the Mac. Large Files is for things you downloaded or made — videos,
    /// disk images, archives, models. A checked-out `node_modules` binary is not
    /// a file anyone chose to keep, and Dev Projects already offers these folders
    /// whole, where deleting them actually means something. Listing their
    /// contents here individually is noise.
    ///
    /// Hidden variants (`.build`, `.gradle`, `.venv`, `.next`, …) need no entry:
    /// the scan skips hidden files and the dot-prefix rule below catches them.
    nonisolated static let projectArtifactFolderNames: Set<String> = [
        "node_modules",
        "bower_components",
        "Pods",
        "Carthage",
        "DerivedData",
        "vendor",
        "venv",
        "__pycache__",
        "site-packages",
        "target",
        // Build output. `build` is the big one: Xcode writes
        // `build/SourcePackages/repositories/…` (bare git repos full of large
        // .pack files) and Gradle writes `build/intermediates/…` (stripped .so
        // libraries and source maps). Everything under it is regenerated by the
        // next build.
        "build",
        "Build",
        "SourcePackages",
        "intermediates",
        "dist",
        "out"
    ]

    nonisolated static func isExcludedDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return true }
        if excludedFolderNames.contains(name) { return true }
        if projectArtifactFolderNames.contains(name) { return true }
        return excludedBundleExtensions.contains(url.pathExtension.lowercased())
    }

    /// Packages walked as one item, never into: apps, media libraries and bundles.
    private nonisolated static let excludedBundleExtensions: Set<String> = [
        "app", "photoslibrary", "imovielibrary", "tvlibrary", "musiclibrary", "theater", "bundle"
    ]

    nonisolated static func isInsideExcludedDirectory(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.dropLast().contains(where: isExcludedComponent)
    }

    /// A folder name whose contents are never offered.
    private nonisolated static func isExcludedComponent(_ component: String) -> Bool {
        if component.hasPrefix(".") { return true }
        if excludedFolderNames.contains(component) { return true }
        if projectArtifactFolderNames.contains(component) { return true }
        let ext = (component as NSString).pathExtension.lowercased()
        if excludedBundleExtensions.contains(ext) { return true }
        // A file inside a VM is part of its disk. Only the whole bundle goes.
        return LargeFileKind.virtualMachineExtensions.contains(ext)
    }

    /// The folder a root is walked at. Usually the root itself. When the user
    /// moved the folder and left a link in its place
    /// (`~/Documents -> /Volumes/Data/Documents`), it is the folder the link
    /// leads to: the enumerator never follows a link, not even at the root, so
    /// such a root used to be listed as empty (#273). Links inside the folder
    /// are still never followed.
    ///
    /// A link is followed only to a folder the user could have moved their
    /// files to: one inside the home folder, or on a volume under `/Volumes`,
    /// on a disk attached to this Mac. Nil for any other target, and the root
    /// is not walked. That rules out `~/Library`, where a cloud provider's
    /// folder deletes a trashed file on every device, the home folder and the
    /// folders above it, which hold `~/Library`, the rest of the system, and
    /// any folder whose files the gate refuses anyway, such as a hidden one.
    /// It also rules out a whole drive, or a copy of a Mac or of a home folder
    /// on one: walked, it would offer other users' files and every backup copy.
    ///
    /// The scan walks what this returns, and `isEligibleForDeletion` asks again
    /// at delete time, so a link changed after the scan is read as it is then.
    /// `volumes` and `isLocalDisk` are for tests.
    nonisolated static func walkedFolder(
        for root: URL,
        home: URL,
        volumes: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        isLocalDisk: (URL) -> Bool = { LargeFileScanPolicy.isOnLocalDisk($0) }
    ) -> URL? {
        let fm = FileManager.default
        guard (try? fm.destinationOfSymbolicLink(atPath: root.path)) != nil else { return root }
        // Resolved in full, so a link to a link ends at the folder, and in the
        // spelling the store and the gate use (`/var`, not `/private/var`).
        let target = root.resolvingSymlinksInPath().standardizedFileURL
        let path = target.path
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }

        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        let volumesPath = volumes.resolvingSymlinksInPath().standardizedFileURL.path
        guard PathContainment.isInside(path, homePath) || PathContainment.isInside(path, volumesPath) else { return nil }
        if PathContainment.isSameOrInside(homePath, path) { return nil }
        // Without case: a link can spell it `~/library/CloudStorage`, which is
        // `~/Library` on the default volume, and macOS 13 and 14 keep the
        // link's spelling when resolving it.
        if target.pathComponents.contains(where: { $0.caseInsensitiveCompare("Library") == .orderedSame }) {
            return nil
        }
        if target.pathComponents.contains(where: isExcludedComponent) { return nil }
        // By identity too, which no spelling gets past (2026-10-22 in
        // `docs/safety-notes.md`): never `~/Library` or a folder in it, never
        // the home folder or a folder above it.
        let lineage = identities(ofFolderAndAbove: target)
        if let library = FileIdentity(path: homePath + "/Library"), lineage.contains(library) { return nil }
        if let own = FileIdentity(path: path), identities(ofFolderAndAbove: home).contains(own) { return nil }

        if target.deletingLastPathComponent().path == volumesPath { return nil }
        if (try? target.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true { return nil }
        if wholeDiskMarkers.contains(where: { fm.fileExists(atPath: target.appendingPathComponent($0).path) }) {
            return nil
        }
        guard isLocalDisk(target) else { return nil }
        return target
    }

    /// Folders that mark a whole Mac (`System`, `Users`), a home folder
    /// (`Library`) or a Time Machine drive (`Backups.backupdb`). A link to a
    /// folder holding one of them is not a folder someone moved.
    private nonisolated static let wholeDiskMarkers = ["System", "Users", "Library", "Backups.backupdb"]

    /// A disk attached to this Mac, with a file system macOS trashes on by
    /// itself. The uninstaller's drive folders use the same rule (#99).
    nonisolated static func isOnLocalDisk(_ url: URL) -> Bool {
        AppFolders.isOnLocalDisk(url)
    }

    /// The folder and every folder above it, by file identity.
    private nonisolated static func identities(ofFolderAndAbove folder: URL) -> Set<FileIdentity> {
        var result = Set<FileIdentity>()
        var current = folder.resolvingSymlinksInPath().standardizedFileURL
        while true {
            if let identity = FileIdentity(path: current.path) { result.insert(identity) }
            guard current.path != "/" else { return result }
            current = current.deletingLastPathComponent()
        }
    }

    /// Whether the path is in `~/Library`, compared without case: on the
    /// default volume `~/library` is the same folder.
    private nonisolated static func isInHomeLibrary(_ path: String, home: URL) -> Bool {
        let spellings = [home.standardizedFileURL.path, home.resolvingSymlinksInPath().standardizedFileURL.path]
        return spellings.contains { home in
            path.range(of: home + "/Library/", options: [.anchored, .caseInsensitive]) != nil
        }
    }

    /// Safari's unfinished download: a `.download` folder directly in
    /// `~/Downloads` with Safari's `Info.plist` inside. Any other folder that
    /// happens to end in `.download` is the user's and is walked like any folder.
    nonisolated static func isSafariDownloadBundle(_ url: URL, home: URL) -> Bool {
        guard url.pathExtension.lowercased() == "download" else { return false }
        // Resolved on both sides: the enumerator spells a temporary home
        // `/private/var/…` while the caller may pass `/var/…`.
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let parent = url.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard parent == downloads else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Info.plist").path)
    }

    /// Whether a VM may be running: its app is open, or the bundle holds a lock
    /// file. Trashing a running VM is a rename on the same volume, so the VM
    /// keeps writing its disk inside the Trash and emptying the Trash loses it.
    /// Checked when the scan lists the VM and again just before it is trashed,
    /// because the app can open between the two (see the 2026-09-21 Chrome
    /// entry in `docs/safety-notes.md`). Only the bundle's top two levels are
    /// read, where VMware puts its `.lck` folders and Parallels its `.lock` files.
    nonisolated static func virtualMachineIsInUse(
        _ bundle: URL,
        isAppRunning: (String) -> Bool = { DeletionSafetyPolicy.isAppRunning(bundleID: $0) }
    ) -> Bool {
        if let app = VirtualMachineApp(bundleExtension: bundle.pathExtension),
           let bundleID = app.bundleID, isAppRunning(bundleID) {
            return true
        }
        guard let enumerator = FileManager.default.enumerator(
            at: bundle, includingPropertiesForKeys: nil, options: []
        ) else { return false }
        while let next = enumerator.nextObject() as? URL {
            if enumerator.level >= 2 { enumerator.skipDescendants() }
            let ext = next.pathExtension.lowercased()
            if ext == "lck" || ext == "lock" { return true }
        }
        return false
    }

    /// Whether a VirtualBox or Tart VM may be running: VirtualBox is open, or
    /// any process of the user's has a file open, a working folder or its
    /// program inside the VM's folder. That finds a VM VirtualBox runs without
    /// its window (`VBoxHeadless`), one whose window stayed open after
    /// VirtualBox quit, and a running Tart VM, where `tart` holds
    /// `config.json` and Apple's Virtualization process holds `disk.img`
    /// (probe for #475). When the open files can't be read the VM counts as
    /// in use. Checked when the scan lists the VM and again just before it
    /// is trashed. `openFiles` is for tests.
    nonisolated static func folderVirtualMachineIsInUse(
        _ folder: URL,
        app: VirtualMachineApp,
        isAppRunning: (String) -> Bool = { DeletionSafetyPolicy.isAppRunning(bundleID: $0) },
        openFiles: OpenFileCheck.Lister = OpenFileCheck.liveListing
    ) -> Bool {
        if let bundleID = app.bundleID, isAppRunning(bundleID) { return true }
        return OpenFileCheck.check(folders: [folder], lister: openFiles) != .free
    }

    /// Whether another VirtualBox VM uses a disk inside `vm`. Trashing the VM
    /// would leave that VM with a missing disk. Two ways count:
    ///
    /// - A `location` in another VM's settings resolves inside `vm`. A linked
    ///   clone names its base disk this way.
    /// - Another VM's settings name, by `uuid`, a disk whose `location` is
    ///   inside `vm`. Since VirtualBox 4.0 a disk sits in one media registry,
    ///   so a VM that attaches an existing disk, or a shareable one, names it
    ///   by `uuid` alone. The locations come from `vm`'s own settings and from
    ///   the global registry in `~/Library/VirtualBox/VirtualBox.xml`.
    ///
    /// Another VM's settings are every regular `.vbox` in a folder in the
    /// root, at any group depth and through links, whatever the folder is
    /// called, and every VM `VirtualBox.xml` registers, wherever it is. A
    /// folder that can't be listed, or settings that can't be read, count as
    /// using the disk.
    nonisolated static func virtualBoxDiskIsShared(_ vm: URL, root: URL, home: URL) -> Bool {
        let fm = FileManager.default
        let vmPath = vm.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        // Without case: on the default volume a `.vbox` may spell the folder
        // differently.
        func isInsideVM(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
            return path == vmPath || path.hasPrefix(vmPath + "/")
        }
        func resolve(_ location: String, against folder: URL) -> URL {
            location.hasPrefix("/") ? URL(fileURLWithPath: location) : folder.appendingPathComponent(location)
        }
        // Read where a link leads: this only reads, and a clone may be kept
        // elsewhere behind a link in the root.
        func settingsFiles(in folder: URL) -> [URL]? {
            let folder = folder.resolvingSymlinksInPath()
            guard let entries = DirectoryListing.entries(of: folder.path) else { return nil }
            return entries
                .filter { $0.isRegularFile && ($0.name as NSString).pathExtension.lowercased() == "vbox" }
                .map { folder.appendingPathComponent($0.name) }
        }

        // The VM's own settings, then the other VMs' settings in the root,
        // read by identity so a link can't lead the walk in a circle.
        guard let ownSettings = settingsFiles(in: vm) else { return true }
        let own = FileIdentity(path: vm.path)
        var otherSettings: [URL] = []
        var visited = Set<FileIdentity>()
        func visit(_ folder: URL) -> Bool {
            guard let identity = FileIdentity(path: folder.path) else { return false }
            guard visited.insert(identity).inserted else { return true }
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
            for name in names where !name.hasPrefix(".") {
                let child = folder.appendingPathComponent(name, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                if let identity = FileIdentity(path: child.path), identity == own { continue }
                guard let files = settingsFiles(in: child) else { return false }
                if !files.isEmpty {
                    otherSettings += files
                    continue
                }
                let ext = child.pathExtension.lowercased()
                if excludedBundleExtensions.contains(ext) || LargeFileKind.virtualMachineExtensions.contains(ext) { continue }
                guard visit(child) else { return false }
            }
            return true
        }
        guard visit(root) else { return true }

        // VirtualBox's own list of VMs and its global media registry.
        let virtualBoxHome = home.appendingPathComponent("Library/VirtualBox", isDirectory: true)
        let registryURL = virtualBoxHome.appendingPathComponent("VirtualBox.xml")
        var registry: String?
        if fm.fileExists(atPath: registryURL.path) {
            guard let text = try? String(contentsOf: registryURL, encoding: .utf8) else { return true }
            registry = text
            for source in virtualBoxRegisteredSettings(in: text) {
                let settings = resolve(source, against: virtualBoxHome)
                guard fm.fileExists(atPath: settings.path), !isInsideVM(settings) else { continue }
                otherSettings.append(settings)
            }
        }

        // The disks inside the VM, by `uuid`.
        var diskIDs = Set<String>()
        func collectDiskIDs(_ text: String, against folder: URL) {
            for medium in virtualBoxMedia(in: text) where isInsideVM(resolve(medium.location, against: folder)) {
                diskIDs.insert(medium.uuid)
            }
        }
        for settings in ownSettings {
            guard let text = try? String(contentsOf: settings, encoding: .utf8) else { return true }
            collectDiskIDs(text, against: vm)
        }
        if let registry { collectDiskIDs(registry, against: virtualBoxHome) }

        for settings in otherSettings {
            guard let text = try? String(contentsOf: settings, encoding: .utf8) else { return true }
            let folder = settings.deletingLastPathComponent()
            if virtualBoxLocations(in: text).contains(where: { isInsideVM(resolve($0, against: folder)) }) {
                return true
            }
            if !diskIDs.isDisjoint(with: virtualBoxUUIDs(in: text)) { return true }
        }
        return false
    }

    /// Each disk or image tag in VirtualBox's XML that has both a `uuid` and
    /// a `location`, with the `uuid` in `virtualBoxUUIDs`'s form.
    nonisolated static func virtualBoxMedia(in text: String) -> [(uuid: String, location: String)] {
        text.matches(of: /<(?:HardDisk|DVDImage|FloppyImage)\b[^>]*>/).compactMap { match in
            let tag = String(match.0)
            guard let uuid = virtualBoxUUIDs(in: tag).first, let location = virtualBoxLocations(in: tag).first
            else { return nil }
            return (uuid, location)
        }
    }

    /// Every `uuid="…"` in VirtualBox's XML, lowercased and without braces, as
    /// a disk is named wherever it is attached.
    nonisolated static func virtualBoxUUIDs(in text: String) -> Set<String> {
        Set(text.matches(of: /\suuid="([^"]*)"/).map {
            String($0.1).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        }.filter { !$0.isEmpty })
    }

    /// Every `location="…"` in a `.vbox` file, the disks and images it names,
    /// decoded. An XML attribute always follows a space, so `\s` keeps another
    /// attribute that ends in the same name from matching.
    nonisolated static func virtualBoxLocations(in settings: String) -> [String] {
        decodedXMLValues(settings.matches(of: /\slocation="([^"]*)"/).map { String($0.1) })
    }

    /// Every `src="…"` in `VirtualBox.xml`: the `.vbox` of each registered VM.
    nonisolated static func virtualBoxRegisteredSettings(in registry: String) -> [String] {
        decodedXMLValues(registry.matches(of: /\ssrc="([^"]*)"/).map { String($0.1) })
    }

    /// Attribute values with XML's five entities decoded, empty ones dropped.
    private nonisolated static func decodedXMLValues(_ values: [String]) -> [String] {
        values.map { value in
            value
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
        }.filter { !$0.isEmpty }
    }

    /// A file may be deleted only if it is a regular file under one of the scan
    /// roots or a folder the user added, and nowhere near Library or system
    /// locations.
    ///
    /// Two kinds of folder are allowed, each as the whole item Large Files lists:
    /// a VM bundle (`.pvm`, `.utm`, `.vmwarevm`) that is not in use, under a scan
    /// root or a VM root, and a Safari download bundle in `~/Downloads`. A loose
    /// file in a VM root is never eligible; that walk lists bundles only. Nor is a
    /// file inside either kind of bundle, or inside a folder shaped like an
    /// Ollama store, which the walk skips.
    ///
    /// This is Large Files' own gate, not `DeletionSafetyPolicy.evaluate(_:)`:
    /// these are the user's files, which the cache allowlist refuses by design.
    ///
    /// The roots are matched where the item really is: its folder with every
    /// link resolved, against the folder each root is walked at
    /// (`walkedFolder`). A file under a linked root passes by its real path
    /// (#273), and one reached through a link anywhere else does not, so the
    /// `~/Library` and excluded-folder checks also apply to where it really is.
    /// `volumes` and `isLocalDisk` are for tests, as in `walkedFolder`.
    ///
    /// A VirtualBox or Tart VM is a third kind of folder (#475), allowed only
    /// where `folderVirtualMachine` finds it, only while it is not in use, and
    /// for VirtualBox only while no other VM uses a disk in it. Nothing inside
    /// a folder of a VM's shape is eligible, wherever that folder is.
    /// `openFiles` is for tests.
    ///
    /// The folders the user added in Settings (#318) count as scan roots too,
    /// read again from disk unless the caller passes `addedRoots` it just read
    /// for a batch. A file under one must also sit on a disk attached to this
    /// Mac, so a share mounted inside the folder is refused.
    nonisolated static func isEligibleForDeletion(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        volumes: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        isLocalDisk: (URL) -> Bool = { LargeFileScanPolicy.isOnLocalDisk($0) },
        isAppRunning: (String) -> Bool = { DeletionSafetyPolicy.isAppRunning(bundleID: $0) },
        openFiles: OpenFileCheck.Lister = OpenFileCheck.liveListing,
        addedRoots: [URL]? = nil
    ) -> Bool {
        let fm = FileManager.default
        let std = url.standardizedFileURL
        let path = std.path

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        if path.contains("/Library/") || isInHomeLibrary(path, home: home) { return false }

        // A VirtualBox or Tart VM, asked before the excluded-folder checks,
        // which refuse everything under `~/.tart`. This is the only way in for
        // a path there, and only for the VM folder itself.
        if isDir.boolValue,
           let app = folderVirtualMachine(at: std, home: home, volumes: volumes, isLocalDisk: isLocalDisk) {
            let real = std.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(std.lastPathComponent).standardizedFileURL
            if real.path.contains("/Library/") || isInHomeLibrary(real.path, home: home) { return false }
            if [std, real].contains(where: {
                AIModelScanPolicy.isOllamaStore($0) || AIModelScanPolicy.isInsideOllamaStore($0)
            }) { return false }
            if folderVirtualMachineIsInUse(std, app: app, isAppRunning: isAppRunning, openFiles: openFiles) {
                return false
            }
            if app == .virtualBox,
               let root = folderVirtualMachineRoots(home: home).first(where: { $0.app == .virtualBox }),
               let walked = folderVirtualMachineWalkedFolder(
                   for: root.url, home: home, volumes: volumes, isLocalDisk: isLocalDisk
               ),
               virtualBoxDiskIsShared(real, root: walked, home: home) {
                return false
            }
            return true
        }

        if isInsideExcludedDirectory(std) { return false }

        // The folder is resolved, not the item: a link the user picked is
        // trashed as the link, wherever it points.
        let real = std.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(std.lastPathComponent).standardizedFileURL
        let realPath = real.path
        if realPath.contains("/Library/") || isInHomeLibrary(realPath, home: home) { return false }
        if isInsideExcludedDirectory(real) { return false }
        // Nothing in a folder shaped like an Ollama store is a Large Files
        // row, whether or not Purge knows the store is Ollama's. A blob
        // trashed alone breaks every model that uses it.
        if AIModelScanPolicy.isInsideOllamaStore(std) || AIModelScanPolicy.isInsideOllamaStore(real) { return false }
        // Nor is the store itself, whatever it is named (`models.pvm`).
        if isDir.boolValue, AIModelScanPolicy.isOllamaStore(std) || AIModelScanPolicy.isOllamaStore(real) {
            return false
        }
        func walkedPath(_ root: URL) -> String? {
            walkedFolder(for: root, home: home, volumes: volumes, isLocalDisk: isLocalDisk).map {
                $0.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            }
        }
        func isUnder(_ roots: [URL]) -> Bool {
            roots.contains { root in
                walkedPath(root).map { realPath.hasPrefix($0) } ?? false
            }
        }

        // Inside a Safari download bundle: only the whole bundle goes.
        let downloadsRoot = home.appendingPathComponent("Downloads", isDirectory: true)
        if let downloads = walkedPath(downloadsRoot),
           realPath.hasPrefix(downloads),
           let first = realPath.dropFirst(downloads.count).split(separator: "/").first,
           realPath.count > downloads.count + first.count,
           isSafariDownloadBundle(URL(fileURLWithPath: downloads + first), home: home) {
            return false
        }

        // An added folder is never a link (`ScanFolders` refuses one), so its
        // path is where it is walked. Nothing the walk skips below it passes:
        // a copy of a Mac, a home folder or a backup, or another sync
        // service's folder.
        let added = addedRoots ?? ScanFolders.roots(home: home, volumes: volumes, isLocalDisk: isLocalDisk)
        func isUnderAddedFolder() -> Bool {
            let holding = added.first { root in
                realPath.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/")
            }
            guard let holding, isLocalDisk(real) else { return false }
            let rootPath = holding.resolvingSymlinksInPath().standardizedFileURL.path
            // `Library` in any case: on a drive `library` is the same folder,
            // and the check above matches only `/Library/` (#318 review).
            let below = realPath.dropFirst(rootPath.count).split(separator: "/")
            if below.contains(where: { $0.caseInsensitiveCompare("Library") == .orderedSame }) { return false }
            // The added folder itself, read again: it may have gained a sync
            // service's marker since the batch read the list (#318 review).
            if ScanFolders.isOffLimits(URL(fileURLWithPath: rootPath, isDirectory: true)) { return false }
            // A bundle is judged itself too: it may hold a copied Mac by now.
            if isDir.boolValue, ScanFolders.isOffLimits(real) { return false }
            return !ScanFolders.crossesOffLimits(from: rootPath, to: real.deletingLastPathComponent())
        }

        // Nor anything inside a folder holding a VirtualBox or Tart VM's
        // files: a disk trashed alone breaks the VM (#475). Asked of the root
        // the item is under and the folders below it, the ones the walk checks.
        let walkedRoots = scanRoots(home: home).compactMap { walkedPath($0).map { String($0.dropLast()) } }
            + added.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        if let holding = walkedRoots.filter({ PathContainment.isInside(realPath, $0) }).max(by: { $0.count < $1.count }),
           isInsideFolderHoldingVirtualMachineFiles(real, below: holding) {
            return false
        }

        guard isDir.boolValue else { return isUnder(scanRoots(home: home)) || isUnderAddedFolder() }

        if isSafariDownloadBundle(std, home: home) { return isUnder([downloadsRoot]) }
        guard VirtualMachineApp(bundleExtension: std.pathExtension) != nil else { return false }
        guard isUnder(scanRoots(home: home)) || isUnder(virtualMachineRoots(home: home)) || isUnderAddedFolder()
        else { return false }
        return !virtualMachineIsInUse(std, isAppRunning: isAppRunning)
    }
}

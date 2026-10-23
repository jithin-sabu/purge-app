import Foundation
import SwiftUI

nonisolated enum LargeFileCategory: String, CaseIterable, Identifiable, Hashable {
    case video
    case audio
    case image
    case pdf
    case archive
    case document
    case aiModel
    case virtualMachine
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video: return String(localized: "Videos")
        case .audio: return String(localized: "Audio")
        case .image: return String(localized: "Images")
        case .pdf: return String(localized: "PDFs")
        case .archive: return String(localized: "Archives")
        case .document: return String(localized: "Documents")
        case .aiModel: return String(localized: "AI Models")
        case .virtualMachine: return String(localized: "Virtual Machines")
        case .other: return String(localized: "Other")
        }
    }

    var symbolName: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .archive: return "archivebox"
        case .document: return "doc.text"
        case .aiModel: return "cpu"
        case .virtualMachine: return "desktopcomputer"
        case .other: return "doc"
        }
    }

    static func category(forExtension ext: String) -> LargeFileCategory {
        switch ext.lowercased() {
        case "mov", "mp4", "m4v", "avi", "mkv", "wmv", "flv", "webm", "mpg", "mpeg", "hevc", "prores":
            return .video
        case "mp3", "wav", "aac", "flac", "m4a", "aiff", "aif", "ogg", "wma":
            return .audio
        case "jpg", "jpeg", "png", "gif", "tiff", "tif", "bmp", "heic", "heif", "raw", "psd", "webp", "svg":
            return .image
        case "pdf":
            return .pdf
        case "zip", "rar", "7z", "tar", "gz", "bz2", "dmg", "pkg", "iso", "xip", "ipsw":
            return .archive
        case "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "txt", "rtf", "csv", "epub":
            return .document
        case "gguf", "safetensors", "onnx", "pt", "pth", "ckpt", "tdict", "mlmodelc", "mlpackage":
            return .aiModel
        default:
            return VirtualMachineApp(bundleExtension: ext) == nil ? .other : .virtualMachine
        }
    }
}

/// The app that owns a virtual machine bundle. The app keeps its own list of
/// VMs, so a VM trashed behind its back stays listed there as missing.
nonisolated enum VirtualMachineApp: String, CaseIterable, Hashable, Sendable {
    case parallels
    case utm
    case vmwareFusion

    init?(bundleExtension ext: String) {
        let ext = ext.lowercased()
        guard let app = Self.allCases.first(where: { $0.bundleExtension == ext }) else { return nil }
        self = app
    }

    var bundleExtension: String {
        switch self {
        case .parallels: return "pvm"
        case .utm: return "utm"
        case .vmwareFusion: return "vmwarevm"
        }
    }

    /// Product names, not translated.
    var displayName: String {
        switch self {
        case .parallels: return "Parallels Desktop"
        case .utm: return "UTM"
        case .vmwareFusion: return "VMware Fusion"
        }
    }

    var bundleID: String {
        switch self {
        case .parallels: return "com.parallels.desktop.console"
        case .utm: return "com.utmapp.UTM"
        case .vmwareFusion: return "com.vmware.fusion"
        }
    }
}

/// What a Large Files row is, when its size alone doesn't say. A 25 GB `.ipsw`
/// reads as an unknown blob without a label, and people hesitate to act on it.
nonisolated enum LargeFileKind: Hashable, Sendable {
    case restoreImage
    /// `appInstalled` is looked up once per scan, never while drawing a row.
    case virtualMachine(VirtualMachineApp, appInstalled: Bool)
    case unfinishedDownload
    /// A downloaded AI model and the store it came from. The explanation says
    /// what the owning app will think once the row is trashed (#157).
    case aiModel(AIModelScanPolicy.Store)

    /// VM bundles are one item: listed and trashed whole, never walked. A file
    /// inside a VM is part of a disk, and trashing it alone breaks the VM.
    /// Safari's `.download` bundle is one item too, but only where Safari puts
    /// it, so `LargeFileScanPolicy.isSafariDownloadBundle` decides that by
    /// location, not by extension.
    static let virtualMachineExtensions: Set<String> = Set(VirtualMachineApp.allCases.map(\.bundleExtension))

    /// VM kinds come back with `appInstalled: false`. The scanner fills it in.
    static func kind(forExtension ext: String) -> LargeFileKind? {
        let ext = ext.lowercased()
        if ext == "ipsw" { return .restoreImage }
        if let app = VirtualMachineApp(bundleExtension: ext) {
            return .virtualMachine(app, appInstalled: false)
        }
        if DeletionSafetyPolicy.unfinishedDownloadExtensions.contains(ext) { return .unfinishedDownload }
        return nil
    }

    var badgeText: String {
        switch self {
        case .restoreImage:
            return String(localized: "Restore image")
        case .virtualMachine(let app, _):
            return String(localized: "Virtual machine · \(app.displayName)")
        case .unfinishedDownload:
            return String(localized: "Unfinished download")
        case .aiModel:
            return String(localized: "AI model")
        }
    }

    var explanation: String {
        switch self {
        case .restoreImage:
            return String(localized: "macOS restore image. Only needed to set up a Mac, device or virtual machine. Safe to remove once setup is done.")
        case .virtualMachine(let app, let appInstalled):
            guard appInstalled else {
                return String(localized: "Virtual machine. Everything inside it goes with it.")
            }
            // Whole sentences per app, so each one translates as a unit.
            switch app {
            case .parallels:
                return String(localized: "Virtual machine. Everything inside it goes with it. Remove it in Parallels Desktop so the app's list of virtual machines stays right.")
            case .utm:
                return String(localized: "Virtual machine. Everything inside it goes with it. Remove it in UTM so the app's list of virtual machines stays right.")
            case .vmwareFusion:
                return String(localized: "Virtual machine. Everything inside it goes with it. Remove it in VMware Fusion so the app's list of virtual machines stays right.")
            }
        case .unfinishedDownload:
            return String(localized: "Unfinished download. It can't be opened as it is. Remove it unless the download is still running.")
        case .aiModel(let store):
            return store.explanation
        }
    }
}

nonisolated struct LargeFile: Identifiable, Hashable {
    let path: URL
    let sizeBytes: Int64
    /// Most recent of last-accessed and last-modified. The file's last touched time.
    let lastUsed: Date
    let category: LargeFileCategory
    var isSelected: Bool = false

    /// Set when the file name on disk isn't what the user calls the thing. An
    /// Ollama model lives at `manifests/registry.ollama.ai/library/gemma4/latest`
    /// but the user knows it as `gemma4:latest`.
    let displayNameOverride: String?

    /// Shown instead of a directory path for rows whose real location is an
    /// implementation detail — "Ollama" reads better than `~/.ollama/models/…`.
    let sourceLabel: String?

    /// Every path that must be removed for this row to be gone. Ordinary files
    /// own exactly one; an AI model spans a manifest plus the blobs it alone
    /// references.
    let componentPaths: [URL]

    /// True when this file is an iCloud item (`isUbiquitousItem`). Trashing it
    /// removes the file from the user's other devices as well. Defaults to false
    /// so rows that never asked (AI models, and every existing call site) stay
    /// unbadged.
    let syncsWithICloud: Bool

    /// False for a file found in iCloud Drive's own folder: Large Files offers
    /// those for Remove Download only (#106). The delete gate refuses them too.
    let canMoveToTrash: Bool

    /// True when, at scan time, the file passed every `ICloudDownloadPolicy`
    /// check. A hint for the buttons and the sheet only: the remover checks
    /// again, from disk, right before it acts.
    let canRemoveDownload: Bool

    /// What the row is when its size alone doesn't say: a restore image, a
    /// virtual machine, an unfinished download. Nil for everything else.
    let kind: LargeFileKind?

    /// Stored (not computed) so identity checks in row bindings, sorting, and list
    /// animations don't re-standardize the URL on every access — the repeated cost
    /// made selection feel delayed compared to App Caches.
    let id: String

    /// Everything a search query is matched against, joined once at init for the
    /// same reason `id` is stored: it's read for every row on every keystroke, so
    /// rebuilding it per access would re-walk the URL hundreds of times a character.
    ///
    /// Holds the display name, the raw parent path, the `sourceLabel` when there
    /// is one, and the kind's badge ("Virtual machine") when there is one — so a
    /// query finds a row by what it's called, what it is, *or* where it lives. The
    /// path and label differ for labelled rows: an Ollama model shows "Ollama" but sits in
    /// `~/.ollama/models`, and both should be findable. Deliberately uses the raw
    /// path rather than `locationLabel`/`displayDirectoryPath`: that helper resolves
    /// the home directory through FileManager and is MainActor-isolated under this
    /// target's default isolation, and `LargeFile` is built inside the scanners'
    /// detached tasks. The raw path matches the same words anyway ("Downloads" hits
    /// either form) — only the `~` prefix differs, which nobody searches for.
    let searchHaystack: String

    init(
        path: URL,
        sizeBytes: Int64,
        lastUsed: Date,
        category: LargeFileCategory,
        isSelected: Bool = false,
        displayNameOverride: String? = nil,
        sourceLabel: String? = nil,
        componentPaths: [URL]? = nil,
        syncsWithICloud: Bool = false,
        canMoveToTrash: Bool = true,
        canRemoveDownload: Bool = false,
        kind: LargeFileKind? = nil
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.lastUsed = lastUsed
        self.category = category
        self.isSelected = isSelected
        self.displayNameOverride = displayNameOverride
        self.sourceLabel = sourceLabel
        self.componentPaths = (componentPaths ?? [path]).map(\.standardizedFileURL)
        self.syncsWithICloud = syncsWithICloud
        self.canMoveToTrash = canMoveToTrash
        self.canRemoveDownload = canRemoveDownload
        let kind = kind ?? LargeFileKind.kind(forExtension: path.pathExtension)
        self.kind = kind
        let standardized = path.standardizedFileURL
        self.id = standardized.path
        self.searchHaystack = [
            displayNameOverride ?? path.lastPathComponent,
            standardized.deletingLastPathComponent().path,
            sourceLabel,
            kind?.badgeText,
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    /// Whether this row should stay visible for `query`. Whitespace splits the query
    /// into terms that must *all* match somewhere in `searchHaystack`, so "wedding
    /// mov" finds the file regardless of what sits between the two words — matching
    /// the whole string verbatim would find nothing. An all-whitespace or empty query
    /// matches everything, so callers don't special-case the unfiltered list.
    ///
    /// Case- and diacritic-insensitive: someone typing "resume" should still find
    /// `Résumé.pdf`.
    func matches(searchQuery query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy { term in
            searchHaystack.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
    /// Whether this row may leave the list, given the paths a delete run
    /// actually removed. Multi-part rows survive a partial delete: a model whose
    /// manifest trashed but whose blobs didn't still occupies the disk.
    func isFullyRemoved(byDeleting deletedPaths: Set<String>) -> Bool {
        componentPaths.allSatisfy { deletedPaths.contains($0.path) }
    }

    /// Copy for the trash confirmation when `syncedCount` of the `totalCount`
    /// files being trashed also live on the user's other devices. Nothing to say
    /// when none do. iCloud items still go to the Trash, so they can be put back.
    static func iCloudDeletionWarning(syncedCount: Int, totalCount: Int) -> String? {
        guard syncedCount >= 1 else { return nil }
        // Whole sentences, not a shared tail, so each one translates as a unit.
        if totalCount == 1 {
            return String(localized: "The file you're trashing syncs with iCloud, so it also disappears from your other devices. You can restore it from the Trash.")
        }
        if syncedCount >= totalCount {
            return String(localized: "All \(totalCount) files you're trashing sync with iCloud, so they also disappear from your other devices. You can restore them from the Trash.")
        }
        if syncedCount == 1 {
            return String(localized: "1 of the files you're trashing syncs with iCloud, so it also disappears from your other devices. You can restore it from the Trash.")
        }
        return String(localized: "\(syncedCount) of the files you're trashing sync with iCloud, so they also disappear from your other devices. You can restore them from the Trash.")
    }

    var displayName: String { displayNameOverride ?? path.lastPathComponent }
    var formattedSize: String { formatBytes(sizeBytes) }
    var locationLabel: String {
        if let sourceLabel { return sourceLabel }
        let folder = path.deletingLastPathComponent()
        return Self.iCloudDriveLocation(for: folder) ?? displayDirectoryPath(for: folder)
    }

    /// "iCloud Drive/Projects" for a folder inside iCloud Drive's own folder,
    /// which Finder shows as iCloud Drive. Nil anywhere else.
    static func iCloudDriveLocation(
        for folder: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let root = LargeFileScanPolicy.iCloudDriveRoot(home: home).standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        if path == root { return String(localized: "iCloud Drive") }
        guard path.hasPrefix(root + "/") else { return nil }
        return String(localized: "iCloud Drive") + "/" + path.dropFirst(root.count + 1)
    }
}

/// The chip filter over the Large Files list, shared by `LargeFilesView` (which
/// draws the list) and `ContentView` (which draws the "N files · X GB to review"
/// page header outside it). Both must narrow the rows identically or the header
/// advertises a different list than the one on screen — a drift that has already
/// happened once and is exactly what this type exists to prevent.
///
/// Duplicates is a pseudo-category rather than a `LargeFileCategory` case: a
/// duplicate cuts across every category, and reusing the one persisted filter key
/// keeps the chips single-select without a second piece of state.
nonisolated enum LargeFileCategoryFilter {
    static let all = "all"
    static let duplicates = "duplicates"

    static func includes(_ file: LargeFile, rawValue: String, duplicates index: DuplicateIndex) -> Bool {
        switch rawValue {
        case all:
            return true
        case Self.duplicates:
            // The filter persists across launches, so a stored "duplicates" can
            // outlive the scan that produced the groups. Falling back to "all"
            // beats relaunching into a permanently empty list.
            guard !index.isEmpty else { return true }
            return index.groupIDByFileID[file.id] != nil
        default:
            return file.category.rawValue == rawValue
        }
    }

    static func isDuplicatesActive(rawValue: String, duplicates index: DuplicateIndex) -> Bool {
        rawValue == duplicates && !index.isEmpty
    }

    /// One duplicate group's rows, as indices into the array they came from.
    struct Section {
        let groupID: String
        let group: DuplicateGroup
        let memberIndices: [Int]

        /// What the card actually renders. Derived from `memberIndices` rather
        /// than `group.copyCount` so the header can never claim more copies than
        /// there are rows beneath it — the two come apart if a row leaves the list
        /// before the index is pruned.
        var displayedCopyCount: Int { memberIndices.count }

        /// How many copies here are *removable* — every rendered copy but the one
        /// worth keeping. This is what the Duplicates chip counts: counting all
        /// copies would include the keeper and overstate the redundancy, the same
        /// way `group.reclaimableBytes` excludes one copy from the space it
        /// promises. Derived from the rendered rows so it can never exceed them.
        var displayedReclaimableCount: Int { max(displayedCopyCount - 1, 0) }

        /// Space freed by keeping one of the rendered copies. Ordering the list
        /// reads this rather than `group.reclaimableBytes` for the same reason:
        /// groups must sort by the number the header shows.
        var displayedReclaimableBytes: Int64 {
            Int64(max(displayedCopyCount - 1, 0)) * group.sizeBytes
        }
    }

    /// The duplicate groups the list should draw, ordered most-reclaimable first,
    /// members in path order.
    ///
    /// A search query is matched against the *group*, not each copy: the point of
    /// a group is to show every copy of a thing at once, and a box that hid one of
    /// them because its filename didn't contain the query would misrepresent what
    /// is on disk. Searching "wedding" surfaces the whole set even if one copy is
    /// called `IMG_4021.mov`.
    static func duplicateSections(
        in files: [LargeFile],
        query: String,
        duplicates index: DuplicateIndex
    ) -> [Section] {
        guard !index.isEmpty else { return [] }

        var indicesByFileID: [String: Int] = [:]
        indicesByFileID.reserveCapacity(files.count)
        for i in files.indices where index.groupIDByFileID[files[i].id] != nil {
            indicesByFileID[files[i].id] = i
        }

        return index.groups.compactMap { group in
            let members = group.fileIDs.compactMap { indicesByFileID[$0] }
            // A group whose copies have since been deleted is no longer a group.
            guard members.count > 1 else { return nil }
            guard members.contains(where: { files[$0].matches(searchQuery: query) }) else { return nil }
            return Section(groupID: group.id, group: group, memberIndices: members)
        }
    }

    /// Indices of the rows the list shows. Ordered when the Duplicates filter is
    /// active (copies laid out group by group); source order otherwise, leaving
    /// the caller's sort menu to arrange them.
    ///
    /// Shared by `LargeFilesView` and by the page header `ContentView` draws
    /// outside it, so the two cannot disagree about what is on screen.
    static func visibleIndices(
        in files: [LargeFile],
        rawValue: String,
        query: String,
        duplicates index: DuplicateIndex
    ) -> [Int] {
        if isDuplicatesActive(rawValue: rawValue, duplicates: index) {
            return duplicateSections(in: files, query: query, duplicates: index)
                .flatMap(\.memberIndices)
        }
        return files.indices.filter { i in
            includes(files[i], rawValue: rawValue, duplicates: index)
                && files[i].matches(searchQuery: query)
        }
    }
}

enum LargeFileSizeThreshold: Int, CaseIterable, Identifiable {
    case mb5 = 5
    case mb50 = 50
    case mb100 = 100
    case mb250 = 250
    case mb500 = 500
    case gb1 = 1024

    static let userDefaultsKey = "filter.largeFiles.size"
    static let defaultOption: LargeFileSizeThreshold = .mb100

    var id: Int { rawValue }
    var bytes: Int64 { Int64(rawValue) * 1024 * 1024 }

    var label: String {
        switch self {
        case .mb5: return String(localized: "5 MB")
        case .mb50: return String(localized: "50 MB")
        case .mb100: return String(localized: "100 MB")
        case .mb250: return String(localized: "250 MB")
        case .mb500: return String(localized: "500 MB")
        case .gb1: return String(localized: "1 GB")
        }
    }

    var menuButtonLabel: String {
        String(localized: "Larger than \(label)")
    }

    static func current(userDefaults: UserDefaults = .standard) -> LargeFileSizeThreshold {
        LargeFileSizeThreshold(rawValue: userDefaults.integer(forKey: userDefaultsKey)) ?? defaultOption
    }
}

enum LargeFileAgeThreshold: Int, CaseIterable, Identifiable {
    case anyTime = 0
    case oneMonth = 30
    case months3 = 90
    case months6 = 180
    case year1 = 365

    static let userDefaultsKey = "filter.largeFiles.lastUsed"
    static let defaultOption: LargeFileAgeThreshold = .anyTime

    var id: Int { rawValue }
    var days: Int { rawValue }

    var label: String {
        switch self {
        case .anyTime: return String(localized: "Any time")
        case .oneMonth: return String(localized: "Over 1 month ago")
        case .months3: return String(localized: "Over 3 months ago")
        case .months6: return String(localized: "Over 6 months ago")
        case .year1: return String(localized: "Over 1 year ago")
        }
    }

    var menuButtonLabel: String {
        String(localized: "Last used: \(label)")
    }

    static func current(userDefaults: UserDefaults = .standard) -> LargeFileAgeThreshold {
        LargeFileAgeThreshold(rawValue: userDefaults.integer(forKey: userDefaultsKey)) ?? defaultOption
    }

    nonisolated static func currentThresholdDays(userDefaults: UserDefaults = .standard) -> Int {
        let raw = userDefaults.integer(forKey: userDefaultsKey)
        if raw == anyTime.rawValue {
            return anyTime.rawValue
        }
        return LargeFileAgeThreshold(rawValue: raw)?.rawValue ?? defaultOption.rawValue
    }
}

enum LargeFileFilterDefaults {
    private static let legacySizeKey = "largeFiles.minSizeMB"
    static let categoryKey = "filter.largeFiles"

    static func register(userDefaults: UserDefaults = .standard) {
        // Duplicates is a way of looking at a scan, not a standing preference:
        // it only means anything once a scan has found groups, and landing in it
        // on launch shows an empty list until one has. The category chips share
        // this key, so the persisted value is dropped back to "all" here rather
        // than being written differently at the tap site.
        if userDefaults.string(forKey: categoryKey) == LargeFileCategoryFilter.duplicates {
            userDefaults.set(LargeFileCategoryFilter.all, forKey: categoryKey)
        }

        if userDefaults.object(forKey: LargeFileSizeThreshold.userDefaultsKey) == nil,
           userDefaults.object(forKey: legacySizeKey) != nil {
            let legacySize = userDefaults.integer(forKey: legacySizeKey)
            if LargeFileSizeThreshold(rawValue: legacySize) != nil {
                userDefaults.set(legacySize, forKey: LargeFileSizeThreshold.userDefaultsKey)
            }
        }

        userDefaults.register(defaults: [
            LargeFileSizeThreshold.userDefaultsKey: LargeFileSizeThreshold.defaultOption.rawValue,
            LargeFileAgeThreshold.userDefaultsKey: LargeFileAgeThreshold.defaultOption.rawValue,
        ])
    }
}

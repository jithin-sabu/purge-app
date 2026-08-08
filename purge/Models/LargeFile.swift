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
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video: return "Videos"
        case .audio: return "Audio"
        case .image: return "Images"
        case .pdf: return "PDFs"
        case .archive: return "Archives"
        case .document: return "Documents"
        case .aiModel: return "AI Models"
        case .other: return "Other"
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
        case "zip", "rar", "7z", "tar", "gz", "bz2", "dmg", "pkg", "iso", "xip":
            return .archive
        case "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "txt", "rtf", "csv", "epub":
            return .document
        default:
            return .other
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

    /// Stored (not computed) so identity checks in row bindings, sorting, and list
    /// animations don't re-standardize the URL on every access — the repeated cost
    /// made selection feel delayed compared to App Caches.
    let id: String

    /// Everything a search query is matched against, joined once at init for the
    /// same reason `id` is stored: it's read for every row on every keystroke, so
    /// rebuilding it per access would re-walk the URL hundreds of times a character.
    ///
    /// Holds the display name, the raw parent path, and the `sourceLabel` when there
    /// is one — so a query finds a row by what it's called *or* where it lives. The
    /// last two differ for labelled rows: an Ollama model shows "Ollama" but sits in
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
        componentPaths: [URL]? = nil
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.lastUsed = lastUsed
        self.category = category
        self.isSelected = isSelected
        self.displayNameOverride = displayNameOverride
        self.sourceLabel = sourceLabel
        self.componentPaths = (componentPaths ?? [path]).map(\.standardizedFileURL)
        let standardized = path.standardizedFileURL
        self.id = standardized.path
        self.searchHaystack = [
            displayNameOverride ?? path.lastPathComponent,
            standardized.deletingLastPathComponent().path,
            sourceLabel,
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

    var displayName: String { displayNameOverride ?? path.lastPathComponent }
    var formattedSize: String { formatBytes(sizeBytes) }
    var locationLabel: String {
        sourceLabel ?? displayDirectoryPath(for: path.deletingLastPathComponent())
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
        case .mb5: return "5 MB"
        case .mb50: return "50 MB"
        case .mb100: return "100 MB"
        case .mb250: return "250 MB"
        case .mb500: return "500 MB"
        case .gb1: return "1 GB"
        }
    }

    var menuButtonLabel: String {
        "Larger than \(label)"
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
        case .anyTime: return "Any time"
        case .oneMonth: return "Over 1 month ago"
        case .months3: return "Over 3 months ago"
        case .months6: return "Over 6 months ago"
        case .year1: return "Over 1 year ago"
        }
    }

    var menuButtonLabel: String {
        "Last used: \(label)"
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

    static func register(userDefaults: UserDefaults = .standard) {
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

import Foundation
import SwiftUI

enum LargeFileCategory: String, CaseIterable, Identifiable, Hashable {
    case video
    case audio
    case image
    case pdf
    case archive
    case document
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

struct LargeFile: Identifiable, Hashable {
    let path: URL
    let sizeBytes: Int64
    /// Most recent of last-accessed and last-modified. The file's last touched time.
    let lastUsed: Date
    let category: LargeFileCategory
    var isSelected: Bool = false

    /// Stored (not computed) so identity checks in row bindings, sorting, and list
    /// animations don't re-standardize the URL on every access — the repeated cost
    /// made selection feel delayed compared to App Caches.
    let id: String

    init(
        path: URL,
        sizeBytes: Int64,
        lastUsed: Date,
        category: LargeFileCategory,
        isSelected: Bool = false
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.lastUsed = lastUsed
        self.category = category
        self.isSelected = isSelected
        self.id = path.standardizedFileURL.path
    }
    var displayName: String { path.lastPathComponent }
    var formattedSize: String { formatBytes(sizeBytes) }
    var locationLabel: String { displayDirectoryPath(for: path.deletingLastPathComponent()) }
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

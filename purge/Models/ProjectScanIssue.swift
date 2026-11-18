import Foundation

nonisolated struct ProjectScanIssue: Identifiable, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case unavailable(AppFolders.Refusal)
        case excluded
        case unreadable
        case depthLimit(Int)
        case entryLimit(Int)
    }

    let path: String
    let reason: Reason
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    var explanation: String {
        switch reason {
        case .unavailable(.notAFolder):
            return String(localized: "This folder is missing or its drive is disconnected.")
        case .unavailable(.throughLink):
            return String(localized: "This saved folder now points through a symbolic link.")
        case .unavailable(.outsideHomeAndDrives), .unavailable(.tooBroad), .unavailable(.insideLibraryOrBundle),
             .unavailable(.notOnWritableLocalDisk), .unavailable(.holdsWholeDisk), .unavailable(.syncs),
             .unavailable(.alreadyIncluded), .unavailable(.holdsAnotherFolder):
            return String(localized: "This folder can no longer be used as a scan location. Review it in Settings.")
        case .excluded:
            return String(localized: "This folder is excluded from scans.")
        case .unreadable:
            return String(localized: "This folder couldn't be read. Check its access permissions in Finder.")
        case .depthLimit(let depth):
            return String(localized: "Reached the scan limit of \(depth) folder levels.")
        case .entryLimit(let count):
            return String(localized: "Skipped subfolders because this folder has more than \(count) entries.")
        }
    }
}

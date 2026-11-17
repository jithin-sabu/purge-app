import Foundation

nonisolated struct HiddenLargeFile: Codable, Sendable, Identifiable {
    let path: String
    let displayName: String
    let sizeBytes: Int64
    var id: String { path }
}

enum HiddenLargeFilesStore {
    nonisolated private static let store = JSONPathStore<HiddenLargeFile>(fileName: "hidden_large_files.json")

    nonisolated static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated static func all() -> [HiddenLargeFile] {
        store.read { $0.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending } }
    }

    nonisolated static func contains(_ url: URL) -> Bool {
        store.read { $0[key(url)] != nil }
    }

    @discardableResult nonisolated static func add(_ files: [LargeFile]) -> Bool {
        store.update { entries in
            for file in files {
                let path = key(file.path)
                entries[path] = HiddenLargeFile(path: path, displayName: file.displayName, sizeBytes: file.sizeBytes)
            }
            return !files.isEmpty
        }
    }

    @discardableResult nonisolated static func remove(_ paths: Set<String>) -> Bool {
        store.update { entries in
            for path in paths { entries.removeValue(forKey: path) }
            return !paths.isEmpty
        }
    }
}

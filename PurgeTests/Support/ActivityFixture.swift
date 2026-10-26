import Foundation

/// Rooted under the real home directory: the git lookup stops at home, and
/// `collectArtifacts` refuses anything outside it. Removed again in `cleanUp`.
struct ActivityFixture {
    static let container = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".purge-test-fixtures", isDirectory: true)

    let root: URL

    init(files: [String] = [], folders: [String] = []) throws {
        root = Self.container.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.makeRoot(root)
        for folder in folders {
            try FileManager.default.createDirectory(at: url(folder), withIntermediateDirectories: true)
        }
        for file in files {
            try write("", to: file)
        }
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    func write(_ text: String, to relative: String) throws {
        let file = url(relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: file)
    }

    func setDate(_ date: Date, of relative: String) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url(relative).path)
    }

    /// Every entry, deepest first so a parent's date is set after its children
    /// stop touching it. Links are skipped: setting their date would date the target.
    func ageEverything(to date: Date) throws {
        let fm = FileManager.default
        var paths: [String] = []
        if let enumerator = fm.enumerator(atPath: root.path) {
            for case let relative as String in enumerator { paths.append(relative) }
        }
        for relative in paths.sorted(by: { $0.count > $1.count }) {
            let attributes = try fm.attributesOfItem(atPath: url(relative).path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { continue }
            try setDate(date, of: relative)
        }
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: root.path)
    }

    /// Another suite's `cleanUp` can remove the empty container between the
    /// container being made and `root` being made inside it, so that is tried again.
    private static func makeRoot(_ root: URL) throws {
        for attempt in 1...5 {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                return
            } catch where attempt < 5 {
                continue
            }
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        // Shared with other suites running in parallel, so only removed when empty.
        // rmdir checks and removes in one step. Listing it first and then removing
        // it whole took a fixture another suite made between the two, and failed
        // that suite's test on CI.
        rmdir(Self.container.path)
    }
}

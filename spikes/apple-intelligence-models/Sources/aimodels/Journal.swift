import Foundation

/// Every run appends one record here, so the test plan's readings (before,
/// after, after a restart, after a day online, after Download again) line up in
/// one file. Plain JSON, never rewritten in place: a damaged file is moved aside.
enum Journal {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Purge/spikes")
    static let file = folder.appendingPathComponent("apple-intelligence-models.json")

    static func load() -> [[String: Any]] {
        guard let data = FileManager.default.contents(atPath: file.path) else { return [] }
        if let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return entries }
        let aside = folder.appendingPathComponent("apple-intelligence-models-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: file, to: aside)
        Log.warn("the journal could not be read and was kept as \(aside.path)")
        return []
    }

    @discardableResult
    static func record(_ command: String, note: String?, fields: [String: Any]) -> [String: Any] {
        var entry: [String: Any] = [
            "date": Format.iso.string(from: Date()),
            "command": command,
            "macOS": MacOS.label,
            "architecture": MacOS.architecture,
        ]
        if let note { entry["note"] = note }
        if let free = Volume.freeBytes() { entry["freeBytes"] = free }
        for (key, value) in fields { entry[key] = Format.jsonSafe(value) }
        var entries = load()
        entries.append(entry)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
        } catch {
            Log.warn("could not write the journal at \(file.path): \(error.localizedDescription)")
        }
        return entry
    }
}

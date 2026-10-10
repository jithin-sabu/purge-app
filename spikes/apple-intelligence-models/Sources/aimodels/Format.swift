import Foundation

enum Format {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: value)
    }

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "unknown" }
        return bytes(value)
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func json(_ value: Any, pretty: Bool = true) -> String {
        let safe = jsonSafe(value)
        guard JSONSerialization.isValidJSONObject(safe),
              let data = try? JSONSerialization.data(
                withJSONObject: safe, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return text
    }

    /// Turns anything a plist or a private reply can hold into JSON-safe values,
    /// so a raw dictionary can be printed and recorded without losing a key.
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            var out: [String: Any] = [:]
            for (key, inner) in dictionary { out[key] = jsonSafe(inner) }
            return out
        case let dictionary as NSDictionary:
            var out: [String: Any] = [:]
            for (key, inner) in dictionary { out[String(describing: key)] = jsonSafe(inner) }
            return out
        case let array as [Any]:
            return array.map(jsonSafe)
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case let date as Date:
            return iso.string(from: date)
        case let data as Data:
            return "<\(data.count) bytes>"
        case let url as URL:
            return url.absoluteString
        case is NSNull:
            return NSNull()
        default:
            return String(describing: value)
        }
    }
}

enum Log {
    static func line(_ text: String = "") {
        print(text)
        fflush(stdout)
    }

    static func warn(_ text: String) {
        line("  ! " + text)
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data(("error: " + text + "\n").utf8))
    }

    static func fail(_ text: String) -> Never {
        error(text)
        exit(1)
    }
}

/// Arguments after the subcommand. Flags are removed as they are read, so what
/// is left over is unknown and reported.
struct Arguments {
    private(set) var rest: [String]

    init(_ arguments: [String]) { rest = arguments }

    mutating func flag(_ name: String) -> Bool {
        guard let index = rest.firstIndex(of: name) else { return false }
        rest.remove(at: index)
        return true
    }

    mutating func option(_ name: String) -> String? {
        guard let index = rest.firstIndex(of: name) else { return nil }
        guard index + 1 < rest.count else { Log.fail("\(name) needs a value") }
        let value = rest[index + 1]
        rest.removeSubrange(index...(index + 1))
        return value
    }

    func rejectUnknown() {
        if let extra = rest.first { Log.fail("unknown argument \(extra)") }
    }
}

enum MacOS {
    static let version = ProcessInfo.processInfo.operatingSystemVersion
    static var major: Int { version.majorVersion }
    static var label: String { "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)" }

    /// macOS 27 has no Apple Intelligence switch (press reports; open question
    /// in the issue), so the models are released through the asset service.
    /// macOS 15 and 26 keep Apple's own switch, which is the release step there.
    static var releasesThroughService: Bool { major >= 27 }

    static var architecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }
}

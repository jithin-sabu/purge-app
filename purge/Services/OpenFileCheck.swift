import Darwin
import Foundation

/// Whether any of the user's processes has a file open, a working folder, or
/// its program inside a folder Purge is about to remove (#225). A tool still
/// running from `~/.hermes` would lose its files under it, so the removal is
/// refused until it quits.
///
/// One `lsof -u <uid>` lists every open file of the user in about 0.1 s,
/// where `lsof +D` would walk a 4 GB folder. When the listing cannot be read
/// the answer is `.unavailable`, which refuses the removal too: an empty
/// answer is not proof that nothing is open.
nonisolated enum OpenFileCheck {
    nonisolated struct Holder: Equatable, Sendable {
        let pid: Int32
        let command: String
    }

    nonisolated enum Result: Equatable, Sendable {
        case free
        case inUse([Holder])
        case unavailable
    }

    /// Returns `lsof -F pcn` output, or nil when it could not be read.
    typealias Lister = @Sendable () -> String?

    static func check(folders: [URL], lister: Lister = liveListing) -> Result {
        guard let listing = lister() else { return .unavailable }
        let prefixes = Set(folders.flatMap(spellings))
        let found = holders(in: listing, folders: prefixes)
        return found.isEmpty ? .free : .inUse(found)
    }

    /// The ways lsof may spell a folder. It reports the real path, such as
    /// `/private/var/…`, which `resolvingSymlinksInPath` shortens to `/var/…`,
    /// so `realpath(3)` supplies that one.
    static func spellings(of folder: URL) -> [String] {
        var result = [folder.standardizedFileURL.path, folder.standardizedFileURL.resolvingSymlinksInPath().path]
        if let resolved = realpath(folder.path, nil) {
            result.append(String(cString: resolved))
            free(resolved)
        }
        return result
    }

    /// The processes in an `lsof -F pcn` listing with any name equal to or
    /// inside one of `folders`, each once, in listing order.
    static func holders(in listing: String, folders: Set<String>) -> [Holder] {
        var result: [Holder] = []
        var pid: Int32?
        var command = ""
        var counted = false
        for line in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value)
                command = ""
                counted = false
            case "c":
                command = value
            case "n":
                guard let pid, !counted else { continue }
                if folders.contains(where: { value == $0 || value.hasPrefix($0 + "/") }) {
                    result.append(Holder(pid: pid, command: command))
                    counted = true
                }
            default:
                continue
            }
        }
        return result
    }

    static let liveListing: Lister = {
        guard let output = ProcessRunner.run(
            executablePath: "/usr/sbin/lsof",
            arguments: ["-n", "-P", "-w", "-F", "pcn", "-u", String(getuid())],
            timeout: 15
        ), output.succeeded, !output.stdout.isEmpty else { return nil }
        return output.stdoutText
    }
}

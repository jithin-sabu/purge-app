import Foundation

/// An npm version range, as `engines.node`, `devEngines.runtime`, `.node-version`
/// and `.nvmrc` write one (#398). Only release versions count: a range or a
/// version with a pre-release or build tag (`-rc.1`, `+sha`) is not read.
///
/// It reads what npm's `semver` reads for releases: exact versions with or
/// without a `v`, x-ranges (`22`, `22.x`, `22.1`, `*`), `^`, `~`, `>=`, `>`,
/// `<=`, `<`, `=`, hyphen ranges (`20 - 22`), comparators joined by spaces, and
/// `||`. Anything else is nil, so a caller that can't read a pin keeps every
/// version.
nonisolated struct NodeVersionRange: Equatable, Sendable {

    nonisolated struct Version: Comparable, Hashable, Sendable {
        var major: Int
        var minor: Int
        var patch: Int

        static func < (a: Version, b: Version) -> Bool {
            (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }

        /// `22.14.0` or `v22.14.0`. Nil for anything else, a partial version included.
        init?(_ text: String) {
            guard let partial = Partial(text), let major = partial.major,
                  let minor = partial.minor, let patch = partial.patch else { return nil }
            self.init(major: major, minor: minor, patch: patch)
        }

        init(major: Int, minor: Int, patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }
    }

    /// Bounds that must all hold, one set for each side of `||`.
    private let alternatives: [[Bound]]

    private nonisolated enum Bound: Equatable, Sendable {
        case atLeast(Version)
        case above(Version)
        case below(Version)
        case atMost(Version)
        /// Nothing matches, as for `<0.0.0` or `>*`.
        case never

        func admits(_ version: Version) -> Bool {
            switch self {
            case .atLeast(let bound): return version >= bound
            case .above(let bound): return version > bound
            case .below(let bound): return version < bound
            case .atMost(let bound): return version <= bound
            case .never: return false
            }
        }
    }

    /// `22`, `22.x`, `22.1.3`, `*`: each part a number or a wildcard, and every
    /// part after a wildcard a wildcard too.
    private nonisolated struct Partial: Sendable {
        var major: Int?
        var minor: Int?
        var patch: Int?

        init?(_ text: String) {
            var value = Substring(text)
            if value.hasPrefix("v") || value.hasPrefix("=") { value = value.dropFirst() }
            guard !value.isEmpty else { return nil }
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 3 else { return nil }
            var numbers: [Int?] = []
            var sawWildcard = false
            for part in parts {
                if part == "x" || part == "X" || part == "*" {
                    sawWildcard = true
                    numbers.append(nil)
                    continue
                }
                guard !sawWildcard, !part.isEmpty, part.count <= 9,
                      part.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let number = Int(part) else { return nil }
                numbers.append(number)
            }
            while numbers.count < 3 { numbers.append(nil) }
            major = numbers[0]
            minor = numbers[1]
            patch = numbers[2]
        }

        /// The lowest version the partial covers.
        var floor: Version { Version(major: major ?? 0, minor: minor ?? 0, patch: patch ?? 0) }

        /// The first version past what the partial covers. Nil for `*`, and for
        /// a full version, which covers only itself.
        var ceiling: Version? {
            guard let major else { return nil }
            guard let minor else { return Version(major: major + 1, minor: 0, patch: 0) }
            guard patch != nil else { return Version(major: major, minor: minor + 1, patch: 0) }
            return nil
        }

        var isFull: Bool { patch != nil }
    }

    /// Nil when `text` is not a range Purge reads.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        var alternatives: [[Bound]] = []
        for alternative in trimmed.components(separatedBy: "||") {
            guard let bounds = Self.bounds(of: alternative.trimmingCharacters(in: .whitespaces)) else { return nil }
            alternatives.append(bounds)
        }
        guard !alternatives.isEmpty else { return nil }
        self.alternatives = alternatives
    }

    func contains(_ version: Version) -> Bool {
        alternatives.contains { bounds in bounds.allSatisfy { $0.admits(version) } }
    }

    /// The newest of `versions` the range takes, as `vp` picks an installed
    /// version for a project. Names that aren't release versions are skipped.
    func newestMatch(in versions: [String]) -> String? {
        versions
            .compactMap { name in Version(name).map { (name, $0) } }
            .filter { contains($0.1) }
            .max { $0.1 < $1.1 }?
            .0
    }

    // MARK: Parsing

    private static let operators = [">=", "<=", "~>", ">", "<", "=", "~", "^"]

    private static func bounds(of range: String) -> [Bound]? {
        if range.isEmpty { return [] }
        let words = range.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // `1.2 - 2.3`: a hyphen with spaces around it between two versions.
        if words.count == 3, words[1] == "-" {
            guard let low = Partial(words[0]), let high = Partial(words[2]) else { return nil }
            var bounds: [Bound] = [.atLeast(low.floor)]
            if high.isFull {
                bounds.append(.atMost(high.floor))
            } else if let ceiling = high.ceiling {
                bounds.append(.below(ceiling))
            }
            return bounds
        }
        // `>= 1.2` may put a space after the operator. Join it to its version.
        var comparators: [String] = []
        var pending = ""
        for word in words {
            if operators.contains(word) {
                guard pending.isEmpty else { return nil }
                pending = word
            } else {
                comparators.append(pending + word)
                pending = ""
            }
        }
        guard pending.isEmpty else { return nil }
        var bounds: [Bound] = []
        for comparator in comparators {
            guard let more = comparatorBounds(comparator) else { return nil }
            bounds += more
        }
        return bounds
    }

    private static func comparatorBounds(_ text: String) -> [Bound]? {
        let op = operators.first { text.hasPrefix($0) } ?? ""
        let rest = String(text.dropFirst(op.count))
        // `~>` is an old spelling of `~`. `=` is no operator for an x-range.
        guard !rest.isEmpty, !rest.hasPrefix(">"), !rest.hasPrefix("<"),
              let partial = Partial(rest) else { return nil }
        let floor = partial.floor
        switch op {
        case "", "=":
            guard partial.major != nil else { return [] }
            if partial.isFull { return [.atLeast(floor), .atMost(floor)] }
            return [.atLeast(floor)] + (partial.ceiling.map { [.below($0)] } ?? [])
        case "~", "~>":
            guard let major = partial.major else { return [] }
            guard partial.minor != nil else { return [.atLeast(floor), .below(Version(major: major + 1, minor: 0, patch: 0))] }
            return [.atLeast(floor), .below(Version(major: major, minor: floor.minor + 1, patch: 0))]
        case "^":
            guard let major = partial.major else { return [] }
            if major > 0 || partial.minor == nil {
                return [.atLeast(floor), .below(Version(major: major + 1, minor: 0, patch: 0))]
            }
            if floor.minor > 0 || partial.patch == nil {
                return [.atLeast(floor), .below(Version(major: 0, minor: floor.minor + 1, patch: 0))]
            }
            return [.atLeast(floor), .below(Version(major: 0, minor: 0, patch: floor.patch + 1))]
        case ">":
            guard partial.major != nil else { return [.never] }
            if partial.isFull { return [.above(floor)] }
            return partial.ceiling.map { [.atLeast($0)] } ?? [.never]
        case ">=":
            return [.atLeast(floor)]
        case "<":
            guard partial.major != nil else { return [.never] }
            return [.below(floor)]
        case "<=":
            guard partial.major != nil else { return [] }
            if partial.isFull { return [.atMost(floor)] }
            return partial.ceiling.map { [.below($0)] } ?? []
        default:
            return nil
        }
    }
}

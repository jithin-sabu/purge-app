import Darwin
import Foundation

/// Old Android build-tools and SDK platform versions (#467). The SDK Manager
/// installs a new `build-tools/<version>` or `platforms/android-<level>` next
/// to the old ones and never removes them.
///
/// Every row is Check First, one per version, like the NDK rows in
/// `OldToolVersionScanPolicy`. A version is offered only when all of these hold:
/// - it is a finished install (`OldToolVersionScanPolicy.isCompleteSDKPackage`);
/// - a finished version above it is in the same folder, so the newest finished
///   one stays, and so does anything newer;
/// - no Gradle build file a Dev Projects walk recorded names it, through
///   `compileSdk` for a platform or `buildToolsVersion` for build-tools
///   (`AndroidGradlePins`). Nothing is offered until a walk with Full Disk
///   Access has saved the list, and a value Purge can't read keeps every
///   version of its kind;
/// - for build-tools, no link in a `bin` folder points into it, the way
///   people put `apksigner` or `zipalign` on their path;
/// - right before the move, `lsof` shows nothing open inside it.
///
/// A project that names no `buildToolsVersion` uses the Android Gradle plugin's
/// own default, which Purge can't know. The next Gradle build downloads it
/// again, and the explanation says so.
nonisolated enum AndroidSDKVersionPolicy {

    nonisolated enum Folder: Equatable, Sendable {
        /// `~/Library/Android/sdk/build-tools/<version>`.
        case buildTools
        /// `~/Library/Android/sdk/platforms/android-<level>`.
        case platform
    }

    // MARK: Rows

    /// One row per version, labelled `Android SDK Build-Tools <version>`, the
    /// name Android Studio's SDK Manager uses.
    static let buildToolsLabelPrefix = "Android SDK Build-Tools "
    /// One row per platform, labelled `Android SDK Platform <level>`.
    static let platformLabelPrefix = "Android SDK Platform "

    static let buildToolsExplanationKey = "android-build-tools-version"
    static let platformExplanationKey = "android-sdk-platform"

    /// The version in a build-tools row's label, or nil for any other label.
    static func buildToolsVersion(inLabel label: String) -> String? {
        guard label.hasPrefix(buildToolsLabelPrefix) else { return nil }
        let version = String(label.dropFirst(buildToolsLabelPrefix.count))
        return OldToolVersionScanPolicy.isDottedVersion(version) ? version : nil
    }

    /// The API level in a platform row's label, or nil for any other label.
    static func platformLevel(inLabel label: String) -> String? {
        guard label.hasPrefix(platformLabelPrefix) else { return nil }
        let level = String(label.dropFirst(platformLabelPrefix.count))
        return isLevel(level) ? level : nil
    }

    // MARK: Places

    static let buildToolsFolder = "build-tools"
    static let platformsFolder = "platforms"

    static func sdkRoot(home: String) -> String {
        "\(home)/\(OldToolVersionScanPolicy.androidSDK)"
    }

    // MARK: Shape

    /// `android-34` → 34. Nil for an extension SDK (`android-34-ext10`), a
    /// minor level (`android-36.1`), a preview (`android-UpsideDownCake`) and
    /// every other name. None of those is ever offered.
    static func platformLevel(ofFolderName name: String) -> Int? {
        guard name.hasPrefix("android-") else { return nil }
        let digits = String(name.dropFirst("android-".count))
        guard isLevel(digits) else { return nil }
        return Int(digits)
    }

    /// One to four ASCII digits, not starting with 0.
    static func isLevel(_ text: String) -> Bool {
        guard let first = text.first, first != "0", (1...4).contains(text.count) else { return false }
        return text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// What `path` is by its place and name alone. Nil for everything else,
    /// including the folders that hold these entries and anything inside one.
    static func folder(of path: String, home: String) -> Folder? {
        let sdk = sdkRoot(home: home)
        if let name = OldToolVersionScanPolicy.onlyChild(path, of: "\(sdk)/\(buildToolsFolder)"),
           OldToolVersionScanPolicy.isDottedVersion(name) {
            return .buildTools
        }
        if let name = OldToolVersionScanPolicy.onlyChild(path, of: "\(sdk)/\(platformsFolder)"),
           platformLevel(ofFolderName: name) != nil {
            return .platform
        }
        return nil
    }

    /// Whether `name` is lower than `other`, both of the same folder's shape.
    static func isLower(_ name: String, than other: String, in folder: Folder) -> Bool {
        switch folder {
        case .buildTools:
            return OldToolVersionScanPolicy.isLower(name, than: other)
        case .platform:
            guard let level = platformLevel(ofFolderName: name),
                  let otherLevel = platformLevel(ofFolderName: other) else { return false }
            return level < otherLevel
        }
    }

    /// Whether a folder name has the shape this folder offers.
    static func hasShape(_ name: String, in folder: Folder) -> Bool {
        switch folder {
        case .buildTools: return OldToolVersionScanPolicy.isDottedVersion(name)
        case .platform: return platformLevel(ofFolderName: name) != nil
        }
    }

    /// The highest finished install in `root`. It is kept, and so is any
    /// version above it, finished or not. Nil when the folder can't be listed
    /// or holds no finished install.
    static func newestComplete(in root: String, folder: Folder) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        return names
            .filter { hasShape($0, in: folder) && OldToolVersionScanPolicy.isCompleteSDKPackage("\(root)/\($0)") }
            .max { isLower($0, than: $1, in: folder) }
    }

    // MARK: Context

    nonisolated struct Context: Sendable {
        /// The Gradle build files Dev Projects walks recorded, there or not, or
        /// nil before a walk with Full Disk Access saved them.
        var gradleFiles: @Sendable () -> [String]?
        /// Whether a file may be read without a macOS prompt. Tests allow everything.
        var mayRead: @Sendable (_ path: String) -> Bool
        /// The `lsof` listing, read only right before a move.
        var openFiles: OpenFileCheck.Lister
        /// The `bin` folders searched for links into a build-tools version. Tests use their own.
        var linkFolders: [String] = NvmNodeVersionPolicy.linkFolders

        /// `access` is worked out once here, not for each file: it probes Full
        /// Disk Access by opening folders.
        static func current(home: String, access: ScanAccess = ScanAccess.current()) -> Context {
            let homeURL = URL(fileURLWithPath: home, isDirectory: true)
            return Context(
                gradleFiles: { AndroidSDKVersionPolicy.ledger.files() },
                mayRead: { path in
                    ProtectedLocations.isReadable(URL(fileURLWithPath: path), access: access, home: homeURL)
                },
                openFiles: OpenFileCheck.liveListing
            )
        }
    }

    /// The Gradle build files recorded by Dev Projects walks.
    static let ledger = NvmrcLedger(
        fileURL: AppSupportFolder.url().appendingPathComponent("android-gradle-files.json"),
        limit: 10_000
    )

    // MARK: Gate

    /// Whether the version folder at `path` is offered now, judged as far as
    /// `check` goes. `.quick` reads only the SDK folder and the ledger's list,
    /// which it keeps in memory, so it is safe on the main thread. `.scan`
    /// also reads the Gradle files and the `bin` links, and `.move` adds `lsof`.
    ///
    /// `knownPins` is what `AndroidGradlePins.pins` just gave, so a scan reads
    /// the Gradle files once for all its versions, not once for each.
    static func isOffered(
        _ path: String,
        home: String,
        context: Context,
        check: NvmNodeVersionPolicy.Check,
        knownPins: AndroidGradlePins.Pins? = nil
    ) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard let folder = folder(of: path, home: home),
              !PathContainment.containsSymlinkComponent(url, home: home),
              OldToolVersionScanPolicy.isCompleteSDKPackage(path),
              let newest = newestComplete(in: url.deletingLastPathComponent().path, folder: folder),
              isLower(name, than: newest, in: folder),
              let files = context.gradleFiles() else { return false }
        switch check {
        case .quick:
            return true
        case .scan, .move:
            break
        }
        let pins = knownPins ?? AndroidGradlePins.pins(in: files, home: home, mayRead: context.mayRead)
        guard let kept = pins.versions(for: folder), !kept.contains(name) else { return false }
        switch folder {
        case .buildTools:
            guard let linked = NvmNodeVersionPolicy.isLinkedFromBinFolder(
                path, home: home, linkFolders: context.linkFolders, mayRead: context.mayRead
            ), !linked else { return false }
        case .platform:
            break
        }
        switch check {
        case .quick, .scan:
            return true
        case .move:
            return OpenFileCheck.check(folders: [url], lister: context.openFiles) == .free
        }
    }

    /// The version folders a scan offers, as paths, lowest first. The Gradle
    /// files are read once.
    static func offeredFolders(home: String, context: Context) -> (buildTools: [String], platforms: [String]) {
        guard let files = context.gradleFiles() else { return ([], []) }
        let pins = AndroidGradlePins.pins(in: files, home: home, mayRead: context.mayRead)
        func offered(in name: String, _ folder: Folder) -> [String] {
            let root = "\(sdkRoot(home: home))/\(name)"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            return names
                .filter { hasShape($0, in: folder) }
                .sorted { isLower($0, than: $1, in: folder) }
                .map { "\(root)/\($0)" }
                .filter { isOffered($0, home: home, context: context, check: .scan, knownPins: pins) }
        }
        return (offered(in: buildToolsFolder, .buildTools), offered(in: platformsFolder, .platform))
    }

    /// `FileDeleter`'s last check before it moves a version: every rule again,
    /// `lsof` included. True for every other path, which other rules judge.
    static func passesImmediateTrashBoundary(
        _ url: URL,
        home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
        context: Context? = nil
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard folder(of: path, home: home) != nil else { return true }
        return isOffered(path, home: home, context: context ?? .current(home: home), check: .move)
    }

    // MARK: Ledger paths

    static let gradleFileNames = ["build.gradle", "build.gradle.kts"]

    /// The Gradle build files for `roots`, for the ledger. Only Android roots
    /// count. In each, the build files at its top and under `android/` (React
    /// Native and Flutter keep their Gradle build there, and the walk never
    /// enters it), listed whether they are there now or not, so one added after
    /// the scan still counts at the move. Also the build file of each module
    /// folder directly below either of them that has one now, such as `app/`.
    static func gradleFiles(inProjectRoots roots: [(URL, [ProjectType])], mayRead: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for (root, types) in roots where types.contains(.androidGradle) {
            let project = root.standardizedFileURL.path
            for gradleRoot in [project, "\(project)/android"] {
                paths += gradleFileNames.map { "\(gradleRoot)/\($0)" }
                paths += moduleBuildFiles(in: gradleRoot, mayRead: mayRead)
            }
        }
        return paths.filter { seen.insert($0).inserted }
    }

    /// The build files of each non-hidden folder directly in `folder` that has one now.
    private static func moduleBuildFiles(in folder: String, mayRead: (String) -> Bool) -> [String] {
        guard mayRead(folder), let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted().flatMap { name in
            gradleFileNames
                .map { "\(folder)/\(name)/\($0)" }
                .filter { OldToolVersionScanPolicy.isRegularFile($0) }
        }
    }
}

/// What recorded Gradle build files say about Android SDK versions (#467). The
/// app has no Gradle or Kotlin parser, and this is not one. It finds the
/// statements that name a version and reads their values:
///
/// - `compileSdk` / `compileSdkVersion`, and the newer `version = release(36)`,
///   name a platform: `35`, `"35"`, `"android-35"`, or an add-on such as
///   `"Google Inc.:Google APIs:33"`, which needs `android-33`;
/// - `buildToolsVersion` names a build-tools version: `"35.0.0"`.
///
/// A value that is not written out is a reference. Its key is looked up in the
/// project's own files, up to two folders above the build file: the
/// `[versions]` of `gradle/*.versions.toml` for `libs.versions.…`, and for
/// anything else `gradle.properties`, `~/.gradle/gradle.properties`, and
/// `key = value`, `extra["key"] = value` or `set("key", value)` in the build
/// and settings files there. Every value found pins its version. When none is
/// found, or a file can't be read, every version of that kind is kept.
nonisolated enum AndroidGradlePins {

    /// The versions recorded build files name, by folder name. Nil keeps every
    /// version of that kind.
    nonisolated struct Pins: Equatable, Sendable {
        /// `android-35`.
        var platforms: Set<String>?
        /// `35.0.0`.
        var buildTools: Set<String>?

        static let unknown = Pins(platforms: nil, buildTools: nil)

        func versions(for folder: AndroidSDKVersionPolicy.Folder) -> Set<String>? {
            switch folder {
            case .buildTools: return buildTools
            case .platform: return platforms
            }
        }
    }

    /// A value's meaning.
    nonisolated enum Outcome: Equatable, Sendable {
        /// The folder names it needs.
        case pins(Set<String>)
        /// A version Purge never offers, such as a preview platform.
        case ignored
        /// Purge can't tell, which keeps every version of its kind.
        case unknown
    }

    /// A Gradle file bigger than this is not read, and keeps every version.
    static let maximumFileBytes = 1_000_000
    /// How far a reference may lead to another before Purge stops following.
    static let maximumReferenceDepth = 3

    // MARK: Reading

    static func pins(in files: [String], home: String, mayRead: @escaping (String) -> Bool) -> Pins {
        // The patterns are fixed, so they compile. If one ever didn't, no pin could be read.
        guard compileSdkPattern != nil, releasePattern != nil, buildToolsPattern != nil else { return .unknown }
        var result = Pins(platforms: [], buildTools: [])
        var reader = Reader(home: home, mayRead: mayRead)
        for file in files {
            switch reader.read(file) {
            case .absent:
                continue
            case .unknown:
                return .unknown
            case .text(let text):
                let lines = codeLines(text)
                let folder = (file as NSString).deletingLastPathComponent
                for (kind, values) in [(AndroidSDKVersionPolicy.Folder.platform, platformValues(lines)),
                                       (.buildTools, buildToolsValues(lines))] {
                    for value in values {
                        let outcome = evaluate(value, as: kind, near: folder, reader: &reader, depth: 0)
                        result.add(outcome, for: kind)
                    }
                }
            }
            if result == .unknown { return result }
        }
        return result
    }

    /// Reads files once each, with the size cap and `readPinFile`'s rules.
    nonisolated struct Reader {
        let home: String
        let mayRead: (String) -> Bool
        private var cache: [String: NvmNodeVersionPolicy.PinFileRead] = [:]

        init(home: String, mayRead: @escaping (String) -> Bool) {
            self.home = home
            self.mayRead = mayRead
        }

        mutating func read(_ file: String) -> NvmNodeVersionPolicy.PinFileRead {
            if let known = cache[file] { return known }
            let result: NvmNodeVersionPolicy.PinFileRead
            var info = stat()
            // `stat` follows a link, so a linked file's own size counts.
            if mayRead(file), stat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
               info.st_size > AndroidGradlePins.maximumFileBytes {
                result = .unknown
            } else {
                result = NvmNodeVersionPolicy.readPinFile(file, home: home, mayRead: mayRead)
            }
            cache[file] = result
            return result
        }
    }

    // MARK: Statements

    /// The lines of `text` with comments left out: whole-line `//`, `#` and
    /// block comments, and a trailing `//` outside a string.
    static func codeLines(_ text: String) -> [String] {
        var lines: [String] = []
        var inBlock = false
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if inBlock {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...])
                inBlock = false
            }
            while let start = line.range(of: "/*"), !isInsideString(line, at: start.lowerBound) {
                if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) {
                    line = String(line[..<start.lowerBound]) + " " + String(line[end.upperBound...])
                } else {
                    line = String(line[..<start.lowerBound])
                    inBlock = true
                }
            }
            if let slashes = line.range(of: "//"), !isInsideString(line, at: slashes.lowerBound) {
                line = String(line[..<slashes.lowerBound])
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            lines.append(trimmed)
        }
        return lines
    }

    /// Whether `index` sits inside a quoted string on its line.
    static func isInsideString(_ line: String, at index: String.Index) -> Bool {
        var quote: Character?
        for character in line[..<index] {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            }
        }
        return quote != nil
    }

    /// The values given to `compileSdk` / `compileSdkVersion`, and to
    /// `version = release(…)`.
    static func platformValues(_ lines: [String]) -> [String] {
        lines.flatMap { values(of: compileSdkPattern, in: $0) + values(of: releasePattern, in: $0) }
    }

    /// The values given to `buildToolsVersion`.
    static func buildToolsValues(_ lines: [String]) -> [String] {
        lines.flatMap { values(of: buildToolsPattern, in: $0) }
    }

    /// A key, not part of a longer name (`compileSdkPreview` and `targetSdk`
    /// don't match), followed by `=` (not `==`), `(`, or spaces and something
    /// a value starts with. Group 1 is the rest of the statement.
    private static func assignmentPattern(_ key: String) -> NSRegularExpression? {
        let value = #"([0-9"'A-Za-z_(\[$][^;]*)"#
        let pattern = #"(?<![A-Za-z0-9_$])"# + key + #"(?![A-Za-z0-9_$])\s*(?:=(?!=)\s*"# + value
            + #"|\(\s*"# + value + #"|[ \t]+"# + value + ")"
        return try? NSRegularExpression(pattern: pattern)
    }

    static let compileSdkPattern = assignmentPattern("compileSdk(?:Version)?")
    static let buildToolsPattern = assignmentPattern("buildToolsVersion")
    /// `compileSdk { version = release(36) { minorApiLevel = 1 } }`.
    static let releasePattern = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_$])version\s*=\s*release\s*\(\s*([^)]*)\)"#
    )

    /// Each value `pattern` captures in `line`, trimmed, up to a `}` outside a
    /// string, which closes the block around it. A value opened with `(` loses
    /// its closing `)`.
    static func values(of pattern: NSRegularExpression?, in line: String) -> [String] {
        guard let pattern else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return pattern.matches(in: line, range: range).compactMap { match in
            for group in 1..<match.numberOfRanges {
                guard let found = Range(match.range(at: group), in: line) else { continue }
                var value = String(line[found])
                if let brace = value.indices.first(where: { value[$0] == "}" && !isInsideString(value, at: $0) }) {
                    value = String(value[..<brace])
                }
                value = value.trimmingCharacters(in: .whitespaces)
                let before = line[..<found.lowerBound].trimmingCharacters(in: .whitespaces)
                if before.hasSuffix("("), value.hasSuffix(")"), !isBalanced(value) {
                    value = String(value.dropLast()).trimmingCharacters(in: .whitespaces)
                }
                return value.isEmpty ? nil : value
            }
            return nil
        }
    }

    private static func isBalanced(_ text: String) -> Bool {
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    // MARK: Values

    /// What `value` means for `kind`. A reference is looked up near `folder`.
    static func evaluate(
        _ value: String,
        as kind: AndroidSDKVersionPolicy.Folder,
        near folder: String,
        reader: inout Reader,
        depth: Int
    ) -> Outcome {
        let expression = stripConversions(value)
        if let literal = literalValue(expression) {
            return literalOutcome(literal, as: kind)
        }
        guard depth < maximumReferenceDepth, let reference = reference(in: expression) else { return .unknown }
        let found = lookUp(reference, near: folder, reader: &reader)
        guard let found else { return .unknown }
        var pins: Set<String> = []
        var ignored = false
        for candidate in found {
            switch evaluate(candidate.value, as: kind, near: candidate.folder, reader: &reader, depth: depth + 1) {
            case .pins(let more): pins.formUnion(more)
            case .ignored: ignored = true
            case .unknown: continue
            }
        }
        if !pins.isEmpty { return .pins(pins) }
        return ignored ? .ignored : .unknown
    }

    /// `value` without the conversions Gradle scripts wrap a value in:
    /// `.toInt()`, `.get()`, `as Integer`, `!!`, and outer brackets.
    static func stripConversions(_ value: String) -> String {
        let suffixes = [
            ".toInt()", ".toInteger()", ".get()", ".toString()", ".orNull", "!!",
            " as Integer", " as int", " as String", " as Int"
        ]
        var text = value.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where text.hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
            if text.hasPrefix("("), text.hasSuffix(")"), isBalanced(String(text.dropFirst().dropLast())) {
                text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return text
    }

    /// A number, or the inside of a one-quoted string with nothing after it.
    /// Nil for anything else, `"$name"` included.
    static func literalValue(_ text: String) -> String? {
        if !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) { return text }
        guard let quote = text.first, quote == "\"" || quote == "'", text.count >= 2, text.last == quote else {
            return nil
        }
        let inside = String(text.dropFirst().dropLast())
        guard !inside.contains(quote), !inside.contains("$"), !inside.contains("\\") else { return nil }
        return inside.trimmingCharacters(in: .whitespaces)
    }

    /// What a written-out value means.
    static func literalOutcome(_ literal: String, as kind: AndroidSDKVersionPolicy.Folder) -> Outcome {
        switch kind {
        case .platform:
            // `35`, `android-35`, and `android-34-ext10` or `android-36.1`, which
            // also keep the base level. An add-on ends in `:33`.
            let base = literal.hasPrefix("android-") ? String(literal.dropFirst("android-".count)) : literal
            let leading = String(base.prefix { $0.isASCII && $0.isNumber })
            if AndroidSDKVersionPolicy.isLevel(leading),
               leading.count == base.count || base.dropFirst(leading.count).first.map({ $0 == "-" || $0 == "." }) == true {
                return .pins(["android-\(leading)"])
            }
            if let colon = literal.lastIndex(of: ":") {
                let level = String(literal[literal.index(after: colon)...])
                return AndroidSDKVersionPolicy.isLevel(level) ? .pins(["android-\(level)"]) : .unknown
            }
            // A preview by its codename, such as `UpsideDownCake`.
            if !base.isEmpty, base.allSatisfy({ $0.isASCII && $0.isLetter }) { return .ignored }
            return .unknown
        case .buildTools:
            guard let first = literal.first, first.isASCII, first.isNumber,
                  literal.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
            else { return .unknown }
            return .pins([literal])
        }
    }

    nonisolated enum Reference: Equatable, Sendable {
        /// `libs.versions.compile.sdk`, by its path after `versions.`.
        case catalog(String)
        /// Any other name: the last part of `rootProject.ext.compileSdkVersion`,
        /// or the quoted name in `property("compileSdk")` or `extra["compileSdk"]`.
        case name(String)
    }

    /// The key a reference names. Nil for an expression Purge doesn't read,
    /// such as `if (…) 34 else 35` or arithmetic.
    static func reference(in expression: String) -> Reference? {
        let quotes = expression.filter { $0 == "\"" || $0 == "'" }
        // `"$name"` and `"${rootProject.ext.name}"`, then plain names.
        if quotes.count == 0 || (quotes.count == 2 && expression.hasPrefix("\"$") && expression.hasSuffix("\"")) {
            var text = expression
            if text.hasPrefix("\"${"), text.hasSuffix("}\"") {
                text = String(text.dropFirst(3).dropLast(2))
            } else if text.hasPrefix("\"$") {
                text = String(text.dropFirst(2).dropLast())
            }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty, parts.allSatisfy(isIdentifier) else { return nil }
            if parts.count > 2, let versions = parts.firstIndex(of: "versions"), versions > 0, versions < parts.count - 1 {
                return .catalog(parts[(versions + 1)...].joined(separator: "."))
            }
            return .name(parts[parts.count - 1])
        }
        // One quoted name inside a call or a subscript.
        if quotes.count == 2 {
            guard let open = expression.firstIndex(where: { $0 == "\"" || $0 == "'" }),
                  let close = expression.lastIndex(where: { $0 == "\"" || $0 == "'" }), open < close else { return nil }
            let name = String(expression[expression.index(after: open)..<close])
            let outside = String(expression[..<open]) + String(expression[expression.index(after: close)...])
            guard isKey(name),
                  outside.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._()[] ".contains($0)) })
            else { return nil }
            return .name(name)
        }
        return nil
    }

    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// A property or catalog key: letters, digits, `.`, `-` and `_`.
    static func isKey(_ text: String) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }

    // MARK: Lookup

    /// A value found for a key, and the folder of the file it was found in.
    nonisolated struct Candidate: Equatable, Sendable {
        var value: String
        var folder: String
    }

    /// Every value given to `reference` in the files near `folder`: it and up to
    /// two folders above, never above home. Nil when one of those files can't be read.
    static func lookUp(_ reference: Reference, near folder: String, reader: inout Reader) -> [Candidate]? {
        var folders: [String] = []
        var current = folder
        for _ in 0...2 {
            folders.append(current)
            guard current != reader.home, current != "/" else { break }
            current = (current as NSString).deletingLastPathComponent
        }
        var found: [Candidate] = []
        switch reference {
        case .catalog(let path):
            for folder in folders {
                guard let catalogs = catalogFiles(in: "\(folder)/gradle", reader: reader) else { return nil }
                for catalog in catalogs {
                    switch reader.read(catalog) {
                    case .absent: continue
                    case .unknown: return nil
                    case .text(let text):
                        found += catalogVersions(text, path: path).map { Candidate(value: $0, folder: folder) }
                    }
                }
            }
        case .name(let key):
            var files: [(String, Bool)] = []
            for folder in folders {
                files.append(("\(folder)/gradle.properties", true))
                files += ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
                    .map { ("\(folder)/\($0)", false) }
            }
            files.append(("\(reader.home)/.gradle/gradle.properties", true))
            for (file, isProperties) in files {
                switch reader.read(file) {
                case .absent: continue
                case .unknown: return nil
                case .text(let text):
                    let fileFolder = (file as NSString).deletingLastPathComponent
                    guard let values = isProperties ? propertyValues(text, key: key) : scriptValues(text, key: key)
                    else { return nil }
                    found += values.map { Candidate(value: $0, folder: fileFolder) }
                }
            }
        }
        return found
    }

    /// The `*.versions.toml` files in a `gradle` folder. Empty when there is
    /// none, nil when the folder is there but can't be listed.
    static func catalogFiles(in folder: String, reader: Reader) -> [String]? {
        guard reader.mayRead(folder) else { return nil }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder)
                .filter { $0.hasSuffix(".versions.toml") }
                .sorted()
                .map { "\(folder)/\($0)" }
        } catch {
            return NvmNodeVersionPolicy.isMissing(folder) ? [] : nil
        }
    }

    /// The values in a catalog's `[versions]` table under the key Gradle turns
    /// into `path`: `-`, `_` and `.` all become `.`, and case is ignored.
    static func catalogVersions(_ text: String, path: String) -> [String] {
        let wanted = normalizedKey(path)
        var inVersions = false
        var values: [String] = []
        for line in codeLines(text) {
            if line.hasPrefix("[") {
                inVersions = line.replacingOccurrences(of: " ", with: "") == "[versions]"
                continue
            }
            guard inVersions, let equals = line.firstIndex(of: "=") else { continue }
            var key = line[..<equals].trimmingCharacters(in: .whitespaces)
            if key.count >= 2, let quote = key.first, quote == "\"" || quote == "'", key.last == quote {
                key = String(key.dropFirst().dropLast())
            }
            guard normalizedKey(key) == wanted else { continue }
            var value = String(line[line.index(after: equals)...])
            // A TOML comment may follow the value.
            if let hash = value.firstIndex(of: "#"), !isInsideString(value, at: hash) {
                value = String(value[..<hash])
            }
            values.append(value.trimmingCharacters(in: .whitespaces))
        }
        return values
    }

    static func normalizedKey(_ key: String) -> String {
        String(key.lowercased().map { $0 == "-" || $0 == "_" ? "." : $0 })
    }

    /// The values `key` has in a `gradle.properties` file, each quoted so it
    /// reads as a string.
    static func propertyValues(_ text: String, key: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix("!"),
                  let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }),
                  line[..<separator].trimmingCharacters(in: .whitespaces) == key else { return nil }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : "\"\(value)\""
        }
    }

    /// The values `key` is given in a build or settings script: `key = value`
    /// (also `ext.key`, `val key`, `def key`), `extra["key"] = value`, and
    /// `set("key", value)`.
    static func scriptValues(_ text: String, key: String) -> [String]? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let value = #"([^;\n]+)"#
        let patterns = [
            #"(?<![A-Za-z0-9_$])"# + escaped + #"["']?\s*\]?\s*(?::\s*[A-Za-z]+\s*)?=(?!=)\s*"# + value,
            #"set\(\s*["']"# + escaped + #"["']\s*,\s*([^)\n]+)\)"#
        ]
        let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        guard regexes.count == patterns.count else { return nil }
        var values: [String] = []
        for line in codeLines(text) {
            for regex in regexes {
                values += Self.values(of: regex, in: line)
            }
        }
        return values
    }
}

private extension AndroidGradlePins.Pins {
    mutating func add(_ outcome: AndroidGradlePins.Outcome, for kind: AndroidSDKVersionPolicy.Folder) {
        switch (outcome, kind) {
        case (.ignored, _):
            return
        case (.unknown, .platform):
            platforms = nil
        case (.unknown, .buildTools):
            buildTools = nil
        case (.pins(let names), .platform):
            platforms = platforms.map { $0.union(names) }
        case (.pins(let names), .buildTools):
            buildTools = buildTools.map { $0.union(names) }
        }
    }
}

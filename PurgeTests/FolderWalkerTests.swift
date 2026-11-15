import Foundation
import Testing
@testable import Purge

/// `FolderWalker` replaced `du` for scan sizing and the file-by-file walk for
/// `FolderSizing.walkedSize`. These pin that it reports what they reported, on
/// temporary folders only, never the user's own (#171).
@Suite("Folder walker counts what du and the file walk counted")
struct FolderWalkerTests {
    private let fm = FileManager.default

    private func makeTemporaryDirectory() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("purge-walker-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    /// Folders, sizes, hidden files, links and hard links of every kind the
    /// walker treats differently.
    private func makeTree(in base: URL) throws -> (one: URL, two: URL) {
        let one = base.appendingPathComponent("one", isDirectory: true)
        let two = base.appendingPathComponent("two", isDirectory: true)
        try write(1, to: one.appendingPathComponent("tiny"))
        try write(9_000, to: one.appendingPathComponent("a/b/c/nine"))
        try write(70_000, to: one.appendingPathComponent("a/seventy"))
        try write(5_000, to: one.appendingPathComponent(".hidden/file"))
        try write(300_000, to: one.appendingPathComponent("Fake.app/Contents/MacOS/binary"))
        try fm.createDirectory(at: one.appendingPathComponent("empty"), withIntermediateDirectories: true)
        // A hard link inside one folder counts once; one shared with `two`
        // counts in each.
        try write(40_000, to: one.appendingPathComponent("linked/original"))
        try fm.linkItem(at: one.appendingPathComponent("linked/original"), to: one.appendingPathComponent("a/second-name"))
        try fm.linkItem(at: one.appendingPathComponent("linked/original"), to: two.appendingPathComponentCreatingParent("shared"))
        try write(12_000, to: two.appendingPathComponent("own"))
        // Links are counted as links and never followed.
        try fm.createSymbolicLink(at: one.appendingPathComponent("link-to-two"), withDestinationURL: two)
        try fm.createSymbolicLink(at: one.appendingPathComponent("link-to-file"), withDestinationURL: one.appendingPathComponent("a/seventy"))
        return (one, two)
    }

    /// `du -sk` on one path, in bytes, or nil when it printed no total.
    private func du(_ path: String, staysOnVolume: Bool = false) -> Int64? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = [staysOnVolume ? "-skx" : "-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
              let tab = line.firstIndex(of: "\t"),
              let kilobytes = Int64(line[line.startIndex..<tab])
        else { return nil }
        return kilobytes * 1024
    }

    // MARK: du

    @Test
    func matchesDuForEveryKindOfEntry() throws {
        let base = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: base) }
        let (one, two) = try makeTree(in: base)
        let paths = [one, two, one.appendingPathComponent("a"), one.appendingPathComponent("tiny"),
                     one.appendingPathComponent("link-to-two"), one.appendingPathComponent("empty")].map(\.path)

        for staysOnVolume in [false, true] {
            let sizes = FolderWalker.shared.sizes(of: paths, staysOnVolume: staysOnVolume)
            #expect(sizes.count == paths.count)
            for (path, size) in zip(paths, sizes) {
                #expect(size == du(path, staysOnVolume: staysOnVolume), "\(path)")
            }
        }
    }

    @Test
    func givesNoFigureForAMissingOrUnreadableFolder() throws {
        let base = try makeTemporaryDirectory()
        let locked = base.appendingPathComponent("locked", isDirectory: true)
        let inner = base.appendingPathComponent("open/inner-locked", isDirectory: true)
        try write(20_000, to: locked.appendingPathComponent("file"))
        try write(20_000, to: inner.appendingPathComponent("file"))
        try write(8_000, to: base.appendingPathComponent("open/visible"))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: inner.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inner.path)
            try? fm.removeItem(at: base)
        }
        let open = base.appendingPathComponent("open").path
        let missing = base.appendingPathComponent("missing").path

        let sizes = FolderWalker.shared.sizes(of: [locked.path, missing, open], staysOnVolume: false)
        #expect(sizes[0] == nil)
        #expect(du(locked.path) == nil)
        #expect(sizes[1] == nil)
        // A folder it cannot open inside one it can counts for nothing, as in `du`.
        #expect(sizes[2] == du(open))
        #expect(FolderSizing.measuredSize(at: locked) == nil)
    }

    /// Paths past `PATH_MAX` are opened one folder at a time. `du` reads such a
    /// folder as empty; the walker counts what is in it.
    @Test
    func readsFoldersDeeperThanPathMax() throws {
        let base = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: base) }
        var deep = base
        while deep.path.utf8.count < Int(PATH_MAX) + 200 {
            deep.appendPathComponent(String(repeating: "d", count: 60), isDirectory: true)
        }
        // `FileManager` refuses paths this long, so the folders are made with
        // `mkdirat` one level at a time.
        var fd = open(base.path, O_RDONLY | O_DIRECTORY)
        for component in deep.path.dropFirst(base.path.count + 1).split(separator: "/") {
            #expect(mkdirat(fd, String(component), 0o755) == 0)
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY)
            close(fd)
            fd = next
        }
        let file = openat(fd, "file", O_WRONLY | O_CREAT, 0o644)
        let bytes = [UInt8](repeating: 1, count: 50_000)
        #expect(Darwin.write(file, bytes, bytes.count) == bytes.count)
        close(file)
        close(fd)

        let size = try #require(FolderWalker.shared.sizes(of: [base.path], staysOnVolume: false)[0])
        #expect(size >= 50_000)
        #expect(size < 50_000 + 200 * 4_096)
    }

    @Test
    func reportsEachFolderOnceAsItFinishes() throws {
        let base = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: base) }
        let (one, two) = try makeTree(in: base)
        let paths = [one.path, two.path, base.appendingPathComponent("missing").path]
        let heard = Heard()

        let sizes = FolderWalker.shared.sizes(of: paths, staysOnVolume: false) { index, bytes in
            heard.add(index, bytes)
        }
        #expect(heard.sorted.map(\.0) == [0, 1, 2])
        #expect(heard.sorted.map(\.1) == sizes)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelledCallReturnsAndTheWalkerKeepsWorking() throws {
        let base = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: base) }
        let (one, _) = try makeTree(in: base)

        let cancelled = FolderWalker.shared.sizes(of: [one.path], staysOnVolume: false, isCancelled: { true })
        #expect(cancelled.count == 1)
        // A cancelled call hears nothing more, and later calls still finish.
        #expect(FolderWalker.shared.sizes(of: [one.path], staysOnVolume: false)[0] == du(one.path))
    }

    @Test
    func scanSizingGoesThroughTheWalker() throws {
        let base = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: base) }
        let (one, two) = try makeTree(in: base)

        let sizes = FolderSizing.directorySizes(at: [one, two, one], split: .spread)
        #expect(sizes == [one.standardizedFileURL.path: du(one.path)!, two.standardizedFileURL.path: du(two.path)!])
        #expect(FolderSizing.walkedSizes(at: [one, two]) == sizes)
    }

    // MARK: walkedSize

    /// `walkedSize` as it was before it used the walker: every regular file's
    /// allocated bytes and its latest access or change.
    private func walkFileByFile(_ url: URL) -> (bytes: Int64, lastUsed: Date) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey,
            .contentAccessDateKey, .contentModificationDateKey
        ]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: []) else {
            return (0, .distantPast)
        }
        var bytes: Int64 = 0
        var lastUsed = Date.distantPast
        while let next = enumerator.nextObject() {
            guard let fileURL = next as? URL,
                  let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { continue }
            bytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            lastUsed = max(lastUsed, max(
                values.contentAccessDate ?? .distantPast,
                values.contentModificationDate ?? .distantPast
            ))
        }
        return (bytes, lastUsed)
    }

    @Test
    func fileTotalsMatchTheFileByFileWalk() throws {
        let base = try makeTemporaryDirectory()
        defer { try? fm.removeItem(at: base) }
        let (one, two) = try makeTree(in: base)
        let old = Date(timeIntervalSince1970: 1_600_000_000.25)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: one.appendingPathComponent("a/b/c/nine").path)

        for url in [one, two, one.appendingPathComponent("Fake.app"), one.appendingPathComponent("empty")] {
            let walked = FolderSizing.walkedSize(at: url, skipsPackages: false)
            let expected = walkFileByFile(url)
            #expect(walked.bytes == expected.bytes, "\(url.path)")
            #expect(abs(walked.lastUsed.timeIntervalSince(expected.lastUsed)) < 0.001, "\(url.path)")
        }
        // Not a folder: nothing, as the file walk found nothing to walk.
        let file = FolderSizing.walkedSize(at: one.appendingPathComponent("tiny"), skipsPackages: false)
        #expect(file.bytes == 0 && file.lastUsed == .distantPast)
        let missing = FolderSizing.walkedSize(at: base.appendingPathComponent("missing"), skipsPackages: false)
        #expect(missing.bytes == 0 && missing.lastUsed == .distantPast)
    }
}

/// The parallel helpers the faster walks are built on.
@Suite("ConcurrentMap keeps order")
struct ConcurrentMapTests {
    /// A made-up tree: each node lists values and children in order.
    private func steps(_ node: Int) -> [TreeStep<Int, Int>] {
        guard node < 400 else { return [.value(node)] }
        return [.value(node), .child(node * 3 + 1), .value(-node), .child(node * 3 + 2), .child(node * 3 + 3)]
    }

    private func depthFirst(_ node: Int) -> [Int] {
        steps(node).flatMap { step -> [Int] in
            switch step {
            case .value(let value): return [value]
            case .child(let child): return depthFirst(child)
            }
        }
    }

    @Test(arguments: [1, 4, 12])
    func treeReturnsValuesInDepthFirstOrder(width: Int) {
        let roots = [0, 1000, 2000]
        let values = ConcurrentMap.tree(roots, width: width, isCancelled: { false }, read: steps)
        #expect(values == roots.flatMap(depthFirst))
    }

    @Test
    func aCancelledTreeStops() {
        let values = ConcurrentMap.tree([0], width: 4, isCancelled: { true }, read: steps)
        #expect(values.isEmpty)
    }

    @Test
    func bothReturnsEachResult() {
        let (text, number) = ConcurrentMap.both({ "left" }, { 42 })
        #expect(text == "left")
        #expect(number == 42)
    }

    /// Maps inside an outer map still give every item, in order.
    @Test
    func nestedMapsKeepEveryItemInOrder() {
        let outer = ConcurrentMap.values(Array(0..<12), width: 12, outer: true) { row in
            ConcurrentMap.values(Array(0..<50)) { row * 100 + $0 }
        }
        #expect(outer == (0..<12).map { row in (0..<50).map { row * 100 + $0 } })
    }

    @Test
    func theGateCoversOnlyOtherAppsContainers() {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        #expect(ContainerAccessGate.isInsideContainers("\(library)/Containers/com.example.app/Data"))
        #expect(ContainerAccessGate.isInsideContainers("\(library)/Group Containers/group.example/x"))
        #expect(!ContainerAccessGate.isInsideContainers("\(library)/Containers"))
        #expect(!ContainerAccessGate.isInsideContainers("\(library)/Caches/com.example.app"))
    }
}

private extension URL {
    func appendingPathComponentCreatingParent(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return appendingPathComponent(name)
    }
}

/// Folders as the walker reports them, from its threads.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [(Int, Int64?)] = []

    func add(_ index: Int, _ bytes: Int64?) {
        lock.lock()
        reports.append((index, bytes))
        lock.unlock()
    }

    var sorted: [(Int, Int64?)] {
        lock.lock()
        defer { lock.unlock() }
        return reports.sorted { $0.0 < $1.0 }
    }
}

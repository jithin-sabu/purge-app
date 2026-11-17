import Foundation
import Testing
@testable import Purge

/// An Ollama store in a folder Large Files walks, at a path Purge doesn't know
/// (`OLLAMA_MODELS` set only in a shell profile while Purge started from the
/// Dock), is known by its shape: `blobs` beside `manifests`. Large Files never
/// lists its blobs one by one, and its gate refuses them, because trashing one
/// blob breaks every model that uses it. AI Models doesn't list such a store
/// either. Every fixture is a throwaway home in the temporary folder.
@Suite("An Ollama store Purge doesn't know stays out of Large Files")
struct OllamaStoreShapeTests {
    // MARK: - Fixtures

    private struct Home {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("purge-ollama-shape-\(UUID().uuidString)", isDirectory: true)
                .standardizedFileURL
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        @discardableResult
        func file(_ relative: String, bytes: Int = 4096) throws -> URL {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x01, count: bytes).write(to: file)
            return file
        }

        /// An Ollama store at `relative`: one model pulled from `registry`,
        /// with one blob. Returns the blob.
        @discardableResult
        func ollamaStore(_ relative: String, registry: String = "registry.ollama.ai") throws -> URL {
            let manifest = url.appendingPathComponent("\(relative)/manifests/\(registry)/library/gemma3/latest")
            try FileManager.default.createDirectory(
                at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let body: [String: Any] = [
                "schemaVersion": 2,
                "layers": [["mediaType": "application/vnd.ollama.image.model", "digest": "sha256:aaa"]],
            ]
            try JSONSerialization.data(withJSONObject: body).write(to: manifest)
            return try file("\(relative)/blobs/sha256-aaa")
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    private func scannedPaths(_ home: Home, roots: [String]) async -> Set<String> {
        let stream = LargeFileScanner().scanStream(
            minBytes: 1024,
            staleDays: 0,
            roots: roots.map { home.url.appendingPathComponent($0, isDirectory: true) },
            virtualMachineRoots: [],
            iCloudDriveRoots: [],
            installedApps: [],
            isAppRunning: { _ in false },
            home: home.url,
            exclusions: ScanExclusions(keys: []),
            isExcluded: { _ in false }
        )
        var paths = Set<String>()
        for await file in stream {
            paths.insert(URL(fileURLWithPath: file.id).resolvingSymlinksInPath().path)
        }
        return paths
    }

    private func real(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    // MARK: - The walk

    /// The bug: the store's blob showed up as a `sha256-…` row of its own.
    @Test
    func blobsOfAnUnknownStoreAreNotListed() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.ollamaStore("Documents/ollama-models")
        let film = try home.file("Documents/film.mov")

        #expect(await scannedPaths(home, roots: ["Documents"]) == [real(film)])
    }

    /// Ollama files a model pulled from Hugging Face under `manifests/hf.co`,
    /// so a store holding only those is still a store.
    @Test
    func aStoreWithModelsFromAnotherRegistryIsSkipped() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.ollamaStore("Documents/Deep/Down/models", registry: "hf.co")

        #expect(await scannedPaths(home, roots: ["Documents"]).isEmpty)
    }

    /// A walked root that is itself a store, such as one picked as a folder to
    /// scan, lists nothing.
    @Test
    func aRootThatIsAStoreListsNothing() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.ollamaStore("Models")

        #expect(await scannedPaths(home, roots: ["Models"]).isEmpty)
    }

    /// APFS compares names without case, so `Blobs` beside `Manifests` is the
    /// same shape. The walk skips it and the gate refuses it alike, so no row
    /// is listed that could only come back "skipped for safety".
    @Test
    func aStoreInOtherCapitalsIsSkippedAndRefused() async throws {
        let home = try Home()
        defer { home.remove() }
        let blob = try home.file("Documents/models/Blobs/sha256-aaa")
        try home.file("Documents/models/Manifests/registry.ollama.ai/library/gemma3/latest")

        #expect(await scannedPaths(home, roots: ["Documents"]).isEmpty)
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(blob, home: home.url))
    }

    /// A root inside a store, such as its `blobs` folder picked as a folder to
    /// scan, lists none of the blobs.
    @Test
    func aRootInsideAStoreListsNothing() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.ollamaStore("Models")

        #expect(await scannedPaths(home, roots: ["Models/blobs"]).isEmpty)
    }

    /// A root linked onto a drive whose top is a store, as when
    /// `OLLAMA_MODELS` is the drive itself and `~/Movies` lives there too. The
    /// gate refuses everything under a store at any height, so the walk lists
    /// nothing there, and no row is offered that can't be cleaned.
    @Test
    func aRootLinkedUnderAStoreListsNothing() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.ollamaStore("Drive")
        try home.file("Drive/Movies/film.mov")
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Movies"),
            withDestinationURL: home.url.appendingPathComponent("Drive/Movies", isDirectory: true)
        )

        #expect(await scannedPaths(home, roots: ["Movies"]).isEmpty)
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(
            home.url.appendingPathComponent("Movies/film.mov"), home: home.url
        ))
    }

    /// The shape needs both folders. A `blobs` folder on its own is the
    /// user's, and its files are listed as before.
    @Test
    func aBlobsFolderAloneIsWalked() async throws {
        let home = try Home()
        defer { home.remove() }
        let file = try home.file("Documents/Project/blobs/big.bin")

        #expect(await scannedPaths(home, roots: ["Documents"]) == [real(file)])
    }

    /// A store named like a VM bundle is still a store. It is not listed as a
    /// virtual machine, and the gate refuses the folder itself.
    @Test
    func aStoreNamedLikeAVirtualMachineIsNotARow() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.ollamaStore("Documents/models.pvm")
        let store = home.url.appendingPathComponent("Documents/models.pvm", isDirectory: true)

        #expect(await scannedPaths(home, roots: ["Documents"]).isEmpty)
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(
            store, home: home.url, isAppRunning: { _ in false }
        ))
    }

    // MARK: - The gates

    /// The Large Files gate refuses a blob and a manifest of the store, so a
    /// row saved before this fix can't trash one either. A file beside the
    /// store still passes.
    @Test
    func largeFilesGateRefusesTheStore() throws {
        let home = try Home()
        defer { home.remove() }
        let blob = try home.ollamaStore("Documents/ollama-models")
        let manifest = home.url.appendingPathComponent(
            "Documents/ollama-models/manifests/registry.ollama.ai/library/gemma3/latest"
        )
        let film = try home.file("Documents/film.mov")

        #expect(!LargeFileScanPolicy.isEligibleForDeletion(blob, home: home.url))
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(manifest, home: home.url))
        #expect(LargeFileScanPolicy.isEligibleForDeletion(film, home: home.url))
    }

    /// Reached through a link to its `blobs` folder, a blob is refused by
    /// where it really is. Its real path is inside Documents, a Large
    /// Files root, so the shape is all that refuses it.
    @Test
    func largeFilesGateRefusesTheStoreThroughALink() throws {
        let home = try Home()
        defer { home.remove() }
        try home.ollamaStore("Documents/ollama-models")
        try FileManager.default.createDirectory(
            at: home.url.appendingPathComponent("Downloads"), withIntermediateDirectories: true
        )
        let link = home.url.appendingPathComponent("Downloads/blobs-link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: home.url.appendingPathComponent("Documents/ollama-models/blobs")
        )

        #expect(!LargeFileScanPolicy.isEligibleForDeletion(
            link.appendingPathComponent("sha256-aaa"), home: home.url
        ))
    }

    /// A folder above the file that can't be listed may be a store, such as
    /// one whose read permission was taken away after the scan, so the gate
    /// refuses a file under it.
    @Test
    func largeFilesGateRefusesUnderAFolderItCannotList() throws {
        let home = try Home()
        defer { home.remove() }
        let blob = try home.ollamaStore("Documents/models")
        let store = home.url.appendingPathComponent("Documents/models", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: store.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.path) }

        #expect(FileManager.default.fileExists(atPath: blob.path))
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(blob, home: home.url))
    }

    /// AI Models lists only the store it knows, so the unknown one has no
    /// rows there, and its gate refuses the blob too. `FileDeleter` asks the
    /// AI model gate for Large Files rows as well, so a yes there would let the
    /// blob go alone.
    @Test
    func aiModelsLeaveAnUnknownStoreAlone() throws {
        let home = try Home()
        defer { home.remove() }
        let blob = try home.ollamaStore("Documents/ollama-models")

        #expect(AIModelScanner.ollamaModels(home: home.url, environment: [:]).isEmpty)
        #expect(!AIModelScanPolicy.isEligibleForDeletion(blob, home: home.url, environment: [:]))
    }

    /// End to end: a blob handed to the user-selected route is skipped for
    /// safety and never reaches the Trash, while a file beside the store goes.
    @MainActor
    @Test
    func fileDeleterSkipsABlobOfAnUnknownStore() async throws {
        let home = try Home()
        defer { home.remove() }
        let blob = try home.ollamaStore("Documents/ollama-models")
        let film = try home.file("Documents/film.mov")

        let trash = FakeTrash()
        let report = try await FileDeleter(home: home.url, trash: trash.trash)
            .deleteUserSelectedFiles(at: [blob, film])

        #expect(trash.trashedPaths == [film.standardizedFileURL.path])
        #expect(report.skippedItems.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
            == [blob.standardizedFileURL.path])
        #expect(FileManager.default.fileExists(atPath: blob.path))
    }
}

import Foundation
import Testing
@testable import Purge

@Suite("Large file search matches on name and location")
struct LargeFileSearchTests {
    private func file(
        path: String,
        displayNameOverride: String? = nil,
        sourceLabel: String? = nil
    ) -> LargeFile {
        LargeFile(
            path: URL(fileURLWithPath: path),
            sizeBytes: 1_000_000,
            lastUsed: Date(),
            category: .video,
            displayNameOverride: displayNameOverride,
            sourceLabel: sourceLabel
        )
    }

    @Test
    func emptyQueryMatchesEverything() {
        let subject = file(path: "/Users/someone/Movies/wedding.mov")
        #expect(subject.matches(searchQuery: ""))
    }

    @Test
    func whitespaceOnlyQueryMatchesEverything() {
        let subject = file(path: "/Users/someone/Movies/wedding.mov")
        #expect(subject.matches(searchQuery: "   "))
    }

    @Test
    func matchesOnFilename() {
        let subject = file(path: "/Users/someone/Movies/wedding.mov")
        #expect(subject.matches(searchQuery: "wedding"))
        #expect(subject.matches(searchQuery: "mov"))
        #expect(!subject.matches(searchQuery: "birthday"))
    }

    @Test
    func matchIsCaseInsensitive() {
        let subject = file(path: "/Users/someone/Movies/Wedding.mov")
        #expect(subject.matches(searchQuery: "wedding"))
        #expect(subject.matches(searchQuery: "WEDDING"))
    }

    @Test
    func matchIsDiacriticInsensitive() {
        let subject = file(path: "/Users/someone/Documents/Résumé.pdf")
        #expect(subject.matches(searchQuery: "resume"))
    }

    @Test
    func matchesOnParentFolder() {
        let subject = file(path: "/Users/someone/Downloads/archive.zip")
        #expect(subject.matches(searchQuery: "Downloads"))
    }

    @Test
    func allTermsMustMatchButOrderDoesNot() {
        let subject = file(path: "/Users/someone/Movies/wedding-final-cut.mov")
        #expect(subject.matches(searchQuery: "wedding cut"))
        #expect(subject.matches(searchQuery: "cut wedding"))
        #expect(!subject.matches(searchQuery: "wedding birthday"))
    }

    @Test
    func termsMayMatchAcrossNameAndFolder() {
        let subject = file(path: "/Users/someone/Downloads/wedding.mov")
        #expect(subject.matches(searchQuery: "downloads wedding"))
    }

    /// The haystack joins its parts with a newline precisely so a query can't match
    /// by straddling the boundary between the folder path and the filename.
    @Test
    func queryCannotMatchAcrossTheNameBoundary() {
        let subject = file(path: "/Users/someone/Downloads/wedding.mov")
        #expect(!subject.matches(searchQuery: "Downloadswedding"))
    }

    @Test
    func matchesOnDisplayNameOverrideRatherThanPathComponent() {
        let subject = file(
            path: "/Users/someone/.ollama/models/manifests/registry.ollama.ai/library/gemma4/latest",
            displayNameOverride: "gemma4:latest",
            sourceLabel: "Ollama"
        )
        #expect(subject.matches(searchQuery: "gemma4:latest"))
        #expect(subject.matches(searchQuery: "gemma"))
    }

    /// A labelled row shows "Ollama" but lives under `~/.ollama` — both the label the
    /// user sees and the path they don't should find it.
    @Test
    func labelledRowMatchesOnBothLabelAndRealPath() {
        let subject = file(
            path: "/Users/someone/.ollama/models/manifests/registry.ollama.ai/library/gemma4/latest",
            displayNameOverride: "gemma4:latest",
            sourceLabel: "Ollama"
        )
        #expect(subject.matches(searchQuery: "Ollama"))
        #expect(subject.matches(searchQuery: "registry.ollama.ai"))
    }
}

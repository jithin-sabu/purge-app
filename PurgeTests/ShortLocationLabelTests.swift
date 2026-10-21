import Foundation
import Testing
@testable import Purge

/// Leftovers rows name only the folder an item sits in.
struct ShortLocationLabelTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    @Test func libraryFolderIsNamedWithoutThePath() {
        let item = home.appendingPathComponent("Library/Application Support/com.example.app")
        #expect(shortLocationLabel(for: item) == "Application Support")
    }

    @Test func deeperLibraryFoldersAreJoined() {
        let item = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        #expect(shortLocationLabel(for: item) == "Application Support › Google")
    }

    @Test func itemsInHomeAndLibraryUseTheirNames() {
        #expect(shortLocationLabel(for: home.appendingPathComponent(".hermes")) == String(localized: "Home folder"))
        #expect(shortLocationLabel(for: home.appendingPathComponent("Library/Example")) == String(localized: "Library"))
    }

    @Test func otherFoldersKeepTheirPath() {
        #expect(shortLocationLabel(for: home.appendingPathComponent(".config/tool")) == "~/.config")
        #expect(shortLocationLabel(for: URL(fileURLWithPath: "/Library/Application Support/Tool")) == "/Library/Application Support")
    }
}

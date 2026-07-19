import Foundation
import Testing
@testable import Purge

@Suite("Large file scan policy stays separate from cache safety")
struct LargeFileScanPolicyTests {
    private var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    @Test
    func downloadsVideoIsEligibleForLargeFileDeletion() throws {
        let url = home.appendingPathComponent("Downloads/purge-test-eligibility-\(UUID().uuidString).mkv")
        FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(LargeFileScanPolicy.isEligibleForDeletion(url))
    }

    @Test
    func moviesVideoIsEligibleForLargeFileDeletion() throws {
        let url = home.appendingPathComponent("Movies/purge-test-eligibility-\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: url.path, contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(LargeFileScanPolicy.isEligibleForDeletion(url))
    }

    @Test
    func cacheSafetyStillBlocksPersonalMediaPaths() {
        let downloads = home.appendingPathComponent("Downloads/movie.mkv")
        let movies = home.appendingPathComponent("Movies/movie.mp4")

        #expect(DeletionSafetyPolicy.evaluate(downloads) == .blockedNeverDelete)
        #expect(DeletionSafetyPolicy.evaluate(movies) == .blockedNeverDelete)
        #expect(!DeletionSafetyPolicy.isOfferedForCleanup(downloads))
        #expect(!DeletionSafetyPolicy.isOfferedForCleanup(movies))
    }

    @Test
    func libraryPathsAreNotEligibleForLargeFileDeletion() {
        let url = home.appendingPathComponent("Library/Caches/com.example.app/cache.db")
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(url))
    }

    @Test
    func photosLibraryDescendantsAreExcluded() {
        let url = home
            .appendingPathComponent("Pictures/Photos Library.photoslibrary/originals/photo.jpg")
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(url))
    }

    @Test
    func scanRootsCoverUserContentFolders() {
        let roots = LargeFileScanPolicy.scanRoots(home: home).map(\.lastPathComponent)
        #expect(roots.contains("Downloads"))
        #expect(roots.contains("Movies"))
        #expect(roots.contains("Documents"))
    }
}

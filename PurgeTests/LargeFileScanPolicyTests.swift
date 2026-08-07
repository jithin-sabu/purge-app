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

    /// Both of these were listed individually in Large Files. They are project
    /// dependencies restored by `npm install` / `pod install`, and Dev Projects
    /// already offers the folders that hold them.
    @Test(arguments: [
        "Documents/purge-landing-page/node_modules/@next/swc-darwin-arm64/next-swc.darwin-arm64.node",
        "Documents/app/ios/Pods/hermes-engine-artifacts/hermes-ios-0.79.6-release.tar.gz",
        "Documents/api/vendor/github.com/some/dep/blob.bin",
        "Documents/rust-app/target/release/binary",
        "Documents/py/venv/lib/site-packages/torch/lib/libtorch.dylib",
        "Desktop/old-project/node_modules/esbuild/bin/esbuild",
        // Xcode's SwiftPM checkout — a bare git repo of .pack files.
        "Documents/app/build/SourcePackages/repositories/GRDB.swift-dd0599db/objects/pack/pack-030a.pack",
        // Gradle build output: stripped native libs and React Native source maps.
        "Documents/app/android/app/build/intermediates/merged_native_libs/debug/out/lib/arm64-v8a/libreactnative.so",
        "Documents/app/android/app/build/intermediates/sourcemaps/react/release/index.android.bundle.map",
        "Documents/app/build/Debug/MyApp.app/Contents/MacOS/MyApp",
    ])
    func projectDependencyFilesAreNotOfferedAsLargeFiles(relativePath: String) {
        let url = home.appendingPathComponent(relativePath)
        #expect(LargeFileScanPolicy.isInsideExcludedDirectory(url))
        #expect(!LargeFileScanPolicy.isEligibleForDeletion(url))
    }

    @Test(arguments: ["node_modules", "Pods", "vendor", "target", "__pycache__", "build", "SourcePackages"])
    func projectArtifactDirectoriesAreNotDescendedInto(folderName: String) {
        let url = home.appendingPathComponent("Documents/project/\(folderName)")
        #expect(LargeFileScanPolicy.isExcludedDirectory(url))
    }

    /// The exclusion must not swallow the files Large Files exists to show.
    @Test(arguments: [
        "Downloads/Xcode_16.dmg",
        "Documents/vendor-contract-scan.pdf",
        "Movies/target-practice.mov",
        "Pictures/node-conference-photo.jpg",
    ])
    func ordinaryUserFilesAreStillOffered(relativePath: String) {
        let url = home.appendingPathComponent(relativePath)
        #expect(!LargeFileScanPolicy.isInsideExcludedDirectory(url))
    }

    @Test
    func scanRootsCoverUserContentFolders() {
        let roots = LargeFileScanPolicy.scanRoots(home: home).map(\.lastPathComponent)
        #expect(roots.contains("Downloads"))
        #expect(roots.contains("Movies"))
        #expect(roots.contains("Documents"))
    }
}

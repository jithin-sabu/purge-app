import Foundation
import Testing
@testable import Purge

/// A project row's icon was picked by finding short names anywhere in the
/// artifact's path, the user's own folders included (#183).
@Suite("Project row icons")
struct BrandIconMappingTests {
    @Test(arguments: ["bunny", "phoenix", "/Users/bunny/Code/app/.build", "digital-target"])
    func aNameThatOnlyContainsAPatternHasNoIcon(name: String) {
        #expect(BrandIconMapping.slug(forPathComponent: name) == nil)
    }

    @Test func aFolderNamedExactlyAfterAToolHasItsIcon() {
        #expect(BrandIconMapping.slug(forPathComponent: "node_modules") == "nodedotjs")
        #expect(BrandIconMapping.slug(forPathComponent: "__pycache__") == "python")
    }

    @Test(arguments: [
        (DeletableArtifactKind.nextBuild, "nextdotjs"),
        (.viteCache, "vite"),
        (.swiftPMBuild, "swift"),
        (.composerVendor, "php"),
        (.bundlerVendor, "ruby"),
        (.gradleBuild, "gradle"),
    ])
    func artifactKindsNameTheirIcon(kind: DeletableArtifactKind, slug: String) {
        #expect(BrandIconMapping.slug(forArtifactKind: kind) == slug)
    }
}

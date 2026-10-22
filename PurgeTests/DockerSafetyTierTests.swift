import Foundation
import Testing
@testable import Purge

/// Docker Desktop's container is mostly `Docker.raw`, the VM disk that holds every
/// image, container, and volume. Volumes can hold the only copy of a database, so
/// the row must never reach one-click or scheduled cleanup, which only take Safe
/// rows. It shipped as Safe once because the tier lives in explanations.json, away
/// from the "Check First" comment in DeletionSafetyPolicy.
@Suite("Docker Desktop is Check First")
struct DockerSafetyTierTests {
    @Test
    func bundledDockerRecordIsCheckFirst() {
        let record = ExplanationDatabase.matchBundledDatabase(folderName: "docker")
        #expect(record?.safetyLevel == .medium)
    }

    @Test
    func dockerDesktopRowResolvesToCheckFirst() {
        // No path, so a user override on this machine cannot change the answer.
        let info = DevScanner.automaticSafetyInfo(forDevToolLabel: "Docker Desktop", primaryPath: nil)
        #expect(info.level == .medium)
    }

    /// Cleaning takes every image, container and volume, so the text must say
    /// so: a user with no important volumes still loses pulled images and local
    /// builds. The prune command is something the user runs, not Purge, and only
    /// works while Docker is open. Quitting comes before cleaning, so the text
    /// must not read "quit, then prune".
    @Test
    func dockerExplanationSaysWhatCleaningTakesAndHowToKeepVolumes() throws {
        let record = ExplanationDatabase.matchBundledDatabase(folderName: "docker")
        #expect(record?.displayName == "Docker Desktop")
        let explanation = record?.explanation ?? ""
        #expect(explanation.contains("image"))
        #expect(explanation.contains("container"))
        #expect(explanation.contains("volume"))
        #expect(explanation.contains("databases"))
        let prune = try #require(explanation.range(of: "run docker --context desktop-linux system prune while Docker is open"))
        let quit = try #require(explanation.range(of: "quit Docker"))
        #expect(prune.upperBound <= quit.lowerBound)
    }
}

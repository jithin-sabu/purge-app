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

    /// Cleaning moves the container folder to the Trash. The prune command is
    /// something the user runs, not Purge, so the explanation has to say both.
    @Test
    func dockerExplanationSaysTheFolderGoesToTheTrash() {
        let record = ExplanationDatabase.matchBundledDatabase(folderName: "docker")
        #expect(record?.displayName == "Docker Desktop")
        let explanation = record?.explanation ?? ""
        #expect(explanation.contains("moves the whole folder to the Trash"))
        #expect(explanation.contains("run docker --context desktop-linux system prune yourself"))
    }
}

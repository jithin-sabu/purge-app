import AppKit
import Combine
import Foundation

/// Owns the trash total and hands the user off to Finder to act on it.
///
/// Purge deliberately cannot empty the trash. Deleting for good is the user's decision
/// to make, in the app that owns the trash across every mounted volume, with its own
/// warning in front of it. That keeps "Purge never permanently deletes anything" true
/// without an asterisk, and costs nothing: Finder is one click away, and this needs no
/// automation permission at all.
@MainActor
final class TrashStore: ObservableObject {
    @Published private(set) var trashBytes: Int64 = 0

    private let trashURL: URL?

    init() {
        trashURL = try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
    }

    var hasTrashContents: Bool { trashBytes > 0 }

    func refresh() async {
        guard let trashURL else { return }
        let bytes = await Task.detached(priority: .utility) {
            FolderSizing.directoryByteSize(at: trashURL)
        }.value
        trashBytes = bytes
    }

    func openTrashInFinder() {
        guard let trashURL else { return }
        NSWorkspace.shared.open(trashURL)
    }
}

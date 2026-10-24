import Foundation
@testable import Purge

/// Runs `body` with `RemovedAppHandoff.root` bound to a temporary folder of its own.
///
/// The root is a task-local value, so the binding reaches everything `body`
/// awaits and nothing else. Suites run in parallel, and a shared global that two
/// of them set and restore in turn left one reading the other's folder, or the
/// real ~/Library/Application Support/Purge. The folder is removed afterwards.
func withTemporaryHandoffRoot<T>(_ body: () throws -> T) throws -> T {
    let root = makeHandoffRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    return try RemovedAppHandoff.$root.withValue(root, operation: body)
}

func withTemporaryHandoffRoot<T>(_ body: () async throws -> T) async throws -> T {
    let root = makeHandoffRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    return try await RemovedAppHandoff.$root.withValue(root, operation: body)
}

private func makeHandoffRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("purge-handoff-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

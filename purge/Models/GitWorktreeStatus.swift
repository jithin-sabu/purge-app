import Foundation

/// Whether the enclosing Git repository looks clean for cleanup decisions.
enum GitWorktreeStatus: String, Codable, Hashable {
    case unknown
    case clean
    case dirty
}

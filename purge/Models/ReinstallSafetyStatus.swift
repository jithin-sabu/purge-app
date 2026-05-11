import Foundation

enum ReinstallSafetyStatus: String, Codable, Hashable {
    /// Safe to recreate with the usual project setup commands.
    case reinstallable
    /// No supporting version-pinned files found near the project.
    case missingLockfile
    /// DerivedData and similar targets that skip lockfile logic.
    case notApplicable
}

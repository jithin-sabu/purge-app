import Foundation

/// Owns the app's long-lived models.
///
/// These used to be `@StateObject`s on `PurgeApp`, which tied their lifetime to
/// the window. Menu-bar-only mode can launch with no window at all, so ownership
/// moved here and `PurgeApp` now adopts these instances rather than creating them.
/// `AppBootstrapper` wires them up from the app delegate.
@MainActor
enum AppEnvironment {
    static let store = PurgeStore()
    static let diskStore = DiskSummaryStore()
    static let trashStore = TrashStore()
    static let menuModel = MenuViewModel()
}

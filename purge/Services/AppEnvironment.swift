import Foundation

/// Owns the app's long-lived models.
///
/// These used to be `@StateObject`s on `PurgeApp`, which tied their lifetime to
/// the window. Menu-bar-only mode can launch with no window at all, so ownership
/// moved here and `PurgeApp` now adopts these instances rather than creating them.
/// `AppBootstrapper` wires them up from the app delegate.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let store = PurgeStore()
    let diskStore = DiskSummaryStore()
    let trashStore = TrashStore()
    let menuModel = MenuViewModel()

    private init() {}
}

import Foundation
import ServiceManagement

enum LoginItemRegistrar {
  /// Whether macOS has the login item: enabled, or still awaiting the user's
  /// approval in System Settings. One awaiting approval used to count as not
  /// registered, so leaving the menu bar mode left it behind, and approving it
  /// later opened a window at every login in on-demand mode (#177).
  static var isRegistered: Bool {
    if #available(macOS 13.0, *) {
      return hasLoginItem(status: SMAppService.mainApp.status)
    }
    return false
  }

  nonisolated static func hasLoginItem(status: SMAppService.Status) -> Bool {
    switch status {
    case .enabled, .requiresApproval: return true
    case .notRegistered, .notFound: return false
    @unknown default: return false
    }
  }

  @discardableResult
  static func register() -> Bool {
    guard #available(macOS 13.0, *) else { return false }
    do {
      try SMAppService.mainApp.register()
      return isRegistered
    } catch {
      return false
    }
  }

  static func unregister() {
    guard #available(macOS 13.0, *) else { return }
    try? SMAppService.mainApp.unregister()
  }
}

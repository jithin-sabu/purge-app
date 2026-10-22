import Foundation
import ServiceManagement

enum LoginItemRegistrar {
  /// Whether the login item is enabled: macOS will launch Purge at login.
  static var isRegistered: Bool {
    if #available(macOS 13.0, *) {
      return SMAppService.mainApp.status == .enabled
    }
    return false
  }

  /// Whether macOS has the login item at all: enabled, or still awaiting the
  /// user's approval in System Settings. Leaving the menu bar mode removes the
  /// item, and one awaiting approval used to be left behind: approved later, it
  /// opened a window at every login in on-demand mode (#177).
  static var isRegisteredOrAwaitingApproval: Bool {
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
      return SMAppService.mainApp.status == .enabled
    } catch {
      return false
    }
  }

  static func unregister() {
    guard #available(macOS 13.0, *) else { return }
    try? SMAppService.mainApp.unregister()
  }
}

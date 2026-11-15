import Foundation

nonisolated struct SimulatorDevice: Identifiable, Hashable {
    let id: UUID
    let deviceName: String
    let runtimeVersion: String
    let isAvailable: Bool
    let lastBootedAt: Date?
    /// `nil` while folder sizing is still running.
    var sizeOnDisk: Int64?
    let folderURL: URL
    var isSelected: Bool
    let safetyInfo: SafetyInfo

    var formattedSize: String {
        guard let sizeOnDisk else { return String(localized: "Calculating…") }
        return formatBytes(sizeOnDisk)
    }

    /// A device that is not shut down is listed so its space is accounted for, but
    /// never offered: a test run or the Simulator app may be using it, and one that
    /// is booting, shutting down or being created is changing under `simctl` (#178).
    /// The row has no checkbox, so the explanation says how to make it removable.
    static func runningSafetyInfo(deviceName: String, runtimeVersion: String, isBooted: Bool) -> SafetyInfo {
        SafetyInfo(
            level: .medium,
            headline: "\(deviceName) · \(runtimeVersion)",
            explanation: isBooted
                ? String(localized: "Running now, so it can't be removed. Shut it down in Simulator, then scan again.")
                : String(localized: "Busy right now, so it can't be removed. Scan again in a moment."),
            recoverySteps: "",
            reinstallCommand: nil
        )
    }

    /// Always Check First. Safe means Clean Safe Items and scheduled cleans take the
    /// item without asking, and they only move things to the Trash. `simctl delete`
    /// removes the device and its apps and data for good (#136).
    static func safetyInfo(
        isAvailable: Bool,
        lastBootedAt: Date?,
        deviceName: String,
        runtimeVersion: String
    ) -> SafetyInfo {
        let headline = "\(deviceName) · \(runtimeVersion)"
        // The explanation says when the device was last used, so the user can tell
        // a forgotten one from one in use, and what deleting costs. The runtime stays.
        let cost = String(localized: "Deletes its apps and data.")
        let explanation: String
        if !isAvailable {
            // CoreSimulator marks a device unavailable for more than one reason
            // (missing runtime, unsupported device type), so don't name one.
            explanation = String(localized: "Xcode can no longer run this device. \(cost)")
        } else if let lastUsed = lastBootedAt {
            let monthsAgo = Calendar.current.dateComponents([.month], from: lastUsed, to: Date()).month ?? 0
            if monthsAgo < 1 {
                explanation = String(localized: "Used in the last month. \(cost)")
            } else if monthsAgo == 1 {
                explanation = String(localized: "Last used 1 month ago. \(cost)")
            } else {
                explanation = String(localized: "Last used \(monthsAgo) months ago. \(cost)")
            }
        } else {
            // simctl omits lastBootedAt for some devices that have been used, so a
            // missing date does not mean the device was never booted.
            explanation = String(localized: "Last use unknown. \(cost)")
        }

        return SafetyInfo(
            level: .medium,
            headline: headline,
            explanation: explanation,
            recoverySteps: "",
            reinstallCommand: nil
        )
    }
}

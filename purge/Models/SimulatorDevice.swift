import Foundation

struct SimulatorDevice: Identifiable, Hashable {
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
        guard let sizeOnDisk else { return "Calculating…" }
        return formatBytes(sizeOnDisk)
    }

    static func safetyInfo(
        isAvailable: Bool,
        lastBootedAt: Date?,
        deviceName: String,
        runtimeVersion: String
    ) -> SafetyInfo {
        let headline = "\(deviceName) — \(runtimeVersion)"
        if !isAvailable {
            return SafetyInfo(
                level: .safe,
                headline: headline,
                explanation: "This simulator's iOS runtime is no longer installed. It's safe to delete.",
                recoverySteps: "",
                reinstallCommand: nil
            )
        }
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast

        guard let lastUsed = lastBootedAt else {
            return SafetyInfo(
                level: .safe,
                headline: headline,
                explanation: "Not used recently. Safe to delete. Xcode will re-download it if you need it again.",
                recoverySteps: "",
                reinstallCommand: nil
            )
        }

        let level: SafetyLevel = lastUsed >= thirtyDaysAgo ? .medium : .safe
        let monthsAgo = Calendar.current.dateComponents([.month], from: lastUsed, to: Date()).month ?? 0
        let explanation: String
        if monthsAgo < 1 {
            explanation = "Used recently. Safe to delete but Xcode will re-download it if you need it again."
        } else if monthsAgo < 3 {
            explanation = "Used \(monthsAgo) month\(monthsAgo == 1 ? "" : "s") ago. Safe to delete. Xcode will re-download it if you need it again."
        } else {
            explanation = "Not used in over \(monthsAgo) months. Safe to delete. Xcode will re-download it if you need it again."
        }

        return SafetyInfo(
            level: level,
            headline: headline,
            explanation: explanation,
            recoverySteps: "",
            reinstallCommand: nil
        )
    }
}

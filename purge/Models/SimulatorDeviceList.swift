import Foundation

/// One answer from `simctl list devices -j`. The device scan, the runtime rows'
/// device counts and the check after a device delete all read it through here, so
/// there is one parser for it (#178).
nonisolated struct SimulatorDeviceList: Equatable, Sendable {
    struct Device: Equatable, Sendable {
        /// `nil` when the entry has none; it still counts toward its runtime.
        let udid: String?
        let name: String?
        /// `Shutdown`, `Booted`, `Booting`, `Shutting Down` or `Creating`, as
        /// `simctl` spells it. Empty when missing.
        let state: String
        let isAvailable: Bool
        let lastBootedAt: Date?
        let dataPath: String?
    }

    /// Devices by the runtime identifier they run on.
    let devicesByRuntime: [String: [Device]]

    /// `nil` when the JSON is not a device list.
    static func parse(_ data: Data) -> SimulatorDeviceList? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else { return nil }
        let dateParser = ISO8601DateFormatter()
        var byRuntime: [String: [Device]] = [:]
        for (runtimeIdentifier, rawList) in devices {
            let entries = (rawList as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            byRuntime[runtimeIdentifier] = entries.map { entry in
                Device(
                    udid: entry["udid"] as? String,
                    name: entry["name"] as? String,
                    state: entry["state"] as? String ?? "",
                    isAvailable: entry["isAvailable"] as? Bool ?? true,
                    lastBootedAt: (entry["lastBootedAt"] as? String).flatMap { dateParser.date(from: $0) },
                    dataPath: entry["dataPath"] as? String
                )
            }
        }
        return SimulatorDeviceList(devicesByRuntime: byRuntime)
    }

    /// Simulators per runtime, every state included.
    var countsByRuntime: [String: Int] {
        devicesByRuntime.mapValues(\.count)
    }

    func contains(udid: String) -> Bool {
        devicesByRuntime.values.contains { devices in
            devices.contains { $0.udid?.caseInsensitiveCompare(udid) == .orderedSame }
        }
    }
}

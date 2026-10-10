import Foundation

/// One simulator runtime disk image (an iOS, watchOS, tvOS or visionOS copy that
/// simulators boot from), as `simctl runtime list -j` reports it.
///
/// Each is about 8 GB and Xcode keeps every one it ever downloaded. Purge removes
/// them through `simctl runtime delete`, never by touching the mounted volume or
/// the MobileAsset download itself.
nonisolated struct SimulatorRuntime: Identifiable, Hashable {
    /// The disk image identifier `simctl runtime delete` takes.
    let id: String
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-3`; the key the device list groups by.
    let runtimeIdentifier: String
    /// `iOS`, `watchOS`, `tvOS` or `visionOS`.
    let platformName: String
    let version: String
    let build: String
    /// `Patchable Cryptex Disk Image` for runtimes from Xcode 16 on, `Cryptex Disk
    /// Image` for older ones. The older layout keeps a second copy of the image
    /// that Apple's own delete can leave behind.
    let kind: String
    let state: String
    /// What `simctl` reports. It undercounts the older layout and can undercount
    /// the newer one too, so the clean reports the measured volume delta instead.
    let sizeBytes: Int64
    let lastUsedAt: Date?
    /// Simulators built on this runtime. `nil` when the device list could not be read.
    let deviceCount: Int?
    /// The mounted volume, or the image when it is not mounted. Only a handle for
    /// the row, the history entry and Reveal in Finder; nothing is deleted at it.
    let locationURL: URL
    let safetyInfo: SafetyInfo

    var formattedSize: String { formatBytes(sizeBytes) }

    /// The pre-Xcode 16 layout: a bundle image cloned from the MobileAsset download.
    var isLegacyImage: Bool { !kind.hasPrefix("Patchable") }

    // MARK: - Parsing

    /// Builds rows from `simctl runtime list -j`.
    ///
    /// - Parameter deviceCountsByRuntimeIdentifier: from ``deviceCounts(fromDevicesList:)``;
    ///   `nil` when the device list could not be read, which keeps every row at Check First.
    /// - Parameter xcodeRuntimeBuilds: from ``xcodeRuntimeBuilds(fromMatchList:)``; the
    ///   builds the selected Xcode creates new simulators on. `nil` when that could not
    ///   be read, which also keeps every row at Check First.
    static func parseRuntimeList(
        _ data: Data,
        deviceCountsByRuntimeIdentifier: [String: Int]?,
        xcodeRuntimeBuilds: Set<String>?,
        now: Date = Date()
    ) -> [SimulatorRuntime] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let dateParser = ISO8601DateFormatter()
        var built: [SimulatorRuntime] = []

        for (identifier, rawEntry) in root {
            guard let entry = rawEntry as? [String: Any] else { continue }
            // Only images `simctl` itself is willing to delete. Anything else is
            // Xcode's own business.
            guard (entry["deletable"] as? Bool) == true else { continue }
            guard let runtimeIdentifier = entry["runtimeIdentifier"] as? String,
                  let version = entry["version"] as? String,
                  let build = entry["build"] as? String else { continue }

            let locationPath = (entry["mountPath"] as? String)
                ?? (entry["path"] as? String)
                ?? (entry["runtimeBundlePath"] as? String)
            guard let locationPath, !locationPath.isEmpty else { continue }

            let sizeBytes: Int64
            if let number = entry["sizeBytes"] as? NSNumber {
                sizeBytes = number.int64Value
            } else {
                sizeBytes = 0
            }
            let lastUsedAt = (entry["lastUsedAt"] as? String).flatMap { dateParser.date(from: $0) }
            let kind = entry["kind"] as? String ?? ""
            let state = entry["state"] as? String ?? ""
            let platformName = Self.platformName(
                runtimeIdentifier: runtimeIdentifier,
                platformIdentifier: entry["platformIdentifier"] as? String
            )
            let deviceCount = deviceCountsByRuntimeIdentifier.map { $0[runtimeIdentifier] ?? 0 }

            let safety = safetyInfo(
                platformName: platformName,
                version: version,
                state: state,
                sizeBytes: sizeBytes,
                lastUsedAt: lastUsedAt,
                deviceCount: deviceCount,
                isXcodeDefault: xcodeRuntimeBuilds.map { $0.contains(build) },
                isLegacyImage: !kind.hasPrefix("Patchable"),
                now: now
            )

            built.append(SimulatorRuntime(
                id: identifier,
                runtimeIdentifier: runtimeIdentifier,
                platformName: platformName,
                version: version,
                build: build,
                kind: kind,
                state: state,
                sizeBytes: sizeBytes,
                lastUsedAt: lastUsedAt,
                deviceCount: deviceCount,
                locationURL: URL(fileURLWithPath: locationPath, isDirectory: true),
                safetyInfo: safety
            ))
        }

        return built.sorted {
            if $0.platformName != $1.platformName { return $0.platformName < $1.platformName }
            return $0.version.compare($1.version, options: .numeric) == .orderedDescending
        }
    }

    /// Simulators per runtime from `simctl list devices -j`, every state included.
    /// `nil` when the JSON is not a device list.
    static func deviceCounts(fromDevicesList data: Data) -> [String: Int]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else { return nil }
        var counts: [String: Int] = [:]
        for (runtimeIdentifier, rawList) in devices {
            counts[runtimeIdentifier] = (rawList as? [[String: Any]])?.count ?? 0
        }
        return counts
    }

    /// Runtime builds the selected Xcode picks for each SDK, from
    /// `simctl runtime match list -j`. Deleting one of these only makes Xcode
    /// download it again the next time a simulator is created.
    static func xcodeRuntimeBuilds(fromMatchList data: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var builds: Set<String> = []
        for rawEntry in root.values {
            guard let entry = rawEntry as? [String: Any] else { continue }
            if let chosen = entry["chosenRuntimeBuild"] as? String, !chosen.isEmpty {
                builds.insert(chosen)
            }
        }
        return builds
    }

    static func platformName(runtimeIdentifier: String, platformIdentifier: String?) -> String {
        switch platformIdentifier {
        case "com.apple.platform.iphonesimulator": return "iOS"
        case "com.apple.platform.watchsimulator": return "watchOS"
        case "com.apple.platform.appletvsimulator": return "tvOS"
        case "com.apple.platform.xrsimulator": return "visionOS"
        default: break
        }
        // `com.apple.CoreSimulator.SimRuntime.iOS-26-3` -> `iOS`
        let tail = runtimeIdentifier.split(separator: ".").last.map(String.init) ?? runtimeIdentifier
        let name = tail.split(separator: "-").first.map(String.init) ?? tail
        return name == "xrOS" ? "visionOS" : name
    }

    // MARK: - Safety

    /// Safe only when nothing uses the runtime: no simulator is built on it, Xcode
    /// does not create new simulators on it, and it has not been started in 30 days.
    /// A missing last-use date counts as unused, the same reading the simulator
    /// device rows give a missing boot date. Anything that could not be checked
    /// (`deviceCount` or `isXcodeDefault` nil) keeps the row at Check First.
    static func safetyInfo(
        platformName: String,
        version: String,
        state: String,
        sizeBytes: Int64,
        lastUsedAt: Date?,
        deviceCount: Int?,
        isXcodeDefault: Bool?,
        isLegacyImage: Bool,
        now: Date = Date()
    ) -> SafetyInfo {
        let headline = String(localized: "\(platformName) \(version) Runtime")
        // Not a trash move: the only way back is Apple's download.
        var cost = String(localized: "Xcode downloads it again (\(formatBytes(sizeBytes))) if a simulator needs it.")
        if isLegacyImage {
            cost = String(localized: "\(cost) Older image format, so macOS may keep its original download.")
        }

        // Each explanation is one localized sentence with the cost at the end, the
        // same shape as the simulator device rows, so translations can drop the
        // space English puts between sentences.
        func info(_ level: SafetyLevel, _ explanation: String) -> SafetyInfo {
            SafetyInfo(
                level: level,
                headline: headline,
                explanation: explanation,
                recoverySteps: "",
                reinstallCommand: nil
            )
        }

        // `Unusable` is CoreSimulator's own verdict that the image cannot boot.
        // Anything else that is not `Ready` is in flight (staging, mounting,
        // unmounting) and is not offered as Safe on usage alone.
        if state == "Unusable" {
            return info(.safe, String(localized: "Xcode can no longer use this runtime. \(cost)"))
        }
        if !state.isEmpty, state != "Ready" {
            return info(.medium, String(localized: "Xcode lists it as \(state.lowercased()). \(cost)"))
        }
        guard let isXcodeDefault else {
            return info(.medium, String(localized: "Could not check whether Xcode uses it for new simulators. \(cost)"))
        }
        if isXcodeDefault {
            return info(.medium, String(localized: "Xcode creates new simulators on this runtime. \(cost)"))
        }
        guard let deviceCount else {
            return info(.medium, String(localized: "Could not check which simulators use it. \(cost)"))
        }
        if deviceCount == 1 {
            return info(.medium, String(localized: "1 simulator uses it. \(cost)"))
        }
        if deviceCount > 1 {
            return info(.medium, String(localized: "\(deviceCount) simulators use it. \(cost)"))
        }

        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        guard let lastUsedAt else {
            return info(.safe, String(localized: "No simulator uses it. Last use unknown. \(cost)"))
        }
        if lastUsedAt >= thirtyDaysAgo {
            return info(.medium, String(localized: "No simulator uses it, but it was used in the last month. \(cost)"))
        }
        let monthsAgo = Calendar.current.dateComponents([.month], from: lastUsedAt, to: now).month ?? 0
        if monthsAgo < 1 {
            return info(.safe, String(localized: "No simulator uses it. Last used over a month ago. \(cost)"))
        }
        if monthsAgo == 1 {
            return info(.safe, String(localized: "No simulator uses it. Last used 1 month ago. \(cost)"))
        }
        return info(.safe, String(localized: "No simulator uses it. Last used \(monthsAgo) months ago. \(cost)"))
    }
}

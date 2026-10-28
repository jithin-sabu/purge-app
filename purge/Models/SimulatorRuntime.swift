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
    /// Image` for older ones. An older one is mounted from inside Apple's
    /// MobileAsset download, which Apple's own delete can leave behind.
    let kind: String
    let state: String
    /// What `simctl` reports. It can be wrong either way, so the clean records
    /// what the volume gave back instead (#165).
    let sizeBytes: Int64
    let lastUsedAt: Date?
    /// Simulators built on this runtime. `nil` when the device list could not be read.
    let deviceCount: Int?
    /// The mounted volume, or the image when it is not mounted. Only a handle for
    /// the row, the history entry and Reveal in Finder; nothing is deleted at it.
    let locationURL: URL
    let safetyInfo: SafetyInfo

    var formattedSize: String { formatBytes(sizeBytes) }

    /// The pre-Xcode 16 layout.
    var isLegacyImage: Bool { Self.isLegacyImage(kind: kind) }

    static func isLegacyImage(kind: String) -> Bool { !kind.hasPrefix("Patchable") }

    // MARK: - Parsing

    /// Builds rows from `simctl runtime list -j`.
    ///
    /// - Parameter deviceCountsByRuntimeIdentifier: from ``deviceCounts(fromDevicesList:)``;
    ///   `nil` when the device list could not be read, which keeps every row at Check First.
    /// - Parameter xcodeRuntimeBuilds: from ``xcodeRuntimeBuilds(fromMatchList:)``; the
    ///   builds the selected Xcode creates new simulators on. `nil` when that could not
    ///   be read, which also keeps every row at Check First.
    /// - Parameter downloadBuilds: from ``downloads(in:)``; the builds Apple keeps a
    ///   MobileAsset download of. `nil` when that could not be read, which leaves out
    ///   every older-format runtime.
    /// - Parameter deviceReachByBuild: from ``deviceReachByBuild(fromRuntimesList:)``;
    ///   empty when that could not be read, which only leaves the warning out.
    static func parseRuntimeList(
        _ data: Data,
        deviceCountsByRuntimeIdentifier: [String: Int]?,
        xcodeRuntimeBuilds: Set<String>?,
        downloadBuilds: Set<String>?,
        deviceReachByBuild: [String: DeviceReach] = [:],
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
            // An older-format runtime is mounted from inside Apple's download.
            // `simctl runtime delete` unmounts it but can't remove that download,
            // so the space stays used and the runtime is mounted again at the
            // next restart (#165). Offering it would promise space it can't free.
            if Self.isLegacyImage(kind: kind) {
                guard let downloadBuilds, !downloadBuilds.contains(build) else { continue }
            }
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
                deviceReach: deviceReachByBuild[build],
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
    ///
    /// `nil` when the answer names no build at all, unreadable or empty. That is
    /// "unknown", never "Xcode uses none of them": an empty set would let Xcode's
    /// own runtime be marked Safe to Clean.
    static func xcodeRuntimeBuilds(fromMatchList data: Data) -> Set<String>? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var builds: Set<String> = []
        for rawEntry in root.values {
            guard let entry = rawEntry as? [String: Any] else { continue }
            if let chosen = entry["chosenRuntimeBuild"] as? String, !chosen.isEmpty {
                builds.insert(chosen)
            }
        }
        return builds.isEmpty ? nil : builds
    }

    /// What a runtime boots, next to the other runtimes of its platform on this Mac.
    /// Apple ships some runtimes for one new device only (an iOS 27.1 that runs
    /// nothing but iPhone Duo), so a newer version is not always the one to keep.
    enum DeviceReach: Equatable {
        /// Runs only these device types while another runtime runs many.
        case only([String])
        /// The one runtime of its platform here that runs most devices; the others
        /// each run only a few.
        case onlyGeneralRuntime
    }

    /// A runtime that runs this many device types or fewer counts as made for
    /// specific devices. A general iOS runtime runs dozens.
    static let deviceSpecificMaxDeviceTypes = 3

    /// Device reach per runtime build, from `simctl list runtimes -j`, which unlike
    /// `simctl runtime list` names the device types each runtime supports. Only a
    /// platform with both kinds of runtime gets an entry.
    static func deviceReachByBuild(fromRuntimesList data: Data) -> [String: DeviceReach] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["runtimes"] as? [[String: Any]] else { return [:] }

        struct Entry { let build: String; let platform: String; let deviceNames: [String] }
        let entries: [Entry] = runtimes.compactMap { runtime in
            guard let build = runtime["buildversion"] as? String,
                  let platform = runtime["platform"] as? String,
                  let types = runtime["supportedDeviceTypes"] as? [[String: Any]] else { return nil }
            return Entry(build: build, platform: platform, deviceNames: types.compactMap { $0["name"] as? String })
        }

        var reach: [String: DeviceReach] = [:]
        for (_, siblings) in Dictionary(grouping: entries, by: \.platform) {
            let specific = siblings.filter { $0.deviceNames.count <= deviceSpecificMaxDeviceTypes }
            let general = siblings.filter { $0.deviceNames.count > deviceSpecificMaxDeviceTypes }
            guard !specific.isEmpty, !general.isEmpty else { continue }
            for entry in specific where !entry.deviceNames.isEmpty {
                reach[entry.build] = .only(entry.deviceNames)
            }
            if general.count == 1, let only = general.first {
                reach[only.build] = .onlyGeneralRuntime
            }
        }
        return reach
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

    // MARK: - Apple's downloads

    /// Where MobileAsset keeps what it downloads, runtimes included. Purge only
    /// reads here: the downloads are Apple's to remove.
    static let mobileAssetRoot = URL(fileURLWithPath: "/System/Library/AssetsV2", isDirectory: true)

    /// One runtime download, an `<id>.asset` folder under AssetsV2.
    struct Download: Equatable, Sendable {
        let build: String
        let folder: URL
    }

    /// Every runtime download under `root`, one `com_apple_MobileAsset_<platform>SimulatorRuntime`
    /// folder per platform, with the build its Info.plist names. Needs no admin rights.
    ///
    /// `nil` when a runtime folder or an asset's Info.plist can't be read. That is
    /// "unknown", never "no download". A Mac without AssetsV2 has none.
    static func downloads(in root: URL = mobileAssetRoot) -> [Download]? {
        let fileManager = FileManager.default
        let platformFolders: [URL]
        do {
            platformFolders = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter {
                    let name = $0.lastPathComponent
                    return name.hasPrefix("com_apple_MobileAsset_") && name.hasSuffix("SimulatorRuntime")
                }
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            return nil
        }

        var found: [Download] = []
        for platformFolder in platformFolders {
            guard let assets = try? fileManager.contentsOfDirectory(at: platformFolder, includingPropertiesForKeys: nil) else {
                return nil
            }
            for asset in assets where asset.pathExtension == "asset" {
                guard let data = try? Data(contentsOf: asset.appendingPathComponent("Info.plist")),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let properties = plist["MobileAssetProperties"] as? [String: Any],
                      let build = properties["Build"] as? String, !build.isEmpty
                else { return nil }
                found.append(Download(build: build, folder: asset))
            }
        }
        return found
    }

    // MARK: - Safety

    /// Always Check First. Safe means Clean Safe Items and scheduled cleans take the
    /// item without asking, and they only move things to the Trash, while a runtime
    /// is removed for good (#136). The explanation says whether anything uses it, so
    /// the user can still tell an orphan from one in use.
    static func safetyInfo(
        platformName: String,
        version: String,
        state: String,
        sizeBytes: Int64,
        lastUsedAt: Date?,
        deviceCount: Int?,
        isXcodeDefault: Bool?,
        deviceReach: DeviceReach? = nil,
        now: Date = Date()
    ) -> SafetyInfo {
        let base = usageSafetyInfo(
            platformName: platformName,
            version: version,
            state: state,
            sizeBytes: sizeBytes,
            lastUsedAt: lastUsedAt,
            deviceCount: deviceCount,
            isXcodeDefault: isXcodeDefault,
            now: now
        )
        // Leads the explanation: which runtime boots which devices is what decides
        // the one to keep, more than the version number or how many simulators
        // use it today.
        let reach: String
        switch deviceReach {
        case .only(let names):
            let devices = ListFormatter.localizedString(byJoining: names)
            reach = String(localized: "Only runs \(devices) simulators. \(base.explanation)")
        case .onlyGeneralRuntime:
            reach = String(localized: "The only \(platformName) runtime here that runs most devices. \(base.explanation)")
        case nil:
            return base
        }
        return SafetyInfo(
            level: base.level,
            headline: base.headline,
            explanation: reach,
            recoverySteps: base.recoverySteps,
            reinstallCommand: base.reinstallCommand
        )
    }

    private static func usageSafetyInfo(
        platformName: String,
        version: String,
        state: String,
        sizeBytes: Int64,
        lastUsedAt: Date?,
        deviceCount: Int?,
        isXcodeDefault: Bool?,
        now: Date
    ) -> SafetyInfo {
        let headline = String(localized: "\(platformName) \(version) Runtime")
        // Not a trash move: the only way back is Apple's download.
        let cost = String(localized: "Xcode downloads it again (\(formatBytes(sizeBytes))) if a simulator needs it.")

        // Each explanation is one localized sentence with the cost at the end, the
        // same shape as the simulator device rows, so translations can drop the
        // space English puts between sentences.
        func info(_ explanation: String) -> SafetyInfo {
            SafetyInfo(
                level: .medium,
                headline: headline,
                explanation: explanation,
                recoverySteps: "",
                reinstallCommand: nil
            )
        }

        // `Unusable` is CoreSimulator's own verdict that the image cannot boot.
        // Anything else that is not `Ready` is in flight (staging, mounting,
        // unmounting).
        if state == "Unusable" {
            return info(String(localized: "Xcode can no longer use this runtime. \(cost)"))
        }
        if !state.isEmpty, state != "Ready" {
            return info(String(localized: "Xcode lists it as \(state.lowercased()). \(cost)"))
        }
        guard let isXcodeDefault else {
            return info(String(localized: "Could not check whether Xcode uses it for new simulators. \(cost)"))
        }
        if isXcodeDefault {
            return info(String(localized: "Xcode creates new simulators on this runtime. \(cost)"))
        }
        guard let deviceCount else {
            return info(String(localized: "Could not check which simulators use it. \(cost)"))
        }
        if deviceCount == 1 {
            return info(String(localized: "1 simulator uses it. \(cost)"))
        }
        if deviceCount > 1 {
            return info(String(localized: "\(deviceCount) simulators use it. \(cost)"))
        }

        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        guard let lastUsedAt else {
            return info(String(localized: "No simulator uses it. Last use unknown. \(cost)"))
        }
        if lastUsedAt >= thirtyDaysAgo {
            return info(String(localized: "No simulator uses it, but it was used in the last month. \(cost)"))
        }
        let monthsAgo = Calendar.current.dateComponents([.month], from: lastUsedAt, to: now).month ?? 0
        if monthsAgo < 1 {
            return info(String(localized: "No simulator uses it. Last used over a month ago. \(cost)"))
        }
        if monthsAgo == 1 {
            return info(String(localized: "No simulator uses it. Last used 1 month ago. \(cost)"))
        }
        return info(String(localized: "No simulator uses it. Last used \(monthsAgo) months ago. \(cost)"))
    }
}

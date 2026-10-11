import CryptoKit
import Foundation

/// The configuration profile that keeps removed models from downloading again
/// (macOS 27). It forces `DownloadServerBaseURLOverride-<assetType>` in
/// com.apple.MobileAsset to a dead loopback URL, which mobileassetd reads from
/// /Library/Managed Preferences (technique from pared). It holds nothing else,
/// and removing it is the whole undo.
enum Profile {
    static let identifier = "io.getpurge.spike.apple-intelligence-models"
    static let domain = "com.apple.MobileAsset"
    static let keyPrefix = "DownloadServerBaseURLOverride-"
    static let blockedURL = "https://127.0.0.1:9/purge-blocked/"
    static let managedPreferences = "/Library/Managed Preferences/com.apple.MobileAsset.plist"
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/Purge Apple Intelligence Models.mobileconfig")

    static func key(for assetType: String) -> String { keyPrefix + assetType }

    /// The asset types a removal of `sets` blocks: each set's own type, which is
    /// what was released. The download-only dependencies a set lists for
    /// Download again were never removed, so they are left alone (pared and
    /// RemoveMacAI block the same five types).
    static func blockedTypes(for sets: [ModelSet]) -> [String] {
        var types: [String] = []
        for set in sets where !types.contains(set.assetType) {
            types.append(set.assetType)
        }
        return types
    }

    static func data(blocking types: [String]) throws -> Data {
        var settings: [String: Any] = [:]
        for type in types { settings[key(for: type)] = blockedURL }
        let payloadID = identifier + ".mobileasset"
        let payload: [String: Any] = [
            "PayloadType": "com.apple.ManagedClient.preferences",
            "PayloadVersion": 1,
            "PayloadIdentifier": payloadID,
            "PayloadUUID": uuid(payloadID),
            "PayloadDisplayName": "Block Apple Intelligence model downloads",
            "PayloadContent": [domain: ["Forced": [["mcx_preference_settings": settings]]]],
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": uuid(identifier),
            "PayloadDisplayName": "Purge: Apple Intelligence models removed",
            "PayloadDescription":
                "Stops macOS downloading the Apple Intelligence models Purge removed. Remove this profile, or choose Download again in Purge, to let them come back.",
            "PayloadOrganization": "Purge",
            "PayloadScope": "System",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [payload],
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// A stable name-based UUID per identifier, so installing a new version
    /// replaces the old one instead of adding a second profile.
    static func uuid(_ name: String) -> String {
        var bytes = Array(Insecure.SHA1.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }

    /// The asset types the installed managed preferences currently block with
    /// the spike's URL. Empty when no profile is in force. Read from the file
    /// mobileassetd itself reads, so it says what the daemon sees.
    static func installedBlocks() -> [String] {
        guard let data = FileManager.default.contents(atPath: managedPreferences),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        return plist.compactMap { key, value -> String? in
            guard key.hasPrefix(keyPrefix), value as? String == blockedURL else { return nil }
            return String(key.dropFirst(keyPrefix.count))
        }.sorted()
    }

    /// Keys in the managed preferences that block downloads with some other
    /// URL: an MDM or another tool, which the spike must not claim as its own.
    static func foreignBlocks() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: managedPreferences),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in plist where key.hasPrefix(keyPrefix) {
            if let url = value as? String, url != blockedURL { out[String(key.dropFirst(keyPrefix.count))] = url }
        }
        return out
    }

    /// Writes the profile and opens it so System Settings offers to install it.
    static func present(blocking types: [String]) throws {
        try data(blocking: types).write(to: file)
        Shell.open(file.path)
        Thread.sleep(forTimeInterval: 1)
        Shell.openSettings(Shell.profilesPane)
    }
}

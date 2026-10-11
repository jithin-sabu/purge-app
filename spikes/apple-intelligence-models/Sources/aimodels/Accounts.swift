import Foundation

/// Other accounts on this Mac and whether they use Apple Intelligence. The
/// models are shared by every account, so the confirmation names them
/// (purge-app#133). Reads each account's opt-in preference file; another
/// account's Library is not readable without sudo, which reads as unknown.
struct Account {
    enum Usage: String {
        case usesAppleIntelligence = "uses Apple Intelligence"
        case optedOut = "has it off"
        case neverChose = "never turned it on"
        case unknown = "unknown: preferences not readable, run with sudo to check"
    }

    let name: String
    let uid: Int
    let home: String
    let usage: Usage
    let isCurrent: Bool
}

enum Accounts {
    static let optInPlist = "Library/Preferences/com.apple.CloudSubscriptionFeatures.optIn.plist"

    static func all() -> [Account] {
        guard let listing = Shell.run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"], timeout: 20), listing.ok
        else { return [] }
        let currentUID = Int(getuid())
        var accounts: [Account] = []
        for line in listing.stdoutText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let uid = Int(parts.last!), uid >= 500 else { continue }
            let name = String(parts[0])
            let home = homeDirectory(of: name) ?? "/Users/\(name)"
            accounts.append(Account(name: name, uid: uid, home: home,
                                    usage: usage(home: home), isCurrent: uid == currentUID))
        }
        return accounts.sorted { $0.name < $1.name }
    }

    static func homeDirectory(of name: String) -> String? {
        guard let result = Shell.run("/usr/bin/dscl", [".", "-read", "/Users/\(name)", "NFSHomeDirectory"], timeout: 20),
              result.ok
        else { return nil }
        for line in result.stdoutText.split(whereSeparator: \.isNewline) where line.hasPrefix("NFSHomeDirectory:") {
            return line.dropFirst("NFSHomeDirectory:".count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// With no Apple Account signed in the key is `device`; signed in, it is the
    /// account's DSID. Any true boolean counts as using it. macOS 27 is also
    /// reported to record an opt-out under `opted_out_buddy`. All of this is
    /// from Mac admin write-ups, not Apple, and is one of the spike's checks.
    static func usage(home: String) -> Account.Usage {
        let path = home + "/" + optInPlist
        guard FileManager.default.isReadableFile(atPath: path) else {
            return FileManager.default.isReadableFile(atPath: home + "/Library/Preferences") ? .neverChose : .unknown
        }
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return .unknown }
        var sawTrue = false
        var sawFalse = false
        for (key, value) in plist {
            guard let flag = value as? Bool else { continue }
            if key.lowercased().contains("opt_out") || key.lowercased().contains("opted_out") {
                if flag { sawFalse = true }
                continue
            }
            if flag { sawTrue = true } else { sawFalse = true }
        }
        if sawTrue { return .usesAppleIntelligence }
        return sawFalse ? .optedOut : .neverChose
    }
}

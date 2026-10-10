import Foundation

/// The read-only check that must pass before a purge is sent: macOS has to
/// honour the service filter, or the same call purges every service.
enum CacheDeleteCheck {
    static let definitions = "/System/Library/CacheDelete"
    static let defaultService = "com.apple.mobileassetd.cache-delete"
    static let defaultUrgency = 3

    /// The CACHE_DELETE_ID of every service `deleted` knows, from its definitions.
    static func knownServices() -> [String: String] {
        var ids: [String: String] = [:]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: definitions) else { return ids }
        for name in names where name.hasSuffix(".plist") {
            let path = definitions + "/" + name
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            else { continue }
            var found: String?
            Descriptors.walk(plist, at: "") { _, key, value in
                if key == "CACHE_DELETE_ID", found == nil, let id = value as? String { found = id }
            }
            ids[name] = found ?? "(no CACHE_DELETE_ID)"
        }
        return ids
    }

    static func request(service: String?, urgency: Int, amount: Int64?) -> [String: Any] {
        var info: [String: Any] = ["CACHE_DELETE_VOLUME": "/", "CACHE_DELETE_URGENCY_LIMIT": urgency]
        if let amount { info["CACHE_DELETE_AMOUNT"] = amount }
        if let service { info["CACHE_DELETE_SERVICES"] = [service] }
        return info
    }

    struct Verdict {
        let honoured: Bool
        let reason: String
        let filteredAmount: Int64?
        let unfilteredAmount: Int64?
    }

    /// The first number under a key that names an amount, searching the whole reply.
    static func amount(in reply: [String: Any]) -> Int64? {
        var found: Int64?
        var fallback: Int64?
        Descriptors.walk(reply, at: "") { _, key, value in
            guard let number = value as? NSNumber, !(value is Bool) else { return }
            let upper = key.uppercased()
            if upper == "CACHE_DELETE_AMOUNT", found == nil { found = number.int64Value }
            if fallback == nil, upper.contains("AMOUNT") || upper.contains("PURGEABLE") { fallback = number.int64Value }
        }
        return found ?? fallback
    }

    /// Conservative: the purge only goes ahead when the filtered reply names no
    /// other service and reports less than the unfiltered one, or when the
    /// unfiltered reply itself shows the filter at work. Anything else aborts.
    static func judge(filtered: [String: Any], unfiltered: [String: Any], service: String,
                      otherServices: [String]) -> Verdict {
        let filteredText = Format.json(filtered, pretty: false)
        let filteredAmount = amount(in: filtered)
        let unfilteredAmount = amount(in: unfiltered)
        let others = otherServices.filter { $0 != service && filteredText.contains($0) }
        if !others.isEmpty {
            return Verdict(honoured: false,
                           reason: "the filtered reply still names other services: " + others.joined(separator: ", "),
                           filteredAmount: filteredAmount, unfilteredAmount: unfilteredAmount)
        }
        guard let filteredAmount else {
            return Verdict(honoured: false, reason: "the filtered reply has no amount to compare",
                           filteredAmount: nil, unfilteredAmount: unfilteredAmount)
        }
        guard let unfilteredAmount else {
            return Verdict(honoured: false, reason: "the unfiltered reply has no amount to compare",
                           filteredAmount: filteredAmount, unfilteredAmount: nil)
        }
        if filteredAmount < unfilteredAmount {
            return Verdict(honoured: true,
                           reason: "the filter lowers the purgeable figure from \(Format.bytes(unfilteredAmount)) to \(Format.bytes(filteredAmount))",
                           filteredAmount: filteredAmount, unfilteredAmount: unfilteredAmount)
        }
        if unfilteredAmount == 0 && filteredAmount == 0 {
            return Verdict(honoured: false, reason: "nothing is purgeable with or without the filter, so the filter cannot be judged",
                           filteredAmount: filteredAmount, unfilteredAmount: unfilteredAmount)
        }
        return Verdict(honoured: false,
                       reason: "the same figure comes back with and without the filter (\(Format.bytes(filteredAmount))), so macOS may be ignoring it",
                       filteredAmount: filteredAmount, unfilteredAmount: unfilteredAmount)
    }
}

import Foundation

/// Throwaway child process for Purge's two private Apple Intelligence calls
/// (issue #133): releasing the model sets and asking for them again. Purge runs
/// it as `io.getpurge.assetworker <op> <json>` from its own bundle, once per
/// call, and reads one JSON object back on stdout. A changed private interface
/// crashes this process, which Purge reports as such, and never Purge itself.
///
/// Ops: `load`, `asset-type` {assetSet}, `reset` {assetSets}, `unsubscribe`
/// {subscriber, names}, `subscribe` {subscriber, subscriptions: [{name,
/// usageAliases, assetSetUsages}]}. Every op refuses what it is not given:
/// a reset with no sets is never sent, because the service reads that as all.
@main
enum PurgeAssetWorkerMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let op = arguments.first else {
            reply(["ok": false, "error": "no op"])
            return
        }
        let input: [String: Any]
        if arguments.count > 1, let data = arguments[1].data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            input = object
        } else {
            input = [:]
        }
        do {
            reply(["ok": true, "result": try perform(op, input)])
        } catch {
            reply(["ok": false, "error": describe(error)])
        }
    }

    private static func reply(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonSafe(object)) else {
            FileHandle.standardOutput.write(Data("{\"ok\":false,\"error\":\"reply could not be encoded\"}".utf8))
            return
        }
        FileHandle.standardOutput.write(data)
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? UnifiedAssetCalls.CallError { return failure.description }
        let nsError = error as NSError
        var parts = ["\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"]
        if let reason = nsError.localizedFailureReason { parts.append(reason) }
        for (key, value) in nsError.userInfo
        where key != NSLocalizedDescriptionKey && key != NSLocalizedFailureReasonErrorKey {
            parts.append("\(key): \(value)")
        }
        return parts.joined(separator: "; ")
    }

    private static func string(_ input: [String: Any], _ key: String) throws -> String {
        guard let value = input[key] as? String, !value.isEmpty else {
            throw UnifiedAssetCalls.CallError("worker input has no \(key)")
        }
        return value
    }

    private static func perform(_ op: String, _ input: [String: Any]) throws -> [String: Any] {
        switch op {
        case "load":
            try UnifiedAssetCalls.load()
            return ["available": true]

        case "asset-type":
            let set = try string(input, "assetSet")
            if let type = try UnifiedAssetCalls.assetType(forSet: set) {
                return ["assetType": type]
            }
            return ["assetType": NSNull()]

        case "reset":
            guard let sets = input["assetSets"] as? [String], !sets.isEmpty,
                  sets.allSatisfy({ !$0.isEmpty })
            else { throw UnifiedAssetCalls.CallError("refusing a reset with no asset sets") }
            try UnifiedAssetCalls.send(["Operation": "ResetAssetSets", "AssetSets": sets], timeout: 120)
            return ["reset": sets]

        case "unsubscribe":
            let subscriber = try string(input, "subscriber")
            guard let names = input["names"] as? [String], !names.isEmpty else {
                throw UnifiedAssetCalls.CallError("no subscription names")
            }
            try UnifiedAssetCalls.send([
                "Operation": "Unsubscribe", "Subscriber": subscriber, "Subscriptions": names, "UserInitiated": true,
            ], timeout: 60)
            return ["unsubscribed": names]

        case "subscribe":
            let subscriber = try string(input, "subscriber")
            guard let requests = input["subscriptions"] as? [[String: Any]], !requests.isEmpty else {
                throw UnifiedAssetCalls.CallError("no subscriptions")
            }
            var subscriptions: [AnyObject] = []
            for request in requests {
                let name = try string(request, "name")
                let usages = request["assetSetUsages"] as? [String: [String: String]] ?? [:]
                let aliases = request["usageAliases"] as? [String: String] ?? [:]
                subscriptions.append(try UnifiedAssetCalls.makeSubscription(name: name, assetSetUsages: usages, usageAliases: aliases))
            }
            try UnifiedAssetCalls.send([
                "Operation": "Subscribe", "Subscriber": subscriber, "Subscriptions": subscriptions, "UserInitiated": true,
            ], timeout: 60)
            return ["subscribed": requests.compactMap { $0["name"] as? String }]

        default:
            throw UnifiedAssetCalls.CallError("unknown op \(op)")
        }
    }

    /// JSON can hold strings, numbers, bools, arrays and dictionaries; anything
    /// else a reply carries becomes its description rather than failing the reply.
    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            var out: [String: Any] = [:]
            for (key, inner) in dictionary { out[key] = jsonSafe(inner) }
            return out
        case let array as [Any]:
            return array.map(jsonSafe)
        case is String, is NSNumber, is NSNull:
            return value
        default:
            return String(describing: value)
        }
    }
}

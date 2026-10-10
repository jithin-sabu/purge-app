import Foundation
import PrivateBridge

/// Every private call runs in a throwaway copy of this executable started with
/// `__worker <op>`. The parent sends one JSON object on stdin and reads one
/// back on stdout, so a changed signature crashes the child, not the tool,
/// and the crash is reported as such (purge-app#133).
enum Worker {
    static let flag = "__worker"

    struct Outcome {
        let ok: Bool
        let result: [String: Any]
        let error: String?
        /// The child died from a signal: the private interface changed shape.
        let crashed: Bool
        let timedOut: Bool

        var problem: String { error ?? "no error given" }
    }

    // MARK: parent side

    static func run(_ op: String, _ input: [String: Any] = [:], timeout: TimeInterval) -> Outcome {
        guard let executable = Bundle.main.executableURL else {
            return Outcome(ok: false, result: [:], error: "cannot find my own executable", crashed: false, timedOut: false)
        }
        let payload = (try? JSONSerialization.data(withJSONObject: Format.jsonSafe(input))) ?? Data("{}".utf8)
        // The child gets a little longer than the call it makes, so the call's
        // own timeout message wins over the parent's.
        guard let result = Shell.run(executable.path, [flag, op], stdin: payload, timeout: timeout + 10) else {
            return Outcome(ok: false, result: [:], error: "could not start the worker", crashed: false, timedOut: false)
        }
        if let signal = result.signal {
            let name = String(cString: strsignal(signal))
            return Outcome(ok: false, result: [:],
                           error: "the private call crashed the worker (signal \(signal), \(name)); the call style or the interface is wrong",
                           crashed: true, timedOut: false)
        }
        if result.timedOut {
            return Outcome(ok: false, result: [:], error: "the worker gave no answer in \(Int(timeout)) s",
                           crashed: false, timedOut: true)
        }
        guard let reply = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            let text = (result.stdoutText + result.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
            return Outcome(ok: false, result: [:], error: "the worker returned no JSON (exit \(result.status)): \(text)",
                           crashed: false, timedOut: false)
        }
        let ok = reply["ok"] as? Bool ?? false
        return Outcome(ok: ok, result: reply["result"] as? [String: Any] ?? [:],
                       error: reply["error"] as? String, crashed: false, timedOut: false)
    }

    // MARK: child side

    static func serve(op: String) -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let input = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let reply: [String: Any]
        do {
            reply = ["ok": true, "result": Format.jsonSafe(try perform(op, input))]
        } catch {
            reply = ["ok": false, "error": describe(error)]
        }
        if let out = try? JSONSerialization.data(withJSONObject: reply) {
            FileHandle.standardOutput.write(out)
        }
        exit(0)
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "io.getpurge.spike.aimodels" || error is Failure {
            return nsError.localizedDescription
        }
        var parts = ["\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"]
        if let reason = nsError.localizedFailureReason { parts.append("reason: \(reason)") }
        for (key, value) in nsError.userInfo where key != NSLocalizedDescriptionKey && key != NSLocalizedFailureReasonErrorKey {
            parts.append("\(key): \(value)")
        }
        return parts.joined(separator: "; ")
    }

    private static func thrown(_ error: NSError?, _ fallback: String) -> Error {
        if let error { return error }
        return Failure(fallback)
    }

    private static func string(_ input: [String: Any], _ key: String) throws -> String {
        guard let value = input[key] as? String, !value.isEmpty else { throw Failure("worker input has no \(key)") }
        return value
    }

    private static func perform(_ op: String, _ input: [String: Any]) throws -> [String: Any] {
        switch op {
        case "uaf-load":
            return ["available": PBLoadUnifiedAssets()]

        case "uaf-asset-type":
            guard PBLoadUnifiedAssets() else { throw Failure("UnifiedAssetFramework is missing") }
            let set = try string(input, "assetSet")
            return ["assetType": PBAssetType(set) ?? NSNull()]

        case "uaf-bytes":
            guard PBLoadUnifiedAssets() else { throw Failure("UnifiedAssetFramework is missing") }
            let set = try string(input, "assetSet")
            var error: NSError?
            guard let bytes = PBDownloadedFilesystemBytes(set, &error) else { throw thrown(error, "no bytes returned") }
            return ["bytes": bytes]

        case "uaf-inventory":
            guard PBLoadUnifiedAssets() else { throw Failure("UnifiedAssetFramework is missing") }
            var error: NSError?
            guard let inventory = PBAssetInventory(&error) else { throw thrown(error, "no inventory returned") }
            return ["inventory": inventory]

        case "uaf-check":
            // pared's read-only validation: a reset naming a set that does not
            // exist reaches the handler and comes back "Could not get config".
            // Nothing real is named, so nothing is removed.
            guard PBLoadUnifiedAssets() else { throw Failure("UnifiedAssetFramework is missing") }
            let target = "io.getpurge.spike.nonexistent.readonly-validation"
            var error: NSError?
            let sent = PBSendAssetOperation(["Operation": "ResetAssetSets", "AssetSets": [target]], 45, &error)
            if sent { return ["reachedHandler": false, "detail": "the service accepted a reset for a set that does not exist"] }
            let nested = error?.userInfo[target] as? NSError
            let reached = error?.domain == "com.apple.UnifiedAssetFramework" && error?.code == -1
                && nested?.localizedFailureReason == "Could not get config"
            return ["reachedHandler": reached, "detail": error.map { describe($0) } ?? "no error returned"]

        case "uaf-reset":
            guard PBLoadUnifiedAssets() else { throw Failure("UnifiedAssetFramework is missing") }
            guard let sets = input["assetSets"] as? [String], !sets.isEmpty else {
                throw Failure("refusing a reset with no asset sets")
            }
            var error: NSError?
            guard PBSendAssetOperation(["Operation": "ResetAssetSets", "AssetSets": sets], 120, &error) else {
                throw thrown(error, "reset failed")
            }
            return ["reset": sets]

        case "uaf-unsubscribe":
            guard PBLoadUnifiedAssets() else { throw Failure("UnifiedAssetFramework is missing") }
            let subscriber = try string(input, "subscriber")
            guard let names = input["names"] as? [String], !names.isEmpty else { throw Failure("no subscription names") }
            var error: NSError?
            let config: [String: Any] = [
                "Operation": "Unsubscribe", "Subscriber": subscriber, "Subscriptions": names, "UserInitiated": true,
            ]
            guard PBSendAssetOperation(config, 60, &error) else { throw thrown(error, "unsubscribe failed") }
            return ["unsubscribed": names]

        case "uaf-subscribe":
            guard PBLoadUnifiedAssets() else { throw Failure("UnifiedAssetFramework is missing") }
            let subscriber = try string(input, "subscriber")
            guard let requests = input["subscriptions"] as? [[String: Any]], !requests.isEmpty else {
                throw Failure("no subscriptions")
            }
            var subscriptions: [Any] = []
            for request in requests {
                let name = try string(request, "name")
                let usages = request["assetSetUsages"] as? [String: [String: String]] ?? [:]
                let aliases = request["usageAliases"] as? [String: String] ?? [:]
                var error: NSError?
                guard let subscription = PBMakeSubscription(name, usages, aliases, &error) else {
                    throw thrown(error, "could not build the subscription \(name)")
                }
                subscriptions.append(subscription)
            }
            var error: NSError?
            let config: [String: Any] = [
                "Operation": "Subscribe", "Subscriber": subscriber, "Subscriptions": subscriptions, "UserInitiated": true,
            ]
            guard PBSendAssetOperation(config, 60, &error) else { throw thrown(error, "subscribe failed") }
            return ["subscribed": requests.compactMap { $0["name"] as? String }]

        case "cd-purgeable", "cd-purge":
            guard PBLoadCacheDelete() else { throw Failure("CacheDelete.framework is missing") }
            guard let info = input["info"] as? [String: Any], !info.isEmpty else { throw Failure("no CacheDelete info") }
            let style: PBCallStyle = (input["style"] as? String) == "block" ? .block : .sync
            let timeout = input["timeout"] as? Double ?? 60
            if op == "cd-purge" {
                guard let services = info["CACHE_DELETE_SERVICES"] as? [String], !services.isEmpty else {
                    throw Failure("refusing a purge with no CACHE_DELETE_SERVICES filter")
                }
            }
            var error: NSError?
            let reply = op == "cd-purge"
                ? PBCacheDeletePurgeSpace(info, style, timeout, &error)
                : PBCacheDeletePurgeableSpace(info, style, timeout, &error)
            guard let reply else { throw thrown(error, "no reply") }
            return ["reply": reply]

        default:
            throw Failure("unknown worker op \(op)")
        }
    }
}

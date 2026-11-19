import Foundation
import ObjectiveC

/// Apple's private UnifiedAssetFramework and its subscription service, reached
/// through the Objective-C runtime so nothing is linked at build time and every
/// class and selector is checked before use. Mapped by pared
/// (github.com/4evy/pared, MIT) and checked on macOS 27.0 by the spike in
/// `spikes/apple-intelligence-models`. Only the worker target compiles this.
enum UnifiedAssetCalls {
    struct CallError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static let frameworkPath =
        "/System/Library/PrivateFrameworks/UnifiedAssetFramework.framework/UnifiedAssetFramework"
    static let serviceName = "com.apple.siri.uaf.subscription.service"
    /// siriknowledged's service, which passes each operation on to `serviceName`.
    static let forwardingServiceName = "com.apple.siri.uaf.service"

    static func load() throws {
        guard dlopen(frameworkPath, RTLD_NOW) != nil else {
            throw CallError("UnifiedAssetFramework is missing on this macOS")
        }
    }

    /// Sends a message that takes no argument or one object, checking first that
    /// the receiver answers it. Nil when it does not, or the reply is not an object.
    private static func message(_ target: AnyObject, _ name: String, _ argument: Any? = nil) -> AnyObject? {
        let selector = Selector((name))
        guard target.responds(to: selector) else { return nil }
        let result: Unmanaged<AnyObject>?
        if let argument {
            result = target.perform(selector, with: argument)
        } else {
            result = target.perform(selector)
        }
        return result?.takeUnretainedValue()
    }

    private static func configurationManager() throws -> AnyObject {
        guard let managerClass = NSClassFromString("UAFConfigurationManager"),
              let manager = message(managerClass as AnyObject, "defaultManager")
        else { throw CallError("UAFConfigurationManager +defaultManager is missing") }
        return manager
    }

    /// The MobileAsset type macOS maps an asset set to, or nil when the set is
    /// unknown to this macOS. Purge compares it with its catalog before sending
    /// anything, so a renamed set is left alone.
    static func assetType(forSet name: String) throws -> String? {
        try load()
        let manager = try configurationManager()
        guard manager.responds(to: Selector(("getAssetSet:"))) else {
            throw CallError("UAFConfigurationManager -getAssetSet: is missing")
        }
        guard let set = message(manager, "getAssetSet:", name) else { return nil }
        guard set.responds(to: Selector(("autoAssetType"))) else {
            throw CallError("the asset set has no autoAssetType")
        }
        return message(set, "autoAssetType") as? String
    }

    /// The first of `candidates` that macOS accepts for the usage alias, or nil
    /// when it accepts none of them. Each is tried as a subscription holding
    /// that alias alone, through the same `isValid:error:` check every
    /// subscription already passes, so this needs nothing more from the
    /// framework. A value a release moved to `UsageAliases/Deprecated` still
    /// passes. Nil is how an alias macOS removed shows up, as
    /// `VisualGeneration.GenerativePlayground` did in 27.2 (#385). A missing
    /// class or method still throws.
    static func firstKnownValue(forAlias alias: String, candidates: [String]) throws -> String? {
        for value in candidates {
            let subscription = try newSubscription(name: "purge.aliasCheck", assetSetUsages: [:], usageAliases: [alias: value])
            if try validationError(subscription) == nil { return value }
        }
        return nil
    }

    /// Sends one operation to the subscription service and waits for its reply.
    /// `config` carries "Operation" and its arguments. Throws on a missing
    /// interface, a transport error, a timeout, or an error reply.
    ///
    /// From macOS 27.3 the subscription service takes connections only from
    /// clients Apple signed and drops Purge's. siriknowledged's service has the
    /// same interface and passes `operationWithConfig:` on unchanged, so a
    /// refused request goes out once more through it. Found by pdfux and
    /// shipped first by RemoveMacAI (github.com/omlahore/RemoveMacAI, MIT,
    /// its issue 123). Both tries share `timeout`, so the wait is no longer
    /// than before. An error reply is the service's own answer and a timeout
    /// may mean the request ran, so neither is sent again.
    static func send(_ config: [String: Any], timeout: TimeInterval) throws {
        try load()
        guard let interfaceClass = NSClassFromString("UAFXPCProxyServiceInterface"),
              let interface = message(interfaceClass as AnyObject, "defaultInterface") as? NSXPCInterface
        else { throw CallError("UAFXPCProxyServiceInterface +defaultInterface is missing") }
        let selector = Selector(("operationWithConfig:completion:"))
        // A proxy answers every selector, so the interface's protocol is what is checked.
        let described = protocol_getMethodDescription(interface.protocol, selector, true, true).name != nil
            || protocol_getMethodDescription(interface.protocol, selector, false, true).name != nil
        guard described else { throw CallError("the service interface no longer has operationWithConfig:completion:") }

        let deadline = Date().addingTimeInterval(timeout)
        do {
            try send(config, to: serviceName, interface: interface, selector: selector, timeout: timeout)
        } catch {
            let remaining = deadline.timeIntervalSinceNow
            guard isRefusedConnection(error), remaining >= 1 else { throw error }
            let refused = error as NSError
            let first = "\(serviceName) refused the connection first (\(refused.domain) \(refused.code))"
            do {
                try send(config, to: forwardingServiceName, interface: interface, selector: selector, timeout: remaining)
            } catch let second as CallError {
                throw CallError("\(second.description); \(first)")
            } catch {
                // The second error keeps its domain and code, which Purge reads,
                // and carries the first in its userInfo for the details.
                let second = error as NSError
                var userInfo = second.userInfo
                userInfo["PurgeFirstTry"] = first
                throw NSError(domain: second.domain, code: second.code, userInfo: userInfo)
            }
        }
    }

    /// Whether `error` says the connection was dropped or never made, rather
    /// than the service answering or the wait running out.
    static func isRefusedConnection(_ error: Error) -> Bool {
        guard !(error is CallError) else { return false }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSXPCConnectionInterrupted || nsError.code == NSXPCConnectionInvalid)
    }

    /// One try at one Mach service.
    private static func send(_ config: [String: Any], to service: String, interface: NSXPCInterface,
                             selector: Selector, timeout: TimeInterval) throws {
        let connection = NSXPCConnection(machServiceName: service, options: [])
        connection.remoteObjectInterface = interface
        connection.resume()

        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var finished = false
        var replyError: Error?
        let finish: (Error?) -> Void = { error in
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            replyError = error
            done.signal()
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in finish(error) } as AnyObject
        let completion: @convention(block) (NSError?) -> Void = { error in finish(error) }
        // Blocks are objects; this hands the completion over as one.
        let completionObject = unsafeBitCast(completion, to: AnyObject.self)
        // The method is `oneway void`: the returned value means nothing and is left alone.
        _ = proxy.perform(selector, with: config as NSDictionary, with: completionObject)

        let waited = done.wait(timeout: .now() + timeout)
        connection.invalidate()
        guard waited == .success else {
            throw CallError("no reply from \(service) in \(Int(timeout)) seconds; the request may still have run")
        }
        if let replyError { throw replyError }
    }

    /// A `UAFAssetSetSubscription` for a Subscribe operation, validated by macOS.
    /// Built with its initializer's implementation directly, since it takes three
    /// arguments, and checked against the configuration manager before it is sent.
    static func makeSubscription(name: String, assetSetUsages: [String: [String: String]],
                                 usageAliases: [String: String]) throws -> AnyObject {
        let subscription = try newSubscription(name: name, assetSetUsages: assetSetUsages, usageAliases: usageAliases)
        if let rejection = try validationError(subscription) { throw rejection }
        return subscription
    }

    /// A `UAFAssetSetSubscription`, not yet validated.
    private static func newSubscription(name: String, assetSetUsages: [String: [String: String]],
                                        usageAliases: [String: String]) throws -> AnyObject {
        try load()
        guard let type = NSClassFromString("UAFAssetSetSubscription") else {
            throw CallError("UAFAssetSetSubscription is missing")
        }
        guard class_conformsToProtocol(type, NSSecureCoding.self) else {
            throw CallError("UAFAssetSetSubscription is not NSSecureCoding, so it cannot cross XPC")
        }
        let initSelector = Selector(("initWithName:assetSets:usageAliases:"))
        guard let initMethod = class_getInstanceMethod(type, initSelector) else {
            throw CallError("UAFAssetSetSubscription initializer is missing")
        }
        guard let allocated = message(type as AnyObject, "alloc") else {
            throw CallError("UAFAssetSetSubscription could not be allocated")
        }
        typealias Initialize = @convention(c) (AnyObject, Selector, NSString, NSDictionary, NSDictionary) -> Unmanaged<AnyObject>?
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: Initialize.self)
        // alloc gave +1, init consumes it and returns +1.
        guard let subscription = initialize(
            allocated, initSelector, name as NSString, assetSetUsages as NSDictionary, usageAliases as NSDictionary
        )?.takeRetainedValue() else {
            throw CallError("UAFAssetSetSubscription returned nil")
        }
        return subscription
    }

    /// Why macOS rejects `subscription`, or nil when it accepts it. Throws only
    /// when the validator itself is missing.
    private static func validationError(_ subscription: AnyObject) throws -> Error? {
        let validSelector = Selector(("isValid:error:"))
        guard let validMethod = class_getInstanceMethod(type(of: subscription), validSelector) else {
            throw CallError("UAFAssetSetSubscription validator is missing")
        }
        let manager = try configurationManager()
        typealias Validate = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<AnyObject?>) -> ObjCBool
        let validate = unsafeBitCast(method_getImplementation(validMethod), to: Validate.self)
        var returnedError: AnyObject?
        let valid = validate(subscription, validSelector, manager, &returnedError).boolValue
        if let returnedError = returnedError as? NSError { return returnedError }
        guard valid else {
            let name = message(subscription, "name") as? String ?? "?"
            return CallError("macOS rejected the subscription \(name)")
        }
        return nil
    }
}

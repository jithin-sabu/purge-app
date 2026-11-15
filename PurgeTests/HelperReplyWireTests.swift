import Foundation
import Security
import Testing
@testable import Purge

/// The helper's v7 reply crosses XPC with a dictionary of failure codes (#299). XPC
/// only decodes the classes an interface allows, so this sends the reply through a
/// real connection, to an in-process listener that stands in for the helper.
@Suite("The helper's reply survives XPC")
struct HelperReplyWireTests {
    /// Answers every move with the same fixed reply.
    private final class FakeHelper: NSObject, PurgeHelperProtocol {
        func moveToTrash(paths: [String], withReply reply: @escaping ([String]) -> Void) {
            reply([])
        }

        func moveToTrashReportingOwnership(
            paths: [String],
            withReply reply: @escaping ([String], [String]) -> Void
        ) {
            reply([], [])
        }

        func moveToTrashReportingFailures(
            paths: [String],
            withReply reply: @escaping ([String], [String], [String: Int], Int) -> Void
        ) {
            reply(
                ["/Applications/Moved.app"],
                ["/Applications/Moved.app"],
                [
                    "/Applications/Locked.app": Int(EPERM),
                    "/Users/example/Desktop/Elsewhere": PurgeHelperConstants.outsideAllowedLocationsCode
                ],
                HelperMoveRefusal.notAdministrator.rawValue
            )
        }

        /// Accepts only an authorization the size of `AuthorizationExternalForm`, so
        /// the test sees whether the bytes crossed whole (#314).
        func moveToTrashWithAuthorization(
            paths: [String],
            authorization: Data,
            withReply reply: @escaping ([String], [String], [String: Int], Int) -> Void
        ) {
            let whole = authorization.count == MemoryLayout<AuthorizationExternalForm>.size
            reply(
                whole ? paths : [],
                [],
                [:],
                (whole ? HelperMoveRefusal.accepted : .approvalUnavailable).rawValue
            )
        }

        func helperVersion(withReply reply: @escaping (String) -> Void) {
            reply(PurgeHelperConstants.version)
        }
    }

    private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: PurgeHelperProtocol.self)
            connection.exportedObject = FakeHelper()
            connection.resume()
            return true
        }
    }

    private struct Reply: Sendable {
        var moved: [String] = []
        var ownershipIncomplete: [String] = []
        var failureCodes: [String: Int] = [:]
        var refusal: Int?
        var error: String?
    }

    /// The reply or the connection error, whichever comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Reply, Never>?

        init(_ continuation: CheckedContinuation<Reply, Never>) {
            self.continuation = continuation
        }

        func resume(_ reply: Reply) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: reply)
        }
    }

    @Test func aReplyCarriesFailureCodesAndTheRefusal() async throws {
        let delegate = ListenerDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: PurgeHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let reply = await withCheckedContinuation { (continuation: CheckedContinuation<Reply, Never>) in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(Reply(error: error.localizedDescription))
            } as? PurgeHelperProtocol
            guard let proxy else {
                once.resume(Reply(error: "no proxy"))
                return
            }
            proxy.moveToTrashReportingFailures(paths: ["/Applications/Locked.app"]) { moved, incomplete, codes, refusal in
                once.resume(Reply(moved: moved, ownershipIncomplete: incomplete, failureCodes: codes, refusal: refusal))
            }
        }

        #expect(reply.error == nil)
        #expect(reply.moved == ["/Applications/Moved.app"])
        #expect(reply.ownershipIncomplete == ["/Applications/Moved.app"])
        #expect(reply.failureCodes == [
            "/Applications/Locked.app": Int(EPERM),
            "/Users/example/Desktop/Elsewhere": -1
        ])
        #expect(reply.refusal.flatMap(HelperMoveRefusal.init(rawValue:)) == .notAdministrator)
    }

    /// The v8 call carries the app's authorization to the helper (#314).
    @Test func anAuthorizationCrossesWhole() async throws {
        let delegate = ListenerDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: PurgeHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let form = Data(repeating: 0x5A, count: MemoryLayout<AuthorizationExternalForm>.size)
        let reply = await withCheckedContinuation { (continuation: CheckedContinuation<Reply, Never>) in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(Reply(error: error.localizedDescription))
            } as? PurgeHelperProtocol
            guard let proxy else {
                once.resume(Reply(error: "no proxy"))
                return
            }
            proxy.moveToTrashWithAuthorization(
                paths: ["/Applications/Locked.app"],
                authorization: form
            ) { moved, incomplete, codes, refusal in
                once.resume(Reply(moved: moved, ownershipIncomplete: incomplete, failureCodes: codes, refusal: refusal))
            }
        }

        #expect(reply.error == nil)
        #expect(reply.moved == ["/Applications/Locked.app"])
        #expect(reply.refusal.flatMap(HelperMoveRefusal.init(rawValue:)) == .accepted)
    }
}

import Foundation
import Testing
@testable import Purge

/// The asset worker sends each request through `AppleIntelligenceModelRoute`
/// (#343). A reset names the model sets to release, so what matters here is
/// that a request is repeated only after a refused or dropped connection,
/// only once, and only through the second service.
@Suite("A refused Apple Intelligence request goes once through the second service, and nothing else is sent again")
struct AppleIntelligenceModelRouteTests {
    private typealias Route = AppleIntelligenceModelRoute

    /// Stands in for the worker's own refusals and its timeout, which are
    /// Swift errors.
    private struct WorkerRefusal: Error {}

    /// Plays one outcome per try, on a clock that only the tries move.
    private final class Tries {
        struct Outcome {
            var error: Error?
            var seconds: TimeInterval = 0
        }

        private(set) var services: [String] = []
        private(set) var timeouts: [TimeInterval] = []
        private var clock = Date(timeIntervalSinceReferenceDate: 0)
        private var outcomes: [Outcome]

        init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

        /// The error the route threw, or nil when the request went through.
        func send(timeout: TimeInterval) -> Error? {
            do {
                try Route.send(timeout: timeout, now: { self.clock }) { service, timeout in
                    self.services.append(service)
                    self.timeouts.append(timeout)
                    let outcome = self.outcomes.isEmpty ? Outcome() : self.outcomes.removeFirst()
                    self.clock = self.clock.addingTimeInterval(outcome.seconds)
                    if let error = outcome.error { throw error }
                }
                return nil
            } catch {
                return error
            }
        }
    }

    private func connectionError(_ code: Int) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: code)
    }

    private var lockReply: NSError {
        NSError(domain: "com.apple.UnifiedAssetFramework", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not eliminate as there are current locks"])
    }

    /// The names are Apple's. A change here is a change to where a release goes.
    @Test func theTwoServicesAreApplesAssetServices() {
        #expect(Route.subscriptionService == "com.apple.siri.uaf.subscription.service")
        #expect(Route.forwardingService == "com.apple.siri.uaf.service")
    }

    /// macOS 26 and 27.0 to 27.2: the first service takes the request, and
    /// the second is never asked.
    @Test func aRequestTheFirstServiceTakesGoesOutOnce() {
        let tries = Tries([.init()])
        #expect(tries.send(timeout: 120) == nil)
        #expect(tries.services == [Route.subscriptionService])
        #expect(tries.timeouts == [120])
    }

    /// 4097 is what macOS 27.3 answers Purge with, and 4099 is a service that
    /// could not be reached.
    @Test(arguments: [NSXPCConnectionInterrupted, NSXPCConnectionInvalid])
    func aRefusedOrDroppedConnectionGoesOnceThroughTheSecondService(code: Int) {
        let tries = Tries([.init(error: connectionError(code)), .init()])
        #expect(tries.send(timeout: 120) == nil)
        #expect(tries.services == [Route.subscriptionService, Route.forwardingService])
    }

    /// The second service is the last one. Its failure keeps its own domain
    /// and code and carries the first refusal for the details.
    @Test func nothingIsSentAThirdTime() throws {
        let tries = Tries([
            .init(error: connectionError(NSXPCConnectionInterrupted)),
            .init(error: connectionError(NSXPCConnectionInvalid)),
            .init(),
        ])
        let failure = try #require(tries.send(timeout: 120) as? Route.SecondTryFailure)
        #expect(tries.services == [Route.subscriptionService, Route.forwardingService])
        #expect(failure.firstTry
            == "com.apple.siri.uaf.subscription.service refused the connection first (NSCocoaErrorDomain 4097)")
        let reported = failure.withFirstTry
        #expect(reported.domain == NSCocoaErrorDomain)
        #expect(reported.code == NSXPCConnectionInvalid)
        #expect(reported.userInfo[Route.firstTryKey] as? String == failure.firstTry)
    }

    /// An error reply is the service's answer to this request. The lock reply
    /// is the one Purge reads, and a second service would only repeat it.
    @Test func theServicesOwnAnswerIsNeverSentAgain() throws {
        let tries = Tries([.init(error: lockReply), .init()])
        let error = try #require(tries.send(timeout: 120)) as NSError
        #expect(tries.services == [Route.subscriptionService])
        #expect(error.domain == "com.apple.UnifiedAssetFramework")
        #expect(error.code == -1)
    }

    /// A timeout may mean the request is still running, and the worker's own
    /// refusals never reached a service at all.
    @Test func aTimeoutOrTheWorkersOwnRefusalIsNeverSentAgain() {
        let tries = Tries([.init(error: WorkerRefusal(), seconds: 120), .init()])
        #expect(tries.send(timeout: 120) is WorkerRefusal)
        #expect(tries.services == [Route.subscriptionService])
        #expect(!Route.isRefusedConnection(WorkerRefusal()))
    }

    /// Only the two codes for a connection that was dropped or never made
    /// count, and only in Cocoa's domain.
    @Test func otherErrorsAreNotARefusedConnection() {
        #expect(Route.isRefusedConnection(connectionError(NSXPCConnectionInterrupted)))
        #expect(Route.isRefusedConnection(connectionError(NSXPCConnectionInvalid)))
        #expect(!Route.isRefusedConnection(connectionError(NSXPCConnectionReplyInvalid)))
        #expect(!Route.isRefusedConnection(connectionError(NSFileNoSuchFileError)))
        #expect(!Route.isRefusedConnection(NSError(domain: "com.apple.UnifiedAssetFramework", code: NSXPCConnectionInterrupted)))
        #expect(!Route.isRefusedConnection(NSError(domain: NSPOSIXErrorDomain, code: NSXPCConnectionInvalid)))

        let tries = Tries([.init(error: connectionError(NSXPCConnectionReplyInvalid)), .init()])
        #expect(tries.send(timeout: 120) != nil)
        #expect(tries.services == [Route.subscriptionService])
    }

    /// The app stops the worker ten seconds after the timeout it gave, so the
    /// two tries together must fit in one timeout.
    @Test func bothTriesShareOneTimeout() {
        let tries = Tries([.init(error: connectionError(NSXPCConnectionInterrupted), seconds: 20), .init()])
        #expect(tries.send(timeout: 60) == nil)
        #expect(tries.timeouts == [60, 40])
    }

    /// With under a second left there is no room for a reply, so the first
    /// error stands. At exactly a second the second try still runs.
    @Test func noSecondTryWithLessThanASecondLeft() throws {
        let late = Tries([.init(error: connectionError(NSXPCConnectionInterrupted), seconds: 59.5), .init()])
        let error = try #require(late.send(timeout: 60)) as NSError
        #expect(late.services == [Route.subscriptionService])
        #expect(error.domain == NSCocoaErrorDomain)
        #expect(error.code == NSXPCConnectionInterrupted)
        #expect(error.userInfo[Route.firstTryKey] == nil)

        let justInTime = Tries([.init(error: connectionError(NSXPCConnectionInterrupted), seconds: 59), .init()])
        #expect(justInTime.send(timeout: 60) == nil)
        #expect(justInTime.timeouts == [60, 1])
    }

    /// A reply from the second service is still that service's answer, so the
    /// lock reply stays a lock reply. A worker refusal on the second try, like
    /// its timeout, is handed back as it is with the first try beside it.
    @Test func aSecondServicesAnswerKeepsItsDomainAndCode() throws {
        let locked = Tries([.init(error: connectionError(NSXPCConnectionInterrupted)), .init(error: lockReply)])
        let failure = try #require(locked.send(timeout: 120) as? Route.SecondTryFailure)
        let reported = failure.withFirstTry
        #expect(reported.domain == "com.apple.UnifiedAssetFramework")
        #expect(reported.code == -1)
        #expect(reported.localizedDescription == "Could not eliminate as there are current locks")
        #expect(reported.userInfo[Route.firstTryKey] as? String == failure.firstTry)

        let timedOut = Tries([.init(error: connectionError(NSXPCConnectionInterrupted)), .init(error: WorkerRefusal())])
        let second = try #require(timedOut.send(timeout: 120) as? Route.SecondTryFailure)
        #expect(second.error is WorkerRefusal)
        #expect(second.firstTry.hasSuffix("(NSCocoaErrorDomain 4097)"))
    }
}

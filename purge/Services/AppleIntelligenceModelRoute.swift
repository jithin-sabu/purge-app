import Foundation

/// Which of Apple's two asset services a request for the Apple Intelligence
/// models goes to, and when it is sent a second time (#343).
///
/// From macOS 27.3 the subscription service takes connections only from
/// clients Apple signed and drops Purge's. siriknowledged's service has the
/// same interface and passes `operationWithConfig:` on unchanged, so a
/// refused request goes out once more through it. Found by pdfux and shipped
/// first by RemoveMacAI (github.com/omlahore/RemoveMacAI, MIT, its issue 123).
/// On macOS 27.0 siriknowledged logs each request as "proxying to
/// subscription service", and the subscription service then logs the same
/// subscriber and names it was sent.
///
/// The second try is not limited to 27.3. On any macOS it follows a refused
/// or dropped first connection, and it sends the same request, so it can
/// never name more than the first try did.
///
/// The rule is kept here, apart from the private calls in `PurgeAssetWorker/`,
/// so the unit tests can run it. The asset worker compiles this file too, so
/// it uses Foundation only.
nonisolated enum AppleIntelligenceModelRoute {
    /// assetsubscriptiond's service, which does the work.
    static let subscriptionService = "com.apple.siri.uaf.subscription.service"
    /// siriknowledged's service, which passes each operation on to `subscriptionService`.
    static let forwardingService = "com.apple.siri.uaf.service"

    /// A second try is not started with less time left than this.
    static let leastSecondsForSecondTry: TimeInterval = 1

    /// The userInfo key that carries the first refusal on a second failure.
    static let firstTryKey = "PurgeFirstTry"

    /// Both services failed. `error` is the second service's and `firstTry`
    /// says how the first refused.
    nonisolated struct SecondTryFailure: Error {
        let error: Error
        let firstTry: String

        /// The second error with its own domain and code, which Purge reads,
        /// and the first try in its userInfo for the details.
        var withFirstTry: NSError {
            let second = error as NSError
            var userInfo = second.userInfo
            userInfo[AppleIntelligenceModelRoute.firstTryKey] = firstTry
            return NSError(domain: second.domain, code: second.code, userInfo: userInfo)
        }
    }

    /// Whether `error` says the connection was dropped or never made, rather
    /// than the service answering or the wait running out. The worker's own
    /// refusals and its timeout are Swift errors, which are never in
    /// `NSCocoaErrorDomain`.
    static func isRefusedConnection(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSXPCConnectionInterrupted || nsError.code == NSXPCConnectionInvalid)
    }

    /// Runs `attempt` on the subscription service. When that connection is
    /// refused or dropped, runs it once more on the forwarding service with
    /// the time that is left, and never a third time.
    ///
    /// Both tries share `timeout`, so the wait is no longer than one try's.
    /// An error reply is the service's own answer and is not sent again. A
    /// timeout is not sent again either, because the request may still be
    /// running. A dropped connection can also mean the request ran. It is
    /// sent again all the same, because a reset, an unsubscribe and a
    /// subscribe are each safe to repeat.
    ///
    /// Throws the first error when there is no second try, and a
    /// `SecondTryFailure` when the second try fails too.
    static func send(timeout: TimeInterval, now: () -> Date = { Date() },
                     attempt: (_ service: String, _ timeout: TimeInterval) throws -> Void) throws {
        let deadline = now().addingTimeInterval(timeout)
        do {
            try attempt(subscriptionService, timeout)
        } catch {
            let remaining = deadline.timeIntervalSince(now())
            guard isRefusedConnection(error), remaining >= leastSecondsForSecondTry else { throw error }
            let refused = error as NSError
            let firstTry = "\(subscriptionService) refused the connection first (\(refused.domain) \(refused.code))"
            do {
                try attempt(forwardingService, remaining)
            } catch {
                throw SecondTryFailure(error: error, firstTry: firstTry)
            }
        }
    }
}

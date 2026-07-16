import AppKit
import Foundation

/// Sends the Apple event that asks Finder to empty the trash.
///
/// Purge never removes trash contents itself. Finder owns the trash across every
/// mounted volume and is the only thing here that permanently deletes anything.
nonisolated enum FinderTrashEmptier {
    /// Apple event status codes, spelled out because they are not surfaced as Swift
    /// constants.
    private enum AEStatus {
        /// errAEEventNotPermitted: automation consent was refused, or never granted.
        static let notPermitted: OSStatus = -1743
        /// errAEEventWouldRequireUserConsent: consent undecided and nothing asked.
        static let wouldRequireConsent: OSStatus = -1744
        /// procNotFound: the target app is not running.
        static let targetNotRunning: OSStatus = -600
        /// userCanceledErr: the user dismissed a confirmation.
        static let userCancelled: OSStatus = -128
    }

    enum Result {
        case success
        case failure(EmptyTrashFailure)
    }

    /// Blocks until Finder reports completion, so callers can trust a volume reading
    /// taken afterwards. Run this off the main actor: on first use this waits on the
    /// user answering the automation consent prompt.
    ///
    /// Sending the event is what raises that prompt. There is deliberately no
    /// `AEDeterminePermissionToAutomateTarget` pre-check here: asking it about
    /// `typeWildCard` means "may I send Finder every event", which macOS cannot put to
    /// the user as a meaningful question, so it denies outright instead of prompting.
    /// A pre-check would only save work we do not have to do anyway.
    static func emptyTrash() -> Result {
        guard let script = NSAppleScript(source: "tell application \"Finder\" to empty trash") else {
            return .failure(.finderError("Try emptying it in Finder."))
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .success }

        let code = (errorInfo[NSAppleScript.errorNumber] as? Int).map(OSStatus.init)
        switch code {
        case AEStatus.notPermitted, AEStatus.wouldRequireConsent:
            return .failure(.automationDenied)
        case AEStatus.userCancelled:
            return .failure(.cancelled)
        case AEStatus.targetNotRunning:
            return .failure(.finderError("Finder is not running."))
        default:
            NSLog("Purge: Finder empty trash failed — %@", errorInfo)
            let detail = (errorInfo[NSAppleScript.errorMessage] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let detail, !detail.isEmpty else {
                return .failure(.finderError("Try emptying it in Finder."))
            }
            return .failure(.finderError(detail))
        }
    }
}

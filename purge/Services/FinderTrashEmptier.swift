import AppKit
import Foundation

/// Sends the Apple event that asks Finder to empty the trash.
///
/// Purge never removes trash contents itself. Finder owns the trash across every
/// mounted volume and is the only thing here that permanently deletes anything.
nonisolated enum FinderTrashEmptier {
    private static let finderBundleID = "com.apple.finder"

    /// Apple event status codes, spelled out because they are not surfaced as Swift
    /// constants.
    private enum AEStatus {
        /// errAEEventNotPermitted: automation consent was refused.
        static let notPermitted: OSStatus = -1743
        /// errAEEventWouldRequireUserConsent: consent undecided and we did not ask.
        static let wouldRequireConsent: OSStatus = -1744
        /// procNotFound: the target app is not running.
        static let targetNotRunning: OSStatus = -600
        /// userCanceledErr: the user dismissed Finder's own confirmation.
        static let userCancelled: OSStatus = -128
    }

    enum Result {
        case success
        case failure(EmptyTrashFailure)
    }

    /// Blocks until Finder reports completion, so callers can trust a volume reading
    /// taken afterwards. Run this off the main actor.
    static func emptyTrash() -> Result {
        switch automationPermission() {
        case .denied:
            return .failure(.automationDenied)
        case .finderUnavailable:
            return .failure(.finderError("Finder is not running."))
        case .granted:
            break
        }

        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)

        guard let errorInfo else { return .success }

        let code = (errorInfo[NSAppleScript.errorNumber] as? Int).map(OSStatus.init)
        if code == AEStatus.notPermitted || code == AEStatus.wouldRequireConsent {
            return .failure(.automationDenied)
        }
        if code == AEStatus.userCancelled {
            return .failure(.finderError("The trash was not emptied."))
        }

        let detail = (errorInfo[NSAppleScript.errorMessage] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(.finderError(detail?.isEmpty == false ? detail! : "Try emptying it in Finder."))
    }

    private enum Permission {
        case granted
        case denied
        case finderUnavailable
    }

    /// Triggers the first-run automation consent prompt when consent has not been
    /// decided yet. Blocks on the user's answer, which is why this runs off-main.
    private static func automationPermission() -> Permission {
        var target = AEAddressDesc()
        var bundleID = finderBundleID
        let status = bundleID.withUTF8 { buffer -> OSErr in
            AECreateDesc(
                typeApplicationBundleID,
                buffer.baseAddress,
                buffer.count,
                &target
            )
        }
        guard status == noErr else { return .granted }
        defer { AEDisposeDesc(&target) }

        let permission = AEDeterminePermissionToAutomateTarget(
            &target,
            typeWildCard,
            typeWildCard,
            true
        )

        switch permission {
        case noErr:
            return .granted
        case AEStatus.notPermitted, AEStatus.wouldRequireConsent:
            return .denied
        case AEStatus.targetNotRunning:
            return .finderUnavailable
        default:
            // Unknown status: let the event itself decide rather than blocking here.
            return .granted
        }
    }
}

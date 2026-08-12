import AppKit
import CoreServices
import Foundation
import Testing
@testable import Purge

@MainActor
@Suite("LaunchContext decides when to start windowless")
struct LaunchContextTests {

    private static func makeOpenAppEvent(launchedAsLoginItem: Bool) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if launchedAsLoginItem {
            event.setParam(
                NSAppleEventDescriptor(enumCode: AEKeyword(keyAELaunchedAsLogInItem)),
                forKeyword: keyAEPropData
            )
        }
        return event
    }

    // MARK: Suppression decision

    /// Windowless launch is the narrow case. Everything else shows a window,
    /// because an app you cannot open is a far worse failure than a stray window.
    @Test(
        "Only a login launch, in menu-bar-only mode, past onboarding starts windowless",
        arguments: [
            (true, true, true, true),
            (false, true, true, false),
            (true, false, true, false),
            (true, true, false, false),
            (false, false, false, false),
            (false, true, false, false),
            (true, false, false, false),
            (false, false, true, false),
        ]
    )
    func suppressionRequiresEveryTerm(
        hidesDockIcon: Bool,
        launchedAsLoginItem: Bool,
        hasCompletedOnboarding: Bool,
        expected: Bool
    ) {
        #expect(
            LaunchContext.shouldSuppressInitialWindow(
                hidesDockIcon: hidesDockIcon,
                launchedAsLoginItem: launchedAsLoginItem,
                hasCompletedOnboarding: hasCompletedOnboarding
            ) == expected
        )
    }

    /// A fresh install that came up windowless would show a menu bar icon and no
    /// way to grant Full Disk Access.
    @Test("Onboarding is never skipped, whatever the preferences say")
    func onboardingAlwaysWins() {
        #expect(
            !LaunchContext.shouldSuppressInitialWindow(
                hidesDockIcon: true,
                launchedAsLoginItem: true,
                hasCompletedOnboarding: false
            )
        )
    }

    // MARK: Login-launch detection

    @Test("A login-item open event is recognised")
    func loginLaunchIsDetected() {
        #expect(LaunchContext.isLoginItemLaunch(event: Self.makeOpenAppEvent(launchedAsLoginItem: true)))
    }

    @Test("A plain open event is not a login launch")
    func manualLaunchIsNotALoginLaunch() {
        #expect(!LaunchContext.isLoginItemLaunch(event: Self.makeOpenAppEvent(launchedAsLoginItem: false)))
    }

    /// `currentAppleEvent` is nil outside event dispatch, and the flag is not part
    /// of the documented SMAppService contract — so "no answer" has to mean
    /// "show the window", not "assume login".
    @Test("No event at all falls back to showing the window")
    func missingEventIsNotALoginLaunch() {
        #expect(!LaunchContext.isLoginItemLaunch(event: nil))
    }

    @Test("The flag is only trusted on an open-application event")
    func flagOnAnotherEventIsIgnored() {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(enumCode: AEKeyword(keyAELaunchedAsLogInItem)),
            forKeyword: keyAEPropData
        )

        #expect(!LaunchContext.isLoginItemLaunch(event: event))
    }
}

import Foundation
import Testing
@testable import Purge

/// Cleaning these has a cost the user sees afterwards: an index to rebuild, a
/// sync to check again, history that is gone, or a sign-in. Safe rows go into
/// Clean Safe Items and scheduled cleans without asking, so these must stay Check
/// First. Spotlight shipped as Safe once, and a user's search broke until macOS
/// rebuilt the index (#10).
@Suite("Rows that cost something visible stay Check First (#10)")
struct VisibleCostTierTests {
    /// Folder names as the cache scan finds them, one per entry moved in #10.
    @Test(arguments: [
        // Index rebuilds
        "com.apple.Spotlight", "com.apple.Photos", "com.apple.mail",
        // Sync re-verification
        "CloudKit", "com.apple.bird", "com.dropbox.DropboxMacFileHelper",
        "com.google.GoogleDrive", "com.microsoft.OneDrive", "com.apple.dataaccess.dataaccessd",
        // Lost history
        "com.apple.ScreenTimeAgent", "com.apple.proactive.eventtracker",
        // Possible re-authentication
        "com.apple.appleaccountd", "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent",
        "com.1password.1password",
    ])
    func rowResolvesToCheckFirst(folderName: String) {
        // No path, so a user override on this machine cannot change the answer.
        let info = ExplanationResolver.initialSafetyForCacheFolder(folderName: folderName, friendlyHeadline: folderName)
        #expect(info.level == .medium)
    }

    /// A Spotlight folder with no entry of its own still falls to the tier list,
    /// which keeps anything under Spotlight's caches out of the one-click clean.
    @Test
    func unlistedSpotlightFolderIsCheckFirst() {
        let path = URL(fileURLWithPath: "\(DeletionSafetyPolicy.cachedHomePath)/Library/Caches/com.apple.Spotlight/PurgeTestSubfolder")
        #expect(SafetyTierList.evaluate(folderName: "PurgeTestSubfolder", path: path) == .medium)
    }
}

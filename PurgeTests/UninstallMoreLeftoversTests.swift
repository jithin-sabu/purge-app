import Foundation
import Testing
@testable import Purge

/// The leftover places added for #352: Application Scripts, Cookies and WebKit
/// in the user's Library, the three `/Library` folders macOS shares with other
/// apps, and hidden entries in every root. The match stays as strict as before,
/// and the shared folders never give up Apple's own or hidden entries.
@Suite("Uninstaller leftovers in the added locations")
struct UninstallMoreLeftoversTests {
    private let fm = FileManager.default
    private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    private func makeApp(
        name: String = "Rectangle",
        bundlePath: String = "/Applications/Rectangle.app",
        bundleID: String? = "com.knollsoft.Rectangle"
    ) -> InstalledApp {
        InstalledApp(
            name: name,
            bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
            bundleID: bundleID,
            bundleSizeBytes: 0,
            isRunning: false
        )
    }

    private func reason(_ name: String, _ category: UninstallCategory, app: InstalledApp? = nil) -> MatchReason? {
        AppUninstallScanPolicy.matchReason(forLeftoverName: name, category: category, app: app ?? makeApp())
    }

    private func eligible(_ path: String) -> Bool {
        AppUninstallScanPolicy.isEligibleForUninstallDeletion(URL(fileURLWithPath: path), home: home)
    }

    private func helperAllows(_ path: String) -> Bool {
        PurgeHelperConstants.isAllowedUninstallLocation(URL(fileURLWithPath: path), homeDirectory: home)
    }

    private func item(_ path: String, _ category: UninstallCategory, _ reason: MatchReason) -> UninstallItem {
        UninstallItem(
            path: URL(fileURLWithPath: path),
            sizeBytes: 0,
            category: category,
            safetyInfo: SafetyInfo(level: .medium, headline: "", explanation: "", recoverySteps: "", reinstallCommand: nil),
            matchReason: reason,
            isSelected: false
        )
    }

    // MARK: Roots

    @Test("The added folders are leftover roots, each with its category")
    func addedRootsAndCategories() {
        let roots = AppUninstallScanPolicy.leftoverSearchRoots(home: home)
        let categories = Dictionary(uniqueKeysWithValues: roots.map { ($0.url.standardizedFileURL.path, $0.category) })
        #expect(categories["/Users/example/Library/Application Scripts"] == .applicationScripts)
        #expect(categories["/Users/example/Library/Cookies"] == .webData)
        #expect(categories["/Users/example/Library/WebKit"] == .webData)
        #expect(categories["/Library/Caches"] == .caches)
        #expect(categories["/Library/Preferences"] == .preferences)
        #expect(categories["/Library/Logs"] == .logs)
    }

    /// A receipt is named by the installer package, and its `.bom` is the only
    /// record of what the package put outside the app bundle.
    @Test("Installer receipts are never a leftover")
    func receiptsStayOut() {
        let roots = AppUninstallScanPolicy.leftoverSearchRoots(home: home).map(\.url.standardizedFileURL.path)
        #expect(!roots.contains { $0.contains("receipts") })
        for path in ["/private/var/db/receipts/com.knollsoft.Rectangle.bom", "/var/db/receipts/com.knollsoft.Rectangle.plist"] {
            #expect(!eligible(path), "\(path)")
            #expect(!helperAllows(path), "\(path)")
        }
    }

    // MARK: Matching

    @Test("Application Scripts, Cookies and WebKit match by identifier only")
    func addedUserFoldersMatchByIdentifier() {
        #expect(reason("com.knollsoft.Rectangle", .applicationScripts) == .bundleID)
        #expect(reason("com.knollsoft.Rectangle.binarycookies", .webData) == .bundleID)
        #expect(reason("com.knollsoft.Rectangle", .webData) == .bundleID)

        // Never by display name, a longer id, or a shared vendor stem.
        #expect(reason("Rectangle", .applicationScripts) == nil)
        #expect(reason("Rectangle", .webData) == nil)
        #expect(reason("com.knollsoft.Rectangle.ShareExtension", .applicationScripts) == nil)
        #expect(reason("com.knollsoft.RectanglePro", .webData) == nil)
        #expect(reason("com.knollsoft", .webData) == nil)
        #expect(reason("Cookies.binarycookies", .webData) == nil)
        #expect(reason("Databases", .webData) == nil)
    }

    /// Cookies and WebKit also hold the system's own files under plain names.
    /// An id of one word would be paired with them (#362).
    @Test("A one-word bundle id matches nothing in Cookies or WebKit")
    func oneWordBundleIDMatchesNoWebData() {
        let cookies = makeApp(name: "Cookies", bundlePath: "/Applications/Cookies.app", bundleID: "Cookies")
        #expect(reason("Cookies.binarycookies", .webData, app: cookies) == nil)
        #expect(reason("Cookies", .webData, app: cookies) == nil)
        #expect(reason(".Cookies.binarycookies", .webData, app: cookies) == nil)
        let hsts = makeApp(name: "HSTS", bundlePath: "/Applications/HSTS.app", bundleID: "HSTS")
        #expect(reason("HSTS.plist", .webData, app: hsts) == nil)
        let databases = makeApp(name: "Databases", bundlePath: "/Applications/Databases.app", bundleID: "databases")
        #expect(reason("Databases", .webData, app: databases) == nil)
        // An id with an empty part or a space is not shaped like one either.
        #expect(reason("Cookies..binarycookies", .webData, app: makeApp(bundleID: "Cookies.")) == nil)
        #expect(reason("My App.binarycookies", .webData, app: makeApp(bundleID: "My App")) == nil)

        // Two parts are enough, as in the shared `/Library` folders.
        let spokenly = makeApp(name: "Spokenly", bundlePath: "/Applications/Spokenly.app", bundleID: "app.spokenly")
        #expect(reason("app.spokenly.binarycookies", .webData, app: spokenly) == .bundleID)
        #expect(reason("app.spokenly", .webData, app: spokenly) == .bundleID)
        // The rule is for the website-data folders only. A one-word id still
        // names its own entries where the system keeps none under that name.
        #expect(reason("Cookies", .caches, app: cookies) == .bundleID)
        #expect(reason("Cookies.plist", .preferences, app: cookies) == .bundleID)
    }

    @Test("A group's Application Scripts folder matches like its group container")
    func applicationScriptsGroupFolder() {
        #expect(reason("XYZ123ABCD.com.knollsoft.Rectangle", .applicationScripts) == .groupID)
        #expect(reason("group.com.knollsoft.Rectangle", .applicationScripts) == .groupID)
        #expect(reason("XYZ123ABCD.Rectangle", .applicationScripts) == nil)
        // The group rule stays in the two folders that hold groups.
        #expect(reason("XYZ123ABCD.com.knollsoft.Rectangle", .webData) == nil)
        #expect(reason("XYZ123ABCD.com.knollsoft.Rectangle", .caches) == nil)
    }

    @Test("A hidden entry matches by the identifier after its dot, and nothing looser")
    func hiddenEntriesMatchByIdentifierOnly() {
        #expect(reason(".com.knollsoft.Rectangle", .applicationSupport) == .bundleID)
        #expect(reason(".com.knollsoft.Rectangle.plist", .preferences) == .bundleID)
        #expect(reason(".com.knollsoft.Rectangle", .caches) == .bundleID)

        #expect(reason(".Rectangle", .applicationSupport) == nil)
        #expect(reason(".Rectangle", .logs) == nil)
        #expect(reason(".XYZ123ABCD.com.knollsoft.Rectangle", .groupContainers) == nil)
        #expect(reason(".com.knollsoft.Rectangle.helper.plist", .launchAgents) == nil)
        #expect(reason("..com.knollsoft.Rectangle", .applicationSupport) == nil)
        #expect(reason(".DS_Store", .applicationSupport) == nil)
        #expect(reason(".GlobalPreferences.plist", .preferences) == nil)

        // An app with no bundle id, even one named like the hidden entry.
        let nameless = makeApp(name: ".Rectangle", bundleID: nil)
        #expect(reason(".Rectangle", .applicationSupport, app: nameless) == nil)
    }

    // MARK: Delete gate

    @Test("The gate accepts entries in the added user folders")
    func gateAcceptsAddedUserFolders() {
        #expect(eligible("/Users/example/Library/Application Scripts/com.knollsoft.Rectangle"))
        #expect(eligible("/Users/example/Library/Cookies/com.knollsoft.Rectangle.binarycookies"))
        #expect(eligible("/Users/example/Library/WebKit/com.knollsoft.Rectangle"))
        #expect(eligible("/Users/example/Library/Application Support/.com.knollsoft.Rectangle"))

        #expect(!eligible("/Users/example/Library/Application Scripts"))
        #expect(!eligible("/Users/example/Library/Cookies"))
        #expect(!eligible("/Users/example/Library/WebKit"))
    }

    /// Paths in the `/Library` folders macOS shares with other apps, and whether
    /// one can be a leftover. The app's gate and the root helper must agree on
    /// every one.
    private static let sharedFolderCases: [(path: String, allowed: Bool)] = [
        ("/Library/Preferences/com.knollsoft.Rectangle.plist", true),
        ("/Library/Caches/com.knollsoft.Rectangle", true),
        ("/Library/Logs/com.knollsoft.Rectangle", true),
        ("/Library/Caches/app.spokenly", true),

        // What macOS names in plain words, with no identifier in the name.
        ("/Library/Logs/DiagnosticReports", false),
        ("/Library/Logs/CrashReporter", false),
        ("/Library/Logs/Bluetooth", false),
        ("/Library/Logs/WindowServer", false),
        ("/Library/Logs/Rectangle", false),
        ("/Library/Caches/ColorSync", false),
        ("/Library/Caches/Desktop Pictures", false),
        ("/Library/Caches/Desktop Pictures.v2", false),
        ("/Library/Preferences/systemmigrationd.plist", false),
        // The system's own log files and the printing system's settings.
        ("/Library/Logs/MCXTools.log", false),
        ("/Library/Logs/LKDC-setup.log", false),
        ("/Library/Preferences/org.cups.printers.plist", false),
        ("/Library/Caches/org.cups", false),
        ("/Library/Caches/com.apple", false),
        ("/Library/Caches/com..Rectangle", false),
        ("/Library/Caches/Rectangle.", false),

        // The folders themselves.
        ("/Library/Preferences", false),
        ("/Library/Caches", false),
        ("/Library/Logs", false),
        // Where macOS keeps its own settings: folders, never a `.plist`.
        ("/Library/Preferences/SystemConfiguration", false),
        ("/Library/Preferences/Audio", false),
        ("/Library/Preferences/OpenDirectory", false),
        ("/Library/Preferences/com.knollsoft.Rectangle", false),
        // Apple's own, whatever the case.
        ("/Library/Preferences/com.apple.loginwindow.plist", false),
        ("/Library/Preferences/com.apple.dt.Xcode.plist", false),
        ("/Library/Preferences/COM.APPLE.SoftwareUpdate.plist", false),
        ("/Library/Caches/com.apple.iconservices.store", false),
        ("/Library/Logs/com.apple.xpc.launchd", false),
        // Hidden entries.
        ("/Library/Preferences/.GlobalPreferences.plist", false),
        ("/Library/Preferences/.com.knollsoft.Rectangle.plist", false),
        ("/Library/Caches/.com.knollsoft.Rectangle", false),
        // Anything deeper than a direct child.
        ("/Library/Preferences/SystemConfiguration/preferences.plist", false),
        ("/Library/Preferences/Vendor/com.knollsoft.Rectangle.plist", false),
        ("/Library/Caches/com.knollsoft.Rectangle/data.db", false),
        ("/Library/Logs/Rectangle/today.log", false),

        // Other spellings of the three folders (#362). A different case is not
        // a folder the rule knows, so nothing under it is a leftover, even
        // where the disk reads both spellings as the same folder.
        ("/library/preferences/com.knollsoft.Rectangle.plist", false),
        ("/library/preferences/com.apple.loginwindow.plist", false),
        ("/LIBRARY/CACHES/com.knollsoft.Rectangle", false),
        ("/Library/caches/com.knollsoft.Rectangle", false),
        ("/Library/logs/com.knollsoft.Rectangle", false),
        ("/Library/PREFERENCES/com.knollsoft.Rectangle.plist", false),
        // `..` is read as the path it leads to: a folder itself, something
        // above it, or an entry the rule refuses.
        ("/Library/Caches/com.knollsoft.Rectangle/..", false),
        ("/Library/Caches/com.knollsoft.Rectangle/../..", false),
        ("/Library/Caches/com.knollsoft.Rectangle/../ColorSync", false),
        ("/Library/Caches/../Preferences/com.apple.loginwindow.plist", false),
        ("/Library/Caches/../Preferences/SystemConfiguration", false),
        ("/Library/Logs/com.knollsoft.Rectangle/../DiagnosticReports", false),
        ("/Library/Preferences/../Preferences", false),
        ("/Library/Preferences/../../etc/hosts", false),
        // So is a trailing slash.
        ("/Library/Preferences/", false),
        ("/Library/Caches/", false),
        ("/Library/Logs/", false),
        ("/Library/Logs/DiagnosticReports/", false),
        ("/Library/Caches/com.apple.iconservices.store/", false),
        ("/Library/Preferences/SystemConfiguration/", false),
        ("/Library/Caches/com.knollsoft.Rectangle/data.db/", false),
        // A spelling that leads to an allowed entry is still that entry.
        ("/Library/Caches/com.knollsoft.Rectangle/", true),
        ("/Library/Caches/../Caches/com.knollsoft.Rectangle", true),
        ("/Library/Logs/./com.knollsoft.Rectangle", true),
    ]

    @Test("The shared /Library folders give up only a direct child that is not Apple's or hidden")
    func sharedSystemFoldersAreNarrow() {
        for (path, allowed) in Self.sharedFolderCases {
            #expect(eligible(path) == allowed, "gate: \(path)")
            #expect(helperAllows(path) == allowed, "helper: \(path)")
        }
    }

    @Test("No name-only match is offered in the shared /Library folders")
    func sharedFoldersOfferNoNameOnlyMatch() {
        for root in AppUninstallScanPolicy.leftoverSearchRoots(home: home) {
            let shared = PurgeHelperConstants.sharedSystemLeftoverRoots.contains(root.url.standardizedFileURL.path)
            #expect(AppUninstallScanPolicy.offers(.appName, in: root) == !shared, "\(root.url.path)")
            #expect(AppUninstallScanPolicy.offers(.bundleID, in: root), "\(root.url.path)")
            #expect(AppUninstallScanPolicy.offers(.groupID, in: root), "\(root.url.path)")
        }
        // An app named after a system folder still matches the name in the
        // user's Logs, where it always did, and the gate refuses the shared one.
        let bluetooth = makeApp(name: "Bluetooth", bundlePath: "/Applications/Bluetooth.app", bundleID: "com.example.bt")
        #expect(reason("Bluetooth", .logs, app: bluetooth) == .appName)
        #expect(!eligible("/Library/Logs/Bluetooth"))
        #expect(!helperAllows("/Library/Logs/Bluetooth"))
    }

    /// In `/Library/Preferences` a leftover is a settings file. A folder or a
    /// link named `com.vendor.App.plist` passes the name rule, so both gates
    /// read what is there. The read is tried here in a temporary folder, since
    /// a test must not write to `/Library`.
    @Test("A folder or a link named like a plist is not a settings file")
    func preferencesEntryMustBeARegularFile() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("purgetest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("com.vendor.App.plist")
        let folder = base.appendingPathComponent("com.vendor.Folder.plist", isDirectory: true)
        let link = base.appendingPathComponent("com.vendor.Link.plist")
        try Data([0x00]).write(to: file)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: file)

        #expect(PurgeHelperConstants.isRegularFileOrMissing(file))
        #expect(!PurgeHelperConstants.isRegularFileOrMissing(folder))
        #expect(!PurgeHelperConstants.isRegularFileOrMissing(link))
        // Nothing there, so nothing to move.
        #expect(PurgeHelperConstants.isRegularFileOrMissing(base.appendingPathComponent("com.vendor.Gone.plist")))

        // Only `/Library/Preferences` asks for a file. The name rule still comes first.
        #expect(!PurgeHelperConstants.isAllowedSharedSystemLeftoverEntry(folder, inRootAt: "/Library/Preferences"))
        #expect(!PurgeHelperConstants.isAllowedSharedSystemLeftoverEntry(link, inRootAt: "/Library/Preferences"))
        #expect(PurgeHelperConstants.isAllowedSharedSystemLeftoverEntry(file, inRootAt: "/Library/Preferences"))
        #expect(PurgeHelperConstants.isAllowedSharedSystemLeftoverEntry(folder, inRootAt: "/Library/Caches"))
        let apple = base.appendingPathComponent("com.apple.loginwindow.plist")
        try Data([0x00]).write(to: apple)
        #expect(!PurgeHelperConstants.isAllowedSharedSystemLeftoverEntry(apple, inRootAt: "/Library/Preferences"))
    }

    /// The app's gate refuses a real application bundle under a leftover root.
    /// The helper checks paths itself, so it refuses one too.
    @Test("The helper refuses a real app bundle under a leftover root")
    func helperRefusesRealAppBundleUnderALeftoverRoot() throws {
        let home = URL(fileURLWithPath: fm.temporaryDirectory.path, isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("purgetest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let bundle = caches.appendingPathComponent("com.vendor.App.app", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let namedLikeOne = caches.appendingPathComponent("com.granola.app", isDirectory: true)
        try fm.createDirectory(at: namedLikeOne, withIntermediateDirectories: true)

        #expect(PurgeHelperConstants.isRealAppBundle(bundle))
        #expect(!PurgeHelperConstants.isRealAppBundle(namedLikeOne))
        #expect(!PurgeHelperConstants.isAllowedUninstallLocation(bundle, homeDirectory: home))
        #expect(PurgeHelperConstants.isAllowedUninstallLocation(namedLikeOne, homeDirectory: home))
        // The app's gate agrees on both.
        #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(bundle, home: home))
        #expect(AppUninstallScanPolicy.isEligibleForUninstallDeletion(namedLikeOne, home: home))

        // The case of the extension changes nothing for either gate (#362).
        // The app's gate once compared it as written, so the helper alone
        // refused a bundle named `.APP`.
        let logs = home.appendingPathComponent("Library/Logs", isDirectory: true)
        for name in ["com.vendor.Loud.APP", "com.vendor.Mixed.App"] {
            let loud = logs.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: loud.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data("<plist/>".utf8).write(to: loud.appendingPathComponent("Contents/Info.plist"))
            #expect(PurgeHelperConstants.isRealAppBundle(loud), "\(name)")
            #expect(!PurgeHelperConstants.isAllowedUninstallLocation(loud, homeDirectory: home), "\(name)")
            #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(loud, home: home), "\(name)")
        }
        let loudName = logs.appendingPathComponent("com.granola.APP", isDirectory: true)
        try fm.createDirectory(at: loudName, withIntermediateDirectories: true)
        #expect(PurgeHelperConstants.isAllowedUninstallLocation(loudName, homeDirectory: home))
        #expect(AppUninstallScanPolicy.isEligibleForUninstallDeletion(loudName, home: home))
        // Deeper than a direct child, a `.APP` name is never a leftover, as a
        // `.app` one never was.
        let deep = logs.appendingPathComponent("com.vendor.Tool/Helper.APP", isDirectory: true)
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        #expect(!PurgeHelperConstants.isAllowedUninstallLocation(deep, homeDirectory: home))
        #expect(!AppUninstallScanPolicy.isEligibleForUninstallDeletion(deep, home: home))
    }

    // MARK: Helper eligibility

    /// `/Library/Caches` is `drwxrwxrwt root:admin`. An administrator can write
    /// to it, and the sticky bit still refuses the move of an entry they don't
    /// own, so asking only whether the folder is writable kept a root-owned
    /// leftover there from ever reaching the helper (#362). A test can't make a
    /// root-owned entry, so the same folder mode is made in a temporary folder
    /// and the check is asked on behalf of a user who owns neither.
    @Test("An entry someone else owns in a sticky folder needs the helper")
    func stickyFolderEntryNeedsPrivilege() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("purgetest-\(UUID().uuidString)", isDirectory: true)
        let sticky = base.appendingPathComponent("sticky", isDirectory: true)
        let plain = base.appendingPathComponent("plain", isDirectory: true)
        let locked = base.appendingPathComponent("locked", isDirectory: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: base)
        }
        var entries: [URL] = []
        for folder in [sticky, plain, locked] {
            let entry = folder.appendingPathComponent("com.vendor.App", isDirectory: true)
            try fm.createDirectory(at: entry, withIntermediateDirectories: true)
            entries.append(entry)
        }
        try fm.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: sticky.path)
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: plain.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let me = getuid()
        let someoneElse = me + 1

        // The mode of `/Library/Caches`, and neither the folder nor the entry
        // is this user's: the plain move fails, so the helper may take it.
        #expect(AppUninstallScanPolicy.moveNeedsPrivilege(entries[0], user: someoneElse))
        // The user who owns the entry, or the folder, can move it unaided.
        #expect(!AppUninstallScanPolicy.moveNeedsPrivilege(entries[0], user: me))
        #expect(!AppUninstallScanPolicy.moveNeedsPrivilege(entries[0]))
        // Root is never held by the sticky bit.
        #expect(!AppUninstallScanPolicy.moveNeedsPrivilege(entries[0], user: 0))
        // Nothing there, so nothing to hand over.
        #expect(!AppUninstallScanPolicy.moveNeedsPrivilege(sticky.appendingPathComponent("com.vendor.Gone"), user: someoneElse))

        // Without the sticky bit a writable folder gives up any entry, whoever
        // owns it, so nothing in a user-writable folder goes to the helper.
        #expect(!AppUninstallScanPolicy.moveNeedsPrivilege(entries[1], user: someoneElse))
        #expect(!AppUninstallScanPolicy.moveNeedsPrivilege(entries[1], user: me))

        // A folder that is not writable always did need it.
        #expect(AppUninstallScanPolicy.moveNeedsPrivilege(entries[2], user: me))
        #expect(AppUninstallScanPolicy.moveNeedsPrivilege(entries[2], user: someoneElse))
    }

    @Test("The shared-folder rule covers exactly the three /Library roots added")
    func sharedRootsAreTheAddedOnes() {
        #expect(Set(PurgeHelperConstants.sharedSystemLeftoverRoots)
            == ["/Library/Caches", "/Library/Preferences", "/Library/Logs"])
        let roots = Set(AppUninstallScanPolicy.leftoverSearchRoots(home: home).map(\.url.standardizedFileURL.path))
        #expect(Set(PurgeHelperConstants.sharedSystemLeftoverRoots).isSubset(of: roots))
    }

    @Test("The helper accepts a direct child of each added user folder")
    func helperAcceptsAddedUserFolders() {
        #expect(helperAllows("/Users/example/Library/Application Scripts/com.knollsoft.Rectangle"))
        #expect(helperAllows("/Users/example/Library/Cookies/com.knollsoft.Rectangle.binarycookies"))
        #expect(helperAllows("/Users/example/Library/WebKit/com.knollsoft.Rectangle"))
        #expect(!helperAllows("/Users/example/Library/WebKit/com.knollsoft.Rectangle/WebsiteData"))
        #expect(!helperAllows("/Users/other/Library/WebKit/com.knollsoft.Rectangle"))
    }

    // MARK: Shared leftovers

    @Test("A second copy of the app keeps the entries in the added folders")
    func secondCopyClaimsAddedFolders() {
        let secondCopy = makeApp(name: "Rectangle Beta", bundlePath: "/Applications/Rectangle Beta.app")
        for (name, category) in [
            ("com.knollsoft.Rectangle", UninstallCategory.applicationScripts),
            ("com.knollsoft.Rectangle.binarycookies", .webData),
            ("com.knollsoft.Rectangle", .webData),
            (".com.knollsoft.Rectangle", .applicationSupport),
        ] {
            let claimant = AppUninstallScanPolicy.claimant(
                forLeftoverName: name, category: category, ownerID: makeApp().id,
                among: [makeApp(), secondCopy], appGroupClaims: AppGroupClaims()
            )
            #expect(claimant?.id == secondCopy.id, "\(name)")
        }
    }

    /// The developer names a group, so one named after the app being removed
    /// can be a group a kept app lists (#200). Its Application Scripts folder is
    /// held back the same way as its group container.
    @Test("An app that lists a group keeps that group's Application Scripts folder")
    func keptAppClaimsGroupScriptsFolder() {
        let kept = makeApp(name: "Sibling", bundlePath: "/Applications/Sibling.app", bundleID: "com.knollsoft.Sibling")
        let group = "XYZ123ABCD.com.knollsoft.Rectangle"
        let claims = AppGroupClaims(groupsByAppID: [kept.id: [group.lowercased()]])

        let claimant = AppUninstallScanPolicy.claimant(
            forLeftoverName: group, category: .applicationScripts, ownerID: makeApp().id,
            among: [makeApp(), kept], appGroupClaims: claims
        )
        #expect(claimant?.id == kept.id)

        // A group listing never holds back an entry outside the two group folders.
        #expect(AppUninstallScanPolicy.claimant(
            forLeftoverName: group, category: .webData, ownerID: makeApp().id,
            among: [makeApp(), kept], appGroupClaims: claims
        ) == nil)
    }

    @Test("Signatures are read for a group's scripts folder, not for the app's own")
    func groupClaimsAreGatheredOnlyForGroupNamedEntries() {
        let kept = makeApp(name: "Sibling", bundlePath: "/Applications/Sibling.app", bundleID: "com.knollsoft.Sibling")
        let group = "XYZ123ABCD.com.knollsoft.Rectangle"
        let scripts = "/Users/example/Library/Application Scripts/"
        var reads = 0
        let read: (URL) -> CodeSignature? = { _ in
            reads += 1
            return CodeSignature(identifier: "com.knollsoft.Sibling", teamID: "XYZ123ABCD", appGroups: [group])
        }

        let own = item(scripts + "com.knollsoft.Rectangle", .applicationScripts, .bundleID)
        #expect(!AppUninstallScanPolicy.isNamedAfterAppGroup(own))
        #expect(AppGroupClaims.gather(for: [kept], leftovers: [own], readSignature: read, remembered: []) == AppGroupClaims())
        #expect(reads == 0)

        let groupFolder = item(scripts + group, .applicationScripts, .groupID)
        #expect(AppUninstallScanPolicy.isNamedAfterAppGroup(groupFolder))
        let claims = AppGroupClaims.gather(for: [kept], leftovers: [groupFolder], readSignature: read, remembered: [])
        #expect(claims.app(kept, claims: group))
        #expect(reads > 0)

        #expect(AppUninstallScanPolicy.isNamedAfterAppGroup(
            item("/Users/example/Library/Group Containers/" + group, .groupContainers, .groupID)
        ))
        #expect(!AppUninstallScanPolicy.isNamedAfterAppGroup(
            item("/Users/example/Library/WebKit/com.knollsoft.Rectangle", .webData, .bundleID)
        ))
    }

    @Test("A retry reads the owner's bundle id from a cookies file or a WebKit folder")
    func retryNamesTheOwnerOfWebData() {
        let cookies = URL(fileURLWithPath: "/Users/example/Library/Cookies/com.knollsoft.Rectangle.binarycookies")
        let webKit = URL(fileURLWithPath: "/Users/example/Library/WebKit/com.knollsoft.Rectangle")
        let scripts = URL(fileURLWithPath: "/Users/example/Library/Application Scripts/XYZ123ABCD.com.knollsoft.Rectangle")
        #expect(PurgeStore.bundleIDNaming(cookies, category: .webData) == "com.knollsoft.Rectangle")
        #expect(PurgeStore.bundleIDNaming(webKit, category: .webData) == "com.knollsoft.Rectangle")
        // A scripts folder gives its name: the app's own id finds the app, and
        // a group's name finds none and leaves it to the claim check.
        #expect(PurgeStore.bundleIDNaming(scripts, category: .applicationScripts) == "XYZ123ABCD.com.knollsoft.Rectangle")
        let ownScripts = URL(fileURLWithPath: "/Users/example/Library/Application Scripts/com.knollsoft.Rectangle")
        #expect(PurgeStore.bundleIDNaming(ownScripts, category: .applicationScripts) == "com.knollsoft.Rectangle")

        // A hidden row is asked about by the id after its dot.
        let lib = "/Users/example/Library/"
        #expect(PurgeStore.bundleIDNaming(URL(fileURLWithPath: lib + "Application Support/.com.knollsoft.Rectangle"), category: .applicationSupport) == "com.knollsoft.Rectangle")
        #expect(PurgeStore.bundleIDNaming(URL(fileURLWithPath: lib + "Caches/.com.knollsoft.Rectangle"), category: .caches) == "com.knollsoft.Rectangle")
        #expect(PurgeStore.bundleIDNaming(URL(fileURLWithPath: lib + "Preferences/.com.knollsoft.Rectangle.plist"), category: .preferences) == "com.knollsoft.Rectangle")
        #expect(PurgeStore.bundleIDNaming(URL(fileURLWithPath: lib + "Cookies/.com.knollsoft.Rectangle.binarycookies"), category: .webData) == "com.knollsoft.Rectangle")
        #expect(AppUninstallScanPolicy.leftoverCategory(for: cookies, home: home) == .webData)
        #expect(AppUninstallScanPolicy.leftoverCategory(for: scripts, home: home) == .applicationScripts)
    }

    // MARK: Scan

    /// macOS makes an app's Application Scripts folder empty. Files in it were
    /// added for the app to run, often written by the user.
    @Test("A scripts folder with files in it is Check First and unticked")
    func scriptsFolderWithFilesIsCheckFirst() async throws {
        let token = UUID().uuidString.prefix(8).lowercased()
        let bundleID = "com.purgetest.\(token)"
        let base = fm.temporaryDirectory.appendingPathComponent("purgetest-\(token)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let scripts = base.appendingPathComponent("home/Library/Application Scripts", isDirectory: true)
        let own = scripts.appendingPathComponent(bundleID, isDirectory: true)
        let group = scripts.appendingPathComponent("XYZ123ABCD.\(bundleID)", isDirectory: true)
        try fm.createDirectory(at: own, withIntermediateDirectories: true)
        try fm.createDirectory(at: group, withIntermediateDirectories: true)
        try Data("on run\nend run".utf8).write(to: own.appendingPathComponent("Export.scpt"))
        // Finder's own file does not make the folder the user's.
        try Data([0x00]).write(to: group.appendingPathComponent(".DS_Store"))

        #expect(AppUninstallScanPolicy.scriptsFolderHoldsFiles(own))
        #expect(!AppUninstallScanPolicy.scriptsFolderHoldsFiles(group))
        // A folder that cannot be listed is kept back too.
        #expect(AppUninstallScanPolicy.scriptsFolderHoldsFiles(scripts.appendingPathComponent("missing")))

        let bundleURL = base.appendingPathComponent("PurgeTest.app", isDirectory: true)
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let app = InstalledApp(name: "PurgeTest", bundleURL: bundleURL, bundleID: bundleID, bundleSizeBytes: 0, isRunning: false)
        let scanner = AppUninstallScanner(home: base.appendingPathComponent("home", isDirectory: true), catalog: AppDotFolderCatalog(entries: []))
        var items: [UninstallItem] = []
        for await found in scanner.leftoverStream(for: app) { items.append(found) }
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path.standardizedFileURL.path, $0) })

        let withScripts = try #require(byPath[own.standardizedFileURL.path])
        #expect(withScripts.category == .applicationScripts)
        #expect(withScripts.safetyInfo.level == .medium)
        #expect(withScripts.isSelected == false)
        #expect(withScripts.holdsAddedScripts)

        let empty = try #require(byPath[group.standardizedFileURL.path])
        #expect(empty.safetyInfo.level == .safe)
        #expect(empty.isSelected == true)
        #expect(!empty.holdsAddedScripts)

        // Read again right before the move. A folder the user approved as empty
        // stays once a script lands in it. One they ticked knowing it held
        // scripts still moves, and a folder that is gone is not held here.
        #expect(!AppUninstallScanPolicy.scriptsFolderGainedFiles(empty))
        #expect(!AppUninstallScanPolicy.scriptsFolderGainedFiles(withScripts))
        try Data("on run\nend run".utf8).write(to: group.appendingPathComponent("Late.scpt"))
        #expect(AppUninstallScanPolicy.scriptsFolderGainedFiles(empty))
        // The same answers for a failure row, which has only the path (#362).
        let testHome = base.appendingPathComponent("home", isDirectory: true)
        #expect(AppUninstallScanPolicy.scriptsFolderGainedFiles(at: group, approvedWithFiles: false, home: testHome))
        #expect(!AppUninstallScanPolicy.scriptsFolderGainedFiles(at: group, approvedWithFiles: true, home: testHome))
        #expect(!AppUninstallScanPolicy.scriptsFolderGainedFiles(at: own, approvedWithFiles: true, home: testHome))
        // Only a scripts folder is read: any other leftover is not this check's.
        let support = base.appendingPathComponent("home/Library/Application Support/\(bundleID)", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try Data([0x00]).write(to: support.appendingPathComponent("data.db"))
        #expect(!AppUninstallScanPolicy.scriptsFolderGainedFiles(at: support, approvedWithFiles: false, home: testHome))

        try fm.removeItem(at: group)
        #expect(!AppUninstallScanPolicy.scriptsFolderGainedFiles(empty))
        #expect(!AppUninstallScanPolicy.scriptsFolderGainedFiles(at: group, approvedWithFiles: false, home: testHome))
    }

    /// The scan against a temporary home (#171): what it finds in the added
    /// folders and among hidden entries, and what it leaves alone.
    @Test("The scan offers the added folders and hidden entries of the chosen app only")
    func scanFindsAddedFoldersAndHiddenEntries() async throws {
        let token = UUID().uuidString.prefix(8).lowercased()
        let bundleID = "com.purgetest.\(token)"
        let appName = "PurgeTest\(token)"
        let base = fm.temporaryDirectory.appendingPathComponent("purgetest-\(token)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let lib = base.appendingPathComponent("home/Library", isDirectory: true)

        func folder(_ relative: String) throws -> URL {
            let url = lib.appendingPathComponent(relative, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func file(_ relative: String) throws -> URL {
            let url = lib.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x00]).write(to: url)
            return url
        }

        let scripts = try folder("Application Scripts/\(bundleID)")
        let groupScripts = try folder("Application Scripts/XYZ123ABCD.\(bundleID)")
        let cookies = try file("Cookies/\(bundleID).binarycookies")
        let webKit = try folder("WebKit/\(bundleID)")
        let hiddenSupport = try folder("Application Support/.\(bundleID)")
        let hiddenPrefs = try file("Preferences/.\(bundleID).plist")

        // Left alone: another app's entries, Finder's and the system's hidden
        // files, a hidden folder that only carries the app's name, and anything
        // deeper than a direct child.
        let strangers = [
            try folder("Application Scripts/com.purgetest.other\(token)"),
            try folder("Application Scripts/\(bundleID).ShareExtension"),
            try file("Cookies/Cookies.binarycookies"),
            try file("Cookies/com.purgetest.other\(token).binarycookies"),
            try folder("WebKit/Databases"),
            try folder("WebKit/com.purgetest.other\(token)/\(bundleID)"),
            try folder("Application Support/.\(appName)"),
            try file("Application Support/.DS_Store"),
            try file("Preferences/.GlobalPreferences.plist"),
            try folder("Application Support/.com.purgetest.other\(token)"),
        ]

        let bundleURL = base.appendingPathComponent("\(appName).app", isDirectory: true)
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let app = InstalledApp(name: appName, bundleURL: bundleURL, bundleID: bundleID, bundleSizeBytes: 0, isRunning: false)

        let scanner = AppUninstallScanner(home: base.appendingPathComponent("home", isDirectory: true), catalog: AppDotFolderCatalog(entries: []))
        var items: [UninstallItem] = []
        for await found in scanner.leftoverStream(for: app) { items.append(found) }
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path.standardizedFileURL.path, $0) })

        let expected: [(URL, UninstallCategory, MatchReason)] = [
            (scripts, .applicationScripts, .bundleID),
            (groupScripts, .applicationScripts, .groupID),
            (cookies, .webData, .bundleID),
            (webKit, .webData, .bundleID),
            (hiddenSupport, .applicationSupport, .bundleID),
            (hiddenPrefs, .preferences, .bundleID),
        ]
        for (url, category, reason) in expected {
            let row = byPath[url.standardizedFileURL.path]
            #expect(row?.category == category, "\(url.lastPathComponent)")
            #expect(row?.matchReason == reason, "\(url.lastPathComponent)")
            #expect(row?.safetyInfo.level == .safe, "\(url.lastPathComponent)")
            #expect(row?.isSelected == true, "\(url.lastPathComponent)")
        }
        for url in strangers {
            #expect(byPath[url.standardizedFileURL.path] == nil, "\(url.path)")
        }
        // The bundle and the six leftovers, nothing else.
        #expect(items.count == expected.count + 1)

        // The roots listed once for many apps carry the hidden entries too.
        let listings = await scanner.listLeftoverRoots()
        var shared: [UninstallItem] = []
        for await found in scanner.leftoverStream(for: app, rootListings: listings) { shared.append(found) }
        #expect(Set(shared.map { $0.path.standardizedFileURL.path }) == Set(byPath.keys))
    }
}

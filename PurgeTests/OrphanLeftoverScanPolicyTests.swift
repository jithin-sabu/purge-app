import Foundation
import Testing
@testable import Purge

@Suite("Orphan leftover detection biases toward keeping data and never flags system paths")
struct OrphanLeftoverScanPolicyTests {

    private func index(_ ids: [String]) -> OrphanLeftoverScanPolicy.InstalledAppIndex {
        OrphanLeftoverScanPolicy.InstalledAppIndex(
            diskBundleIDs: Set(ids.map { $0.lowercased() }),
            evidence: InstalledCodeEvidence()
        )
    }

    // MARK: Ownership

    /// An installed app owns its own container.
    @Test
    func installedAppOwnsItsBundleID() {
        let installed = index(["com.vendor.app", "com.foo.bar", "org.baz.qux", "a.b", "c.d"])
        #expect(installed.owns(bundleID: "com.vendor.App"))
        #expect(installed.owns(bundleID: "com.vendor.app"))
    }

    /// A helper or extension id is owned whenever its parent app is installed, so
    /// the app's own XPC containers are never mistaken for orphans.
    @Test
    func helperIsOwnedByItsParentApp() {
        let installed = index(["com.vendor.app", "one.two", "three.four", "five.six", "seven.eight"])
        #expect(installed.owns(bundleID: "com.vendor.App.Helper"))
        #expect(installed.owns(bundleID: "com.vendor.App.QuickLook.Extension"))
    }

    /// Sharing only a vendor stem is not ownership: a genuinely removed
    /// `com.vendor.Other` is still orphaned while `com.vendor.App` stays.
    @Test
    func siblingUnderSameVendorIsNotOwned() {
        let installed = index(["com.vendor.app", "one.two", "three.four", "five.six", "seven.eight"])
        #expect(!installed.owns(bundleID: "com.vendor.Other"))
    }

    // MARK: Orphan test guards

    @Test
    func absentOwnerIsOrphan() {
        let installed = index(["com.keep.this", "one.two", "three.four", "five.six", "seven.eight"])
        #expect(OrphanLeftoverScanPolicy.isOrphan(bundleID: "com.gone.App", installed: installed))
    }

    @Test
    func installedOwnerIsNotOrphan() {
        let installed = index(["com.keep.this", "one.two", "three.four", "five.six", "seven.eight"])
        #expect(!OrphanLeftoverScanPolicy.isOrphan(bundleID: "com.keep.this", installed: installed))
    }

    /// Apple's own identifiers are never orphaned: macOS keeps system-service
    /// containers whose app never appears in /Applications.
    @Test
    func appleIdentifiersAreNeverOrphaned() {
        let installed = index(["one.two", "three.four", "five.six", "seven.eight", "nine.ten"])
        #expect(!OrphanLeftoverScanPolicy.isOrphan(bundleID: "com.apple.Safari", installed: installed))
        #expect(!OrphanLeftoverScanPolicy.isOrphan(bundleID: "com.apple.dt.Xcode", installed: installed))
    }

    @Test
    func protectedContainerIdentifiersAreNeverOrphaned() {
        let installed = index(["one.two", "three.four", "five.six", "seven.eight", "nine.ten"])
        // A protected container id (accounts/passkit family) must never surface.
        #expect(!OrphanLeftoverScanPolicy.isOrphan(bundleID: "com.apple.Accounts", installed: installed))
    }

    @Test
    func purgeIsNeverItsOwnOrphan() {
        let installed = index(["one.two", "three.four", "five.six", "seven.eight", "nine.ten"])
        #expect(!OrphanLeftoverScanPolicy.isOrphan(bundleID: "io.getpurge.app", installed: installed))
    }

    @Test
    func emptyBundleIDIsNotOrphan() {
        let installed = index(["one.two", "three.four", "five.six", "seven.eight", "nine.ten"])
        #expect(!OrphanLeftoverScanPolicy.isOrphan(bundleID: "", installed: installed))
    }

    // MARK: Completeness gate

    @Test
    func tooFewInstalledAppsLooksIncomplete() {
        #expect(!index(["a.b", "c.d"]).looksComplete)
    }

    @Test
    func enoughInstalledAppsLooksComplete() {
        #expect(index(["a.b", "c.d", "e.f", "g.h", "i.j"]).looksComplete)
    }

    /// A root that existed but failed to enumerate leaves the view degraded, so
    /// the scan must not run even with enough apps counted elsewhere.
    @Test
    func unreadableRootLooksIncomplete() {
        let degraded = OrphanLeftoverScanPolicy.InstalledAppIndex(
            diskBundleIDs: Set(["a.b", "c.d", "e.f", "g.h", "i.j"]),
            rootsReadable: false,
            evidence: InstalledCodeEvidence()
        )
        #expect(!degraded.looksComplete)
    }

    // MARK: Bundle-id extraction

    @Test
    func bundleIDNamedContainerResolvesToItself() {
        let url = URL(fileURLWithPath: "/tmp/Containers/com.vendor.App", isDirectory: true)
        #expect(OrphanLeftoverScanPolicy.owningBundleIDForContainer(
            at: url, directoryName: "com.vendor.App"
        ) == "com.vendor.App")
    }

    @Test
    func bundleIDNamedApplicationSupportFolderResolvesToItself() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("com.docker.install", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(OrphanLeftoverScanPolicy.applicationSupportBundleID(
            from: "com.docker.install",
            url: url
        ) == "com.docker.install")
    }

    @Test
    func applicationSupportRejectsHumanNamedFolders() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Docker", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(OrphanLeftoverScanPolicy.applicationSupportBundleID(
            from: "Docker",
            url: url
        ) == nil)
    }

    @Test
    func applicationSupportRejectsBundleIDNamedFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("com.vendor.App")
        try Data().write(to: url)
        #expect(OrphanLeftoverScanPolicy.applicationSupportBundleID(
            from: "com.vendor.App",
            url: url
        ) == nil)
    }

    /// A UUID-named container is not attributed by name; ownership must come from
    /// metadata (unavailable in a unit test), so this returns nil rather than
    /// treating the UUID as a bundle id.
    @Test
    func uuidNamedContainerIsNotAttributedByName() {
        let uuid = "3654A0C6-DBF7-4FCD-9CC3-3E42F9A94A5D"
        let url = URL(fileURLWithPath: "/tmp/Containers/\(uuid)", isDirectory: true)
        #expect(OrphanLeftoverScanPolicy.owningBundleIDForContainer(
            at: url, directoryName: uuid
        ) == nil)
    }

    /// The whole folder name is the app group, and the name after the team id
    /// is only shown on the row. It is never treated as a bundle id (#197).
    @Test
    func groupContainerKeepsTheWholeNameAsTheGroup() {
        let owner = OrphanLeftoverScanPolicy.groupContainerOwner(from: "6N38VWS5BX.com.vendor.App")
        #expect(owner == .appGroup("6N38VWS5BX.com.vendor.App", teamID: "6N38VWS5BX"))
        #expect(owner?.displayName == "com.vendor.App")
    }

    /// The `group.<name>` form carries no team id and is shared with installed
    /// apps and their extensions, so it is not attributed at all.
    @Test
    func groupContainerRejectsAppGroupPrefix() {
        #expect(OrphanLeftoverScanPolicy.groupContainerOwner(from: "group.com.vendor.App") == nil)
    }

    @Test
    func groupContainerRejectsUnkeyedName() {
        #expect(OrphanLeftoverScanPolicy.groupContainerOwner(from: "randomfolder") == nil)
        #expect(OrphanLeftoverScanPolicy.groupContainerOwner(from: "UBF8T346G9.ms") == nil)
    }

    /// Every team-prefixed group container comes back as an app group, whatever
    /// its name looks like, so no code path can check it against bundle ids
    /// alone again.
    @Test(arguments: [
        "HUAQ24HBR6.dev.orbstack",
        "6N38VWS5BX.ru.keepcoder.Telegram",
        "UBF8T346G9.group.com.microsoft.shared",
        "243LU875E5.groups.com.apple.podcasts"
    ])
    func groupContainersAreAlwaysAppGroups(name: String) {
        let owner = OrphanLeftoverScanPolicy.candidateOwner(
            entryName: name,
            category: .groupContainers,
            url: URL(fileURLWithPath: "/tmp/Group Containers/\(name)", isDirectory: true)
        )
        guard case .appGroup(let identifier, _) = owner else {
            Issue.record("\(name) was not read as an app group: \(String(describing: owner))")
            return
        }
        #expect(identifier == name)
    }

    @Test
    func savedStateStripsSuffix() {
        #expect(OrphanLeftoverScanPolicy.savedStateBundleID(
            from: "com.vendor.App.savedState"
        ) == "com.vendor.App")
        #expect(OrphanLeftoverScanPolicy.savedStateBundleID(from: "com.vendor.App") == nil)
    }

    @Test
    func httpStorageStripsBinaryCookiesSuffix() {
        #expect(OrphanLeftoverScanPolicy.httpStorageBundleID(
            from: "com.vendor.App.binarycookies"
        ) == "com.vendor.App")
        #expect(OrphanLeftoverScanPolicy.httpStorageBundleID(
            from: "com.vendor.App"
        ) == "com.vendor.App")
    }

    // MARK: looksLikeBundleID

    @Test
    func looksLikeBundleIDAcceptsReverseDNS() {
        #expect(OrphanLeftoverScanPolicy.looksLikeBundleID("com.vendor.App"))
        #expect(OrphanLeftoverScanPolicy.looksLikeBundleID("org.mozilla.firefox"))
    }

    @Test
    func looksLikeBundleIDRejectsUUIDAndSingleWordAndLeadingDigit() {
        #expect(!OrphanLeftoverScanPolicy.looksLikeBundleID("3654A0C6-DBF7-4FCD-9CC3-3E42F9A94A5D"))
        #expect(!OrphanLeftoverScanPolicy.looksLikeBundleID("Rectangle"))
        #expect(!OrphanLeftoverScanPolicy.looksLikeBundleID("9to5.mac"))
        #expect(!OrphanLeftoverScanPolicy.looksLikeBundleID("com..App"))
    }

    // MARK: Cross-evidence inside Library (#224)

    private func clues(preferences: [String] = [], caches: [String] = []) -> OrphanLeftoverScanPolicy.LibraryIdentifierClues {
        OrphanLeftoverScanPolicy.LibraryIdentifierClues(preferenceIDs: Set(preferences), cacheIDs: Set(caches))
    }

    private func crossOwner(
        _ name: String,
        clues: OrphanLeftoverScanPolicy.LibraryIdentifierClues,
        apps: [String] = ["com.vendor.Other"],
        names: [String] = []
    ) -> String? {
        var installed = index(apps: apps)
        installed.diskAppNames = Set(names.map { $0.lowercased() })
        return OrphanLeftoverScanPolicy.crossEvidenceOwner(folderName: name, clues: clues, installed: installed)
    }

    /// A human-named folder with nothing else in Library naming its app is not
    /// attributed, as before #224.
    @Test
    func humanNamedFolderWithoutCrossEvidenceIsNotAttributed() {
        #expect(crossOwner("Antigravity", clues: clues()) == nil)
        #expect(crossOwner("Antigravity", clues: clues(preferences: ["com.google.Keystone"])) == nil)
    }

    /// The reported case: `Application Support/Antigravity` with
    /// `Preferences/com.google.antigravity.plist`, and the app gone.
    @Test
    func matchingPreferencesPlistForAnUninstalledIDAttributesTheFolder() {
        #expect(crossOwner("Antigravity", clues: clues(preferences: ["com.google.antigravity"]))
            == "com.google.antigravity")
        #expect(crossOwner("Antigravity", clues: clues(caches: ["com.google.antigravity"]))
            == "com.google.antigravity")
        // Case-insensitive on both sides.
        #expect(crossOwner("antigravity", clues: clues(preferences: ["com.google.Antigravity"]))
            == "com.google.Antigravity")
    }

    @Test
    func matchingPlistForAnInstalledIDKeepsTheFolder() {
        #expect(crossOwner("Antigravity", clues: clues(preferences: ["com.google.antigravity"]),
                           apps: ["com.google.antigravity"]) == nil)
        // A helper id under an installed app is owned too.
        #expect(crossOwner("Helper", clues: clues(preferences: ["com.vendor.Other.Helper"])) == nil)
    }

    /// `Code` is VS Code's folder, whatever stray id ends in `.code`: an
    /// installed app with the folder's name owns it.
    @Test
    func installedAppWithTheFolderNameKeepsItDespiteAStrayID() {
        #expect(crossOwner("Code", clues: clues(preferences: ["com.gone.code"]), names: ["Code"]) == nil)
    }

    @Test
    func twoCandidateIDsAreAmbiguousAndKeepTheFolder() {
        #expect(crossOwner("Antigravity", clues: clues(
            preferences: ["com.google.antigravity"], caches: ["com.other.antigravity"]
        )) == nil)
        // The same id in both places is one clue, not two.
        #expect(crossOwner("Antigravity", clues: clues(
            preferences: ["com.google.antigravity"], caches: ["com.google.antigravity"]
        )) == "com.google.antigravity")
    }

    @Test
    func appleIdentifiersAreNeverCrossEvidence() {
        #expect(crossOwner("Safari", clues: clues(preferences: ["com.apple.Safari"])) == nil)
        #expect(crossOwner("Podcasts", clues: clues(caches: ["groups.com.apple.podcasts"])) == nil)
    }

    @Test
    func identifierNamedFoldersDoNotUseCrossEvidence() {
        #expect(crossOwner("com.vendor.App", clues: clues(preferences: ["com.vendor.App"])) == nil)
        #expect(crossOwner("", clues: clues(preferences: ["com.vendor.App"])) == nil)
    }

    /// The clues come from the plists and cache folders as they sit on disk;
    /// anything not shaped like a bundle id is ignored.
    @Test
    func cluesAreReadFromPreferencesAndCaches() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        let preferences = lib.appendingPathComponent("Preferences", isDirectory: true)
        let caches = lib.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try Data().write(to: preferences.appendingPathComponent("com.google.antigravity.plist"))
        try Data().write(to: preferences.appendingPathComponent("loginwindow.plist"))
        try Data().write(to: preferences.appendingPathComponent("com.vendor.App.notaplist"))
        try FileManager.default.createDirectory(at: caches.appendingPathComponent("com.vendor.App"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches.appendingPathComponent("Google"), withIntermediateDirectories: true)

        let clues = OrphanLeftoverScanPolicy.LibraryIdentifierClues.gather(home: home)
        #expect(clues.preferenceIDs == ["com.google.antigravity"])
        #expect(clues.cacheIDs == ["com.vendor.App"])
        #expect(clues.identifiers(endingIn: "Antigravity") == ["com.google.antigravity"])
        #expect(clues.identifiers(endingIn: "App") == ["com.vendor.App"])
        #expect(clues.identifiers(endingIn: "Google").isEmpty)
    }

    // MARK: Staleness

    @Test
    func showAllKeepsMinimumSafetyWindow() {
        let suite = ThrowawayDefaults()
        defer { suite.remove() }
        let defaults = suite.defaults
        defaults.set(DevToolsStalenessOption.showAll.rawValue, forKey: DevToolsStalenessOption.userDefaultsKey)
        let days = OrphanLeftoverScanPolicy.effectiveStaleDays(userDefaults: defaults)
        #expect(days == OrphanLeftoverScanPolicy.minimumStaleDaysFloor)
    }

    @Test
    func configuredWindowIsRespectedAboveFloor() {
        let suite = ThrowawayDefaults()
        defer { suite.remove() }
        let defaults = suite.defaults
        defaults.set(DevToolsStalenessOption.twelveMonths.rawValue, forKey: DevToolsStalenessOption.userDefaultsKey)
        #expect(OrphanLeftoverScanPolicy.effectiveStaleDays(userDefaults: defaults) == 365)
    }

    @Test
    func cutoffIsThatManyDaysBeforeNow() {
        let now = Date()
        let cutoff = OrphanLeftoverScanPolicy.staleCutoff(staleDays: 180, now: now)
        #expect(now.timeIntervalSince(cutoff) == 180 * 24 * 60 * 60)
    }

    // MARK: Safety mapping

    @Test
    func orphanSafetyIsAlwaysCheckFirst() {
        for category in UninstallCategory.allCases {
            let info = OrphanLeftoverScanPolicy.safetyInfo(appName: "Docker", category: category)
            #expect(info.level == .medium)
        }
    }

    // MARK: Ownership from installed code (#197)

    /// An index whose signatures all read, with the given claims.
    private func index(
        apps: [String],
        teams: [String] = [],
        groups: [String] = [],
        code: [String] = []
    ) -> OrphanLeftoverScanPolicy.InstalledAppIndex {
        let filler = ["one.two", "three.four", "five.six", "seven.eight", "nine.ten"]
        let ids = Set((apps + filler).map { $0.lowercased() })
        var evidence = InstalledCodeEvidence()
        evidence.teamIDs = Set(teams)
        evidence.appGroups = Set(groups.map { $0.lowercased() })
        evidence.bundleIDs = Set(code.map { $0.lowercased() })
        evidence.userAppSignaturesRead = ids.count
        return OrphanLeftoverScanPolicy.InstalledAppIndex(diskBundleIDs: ids, evidence: evidence)
    }

    private func isOrphan(
        _ name: String,
        in category: UninstallCategory,
        installed: OrphanLeftoverScanPolicy.InstalledAppIndex
    ) -> Bool {
        let url = URL(fileURLWithPath: "/tmp/OrphanLeftoverScanPolicyTests/\(name)")
        guard let owner = OrphanLeftoverScanPolicy.candidateOwner(entryName: name, category: category, url: url) else {
            Issue.record("\(name) was not attributed at all")
            return false
        }
        return OrphanLeftoverScanPolicy.isOrphan(owner, installed: installed)
    }

    /// The reported case: OrbStack's app is `dev.kdrag0n.MacVirt`, its Docker
    /// data is in `HUAQ24HBR6.dev.orbstack`. While OrbStack is installed, its
    /// signing team claims the group.
    @Test
    func orbStackDataIsKeptWhileOrbStackIsInstalled() {
        let installed = index(apps: ["dev.kdrag0n.MacVirt"], teams: ["HUAQ24HBR6"])
        #expect(!isOrphan("HUAQ24HBR6.dev.orbstack", in: .groupContainers, installed: installed))
    }

    /// Once OrbStack is gone, its data is a real leftover and is still found.
    @Test
    func orbStackDataIsFoundOnceOrbStackIsRemoved() {
        let installed = index(apps: ["com.vendor.Other"], teams: ["ZZZZZZZZZZ"])
        #expect(isOrphan("HUAQ24HBR6.dev.orbstack", in: .groupContainers, installed: installed))
    }

    /// A leftover name that differs from the installed app's bundle id, from
    /// apps users really have. Each must be kept while its app is installed.
    struct NamingMismatch: Sendable, CustomTestStringConvertible {
        let leftover: String
        let category: UninstallCategory
        var apps: [String] = []
        var teams: [String] = []
        var groups: [String] = []
        var code: [String] = []
        var testDescription: String { leftover }
    }

    @Test(arguments: [
        // A group named freely, claimed by the signing team (#197).
        NamingMismatch(leftover: "HUAQ24HBR6.dev.orbstack", category: .groupContainers,
                       apps: ["dev.kdrag0n.MacVirt"], teams: ["HUAQ24HBR6"]),
        // A suite's shared groups, claimed by any app of the team.
        NamingMismatch(leftover: "UBF8T346G9.com.microsoft.oneauth", category: .groupContainers,
                       apps: ["com.microsoft.Word"], teams: ["UBF8T346G9"]),
        NamingMismatch(leftover: "UBF8T346G9.group.com.microsoft.shared", category: .groupContainers,
                       apps: ["com.microsoft.Outlook"], teams: ["UBF8T346G9"]),
        // A group listed in an installed app's entitlements, team unknown.
        NamingMismatch(leftover: "ABCDE12345.com.indie.shared", category: .groupContainers,
                       apps: ["com.indie.Tool"], groups: ["ABCDE12345.com.indie.shared"]),
        // A group named after an extension of an installed app, no team read.
        NamingMismatch(leftover: "6N38VWS5BX.ru.keepcoder.Telegram.TelegramShare", category: .groupContainers,
                       apps: ["ru.keepcoder.Telegram"]),
        // Apple's team-prefixed group for a built-in app.
        NamingMismatch(leftover: "243LU875E5.groups.com.apple.podcasts", category: .groupContainers),
        // A framework helper inside many apps, with its own id.
        NamingMismatch(leftover: "org.sparkle-project.Downloader", category: .caches,
                       apps: ["com.vendor.App"], code: ["org.sparkle-project.Downloader"]),
        NamingMismatch(leftover: "org.sparkle-project.Downloader.binarycookies", category: .caches,
                       apps: ["com.vendor.App"], code: ["org.sparkle-project.Downloader"]),
        // An extension or login item whose id shares nothing with its app's.
        NamingMismatch(leftover: "com.othervendor.helper", category: .containers,
                       apps: ["com.vendor.App"], code: ["com.othervendor.helper"]),
        // An app running from outside the app roots.
        NamingMismatch(leftover: "com.elsewhere.App.savedState", category: .savedState,
                       code: ["com.elsewhere.App"])
    ])
    func leftoverOfInstalledCodeIsKept(_ mismatch: NamingMismatch) {
        let installed = index(
            apps: mismatch.apps,
            teams: mismatch.teams,
            groups: mismatch.groups,
            code: mismatch.code
        )
        #expect(!isOrphan(mismatch.leftover, in: mismatch.category, installed: installed))
    }

    /// The other half: the fix must not stop the scan finding real leftovers.
    @Test
    func leftoversOfRemovedAppsAreStillFound() {
        let installed = index(apps: ["com.vendor.Other"], teams: ["BBBBBBBBBB"], code: ["com.vendor.Other.Helper"])
        // Made-up ids only: the name fallback asks this Mac's Launch Services,
        // so a real app's id would pass or fail with what is installed here.
        #expect(isOrphan("SY64MV22J9.com.gone.vendor.shared", in: .groupContainers, installed: installed))
        #expect(isOrphan("AAAAAAAAAA.com.vendor.App", in: .groupContainers, installed: installed))
        #expect(isOrphan("com.gone.App", in: .containers, installed: installed))
        #expect(isOrphan("com.gone.App.savedState", in: .savedState, installed: installed))
    }

    /// When signatures cannot be read, the team and entitlement claims are near
    /// empty, so group containers are not judged at all rather than judged by
    /// name alone.
    @Test
    func groupsAreNotJudgedWithoutReadableSignatures() {
        let ids: Set<String> = ["a.b", "c.d", "e.f", "g.h", "i.j"]
        let unread = OrphanLeftoverScanPolicy.InstalledAppIndex(diskBundleIDs: ids, evidence: InstalledCodeEvidence())
        #expect(!isOrphan("SY64MV22J9.com.gone.vendor.shared", in: .groupContainers, installed: unread))

        var mostlyFailed = InstalledCodeEvidence()
        mostlyFailed.userAppSignaturesRead = 3
        mostlyFailed.userAppSignatureFailures = 2
        let degraded = OrphanLeftoverScanPolicy.InstalledAppIndex(diskBundleIDs: ids, evidence: mostlyFailed)
        #expect(!isOrphan("SY64MV22J9.com.gone.vendor.shared", in: .groupContainers, installed: degraded))

        // Bundle-id leftovers do not depend on signatures and are still judged.
        #expect(isOrphan("com.gone.App", in: .containers, installed: degraded))
    }

    @Test
    func groupsAreJudgedWhenNearlyAllSignaturesRead() {
        var evidence = InstalledCodeEvidence()
        evidence.userAppSignaturesRead = 9
        evidence.userAppSignatureFailures = 1
        #expect(evidence.canJudgeAppGroups)
        evidence.userAppSignatureFailures = 2
        #expect(!evidence.canJudgeAppGroups)
        #expect(!InstalledCodeEvidence().canJudgeAppGroups)
    }

    @Test
    func appleIdentifiersAnywhereInTheNameAreApple() {
        #expect(OrphanLeftoverScanPolicy.isAppleIdentifier("com.apple.safari"))
        #expect(OrphanLeftoverScanPolicy.isAppleIdentifier("groups.com.apple.podcasts"))
        #expect(!OrphanLeftoverScanPolicy.isAppleIdentifier("com.applesauce.app"))
    }

    // MARK: Content age

    private func setDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private let longAgo = Date().addingTimeInterval(-400 * 24 * 60 * 60)
    private var cutoff: Date { Date().addingTimeInterval(-30 * 24 * 60 * 60) }

    /// A folder's own date stays old while an app writes deeper in: OrbStack's
    /// disk image, Telegram's database. That is still in use.
    @Test
    func deepWriteMakesAnOldFolderRecent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: data.appendingPathComponent("data.img"))
        try setDate(longAgo, at: data)
        try setDate(longAgo, at: root)

        #expect(OrphanLeftoverScanPolicy.contentAge(of: root, cutoff: cutoff) == .recent)
    }

    @Test
    func untouchedTreeReportsItsNewestDate() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("store.sqlite")
        try Data("x".utf8).write(to: file)
        let newest = longAgo.addingTimeInterval(24 * 60 * 60)
        try setDate(newest, at: file)
        try setDate(longAgo, at: root)

        let age = OrphanLeftoverScanPolicy.contentAge(of: root, cutoff: cutoff)
        guard case .untouchedSince(let date) = age else {
            Issue.record("expected untouched, got \(age)")
            return
        }
        #expect(abs(date.timeIntervalSince(newest)) < 2)
    }

    /// Old sandbox containers link to Desktop and Downloads; the link's date and
    /// its target's say nothing about the app.
    @Test
    func symbolicLinksDoNotCountAsUse() throws {
        let root = try makeTemporaryDirectory()
        let target = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        try Data("fresh".utf8).write(to: target.appendingPathComponent("today.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Downloads"),
            withDestinationURL: target
        )
        try setDate(longAgo, at: root)

        guard case .untouchedSince = OrphanLeftoverScanPolicy.contentAge(of: root, cutoff: cutoff) else {
            Issue.record("a symbolic link made the folder look in use")
            return
        }
    }

    /// Opening a leftover in Finder writes `.DS_Store`, which also sets the
    /// folder's date. That must not hide the leftover, in the top folder or a
    /// subfolder. The files are written after the folders are backdated, the
    /// order it happens in.
    @Test
    func finderVisitDoesNotHideALeftover() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let store = data.appendingPathComponent("store.sqlite")
        try Data("x".utf8).write(to: store)
        try setDate(longAgo, at: store)
        try setDate(longAgo, at: data)
        try setDate(longAgo, at: root)

        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        try Data().write(to: data.appendingPathComponent(".DS_Store"))
        try Data().write(to: root.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))

        guard case .untouchedSince = OrphanLeftoverScanPolicy.contentAge(of: root, cutoff: cutoff) else {
            Issue.record("a Finder visit made the folder look in use")
            return
        }
    }

    /// Removing a file changes only its folder's date, so a recent folder date
    /// with nothing to explain it is still use.
    @Test
    func removedFileStillCountsAsUse() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("kept")
        let removed = root.appendingPathComponent("removed")
        try Data("x".utf8).write(to: kept)
        try Data("y".utf8).write(to: removed)
        try setDate(longAgo, at: kept)
        try setDate(longAgo, at: root)

        try FileManager.default.removeItem(at: removed)

        #expect(OrphanLeftoverScanPolicy.contentAge(of: root, cutoff: cutoff) == .recent)
    }

    /// An old `.DS_Store` cannot explain a folder date set long after it.
    @Test
    func olderIgnoredFileDoesNotExplainALaterChange() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("kept")
        let removed = root.appendingPathComponent("removed")
        let finder = root.appendingPathComponent(".DS_Store")
        try Data("x".utf8).write(to: kept)
        try Data("y".utf8).write(to: removed)
        try Data().write(to: finder)
        try setDate(longAgo, at: kept)
        try setDate(longAgo, at: finder)
        try setDate(longAgo, at: root)

        try FileManager.default.removeItem(at: removed)

        #expect(OrphanLeftoverScanPolicy.contentAge(of: root, cutoff: cutoff) == .recent)
    }

    /// A folder holding only ignored files has no date that says how old it is.
    @Test
    func onlyIgnoredFilesMakeTheAgeUnknown() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try setDate(longAgo, at: root)
        try Data().write(to: root.appendingPathComponent(".DS_Store"))

        #expect(OrphanLeftoverScanPolicy.contentAge(of: root, cutoff: cutoff) == .unknown)
    }

    /// Anything the walk cannot read leaves the age unknown, which the scan
    /// treats as in use.
    @Test
    func unreadableContentMakesTheAgeUnknown() throws {
        let root = try makeTemporaryDirectory()
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("inside"))
        try setDate(longAgo, at: locked.appendingPathComponent("inside"))
        try setDate(longAgo, at: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        try setDate(longAgo, at: root)

        #expect(OrphanLeftoverScanPolicy.contentAge(of: root, cutoff: cutoff) == .unknown)
    }

    @Test
    func tooManyItemsMakeTheAgeUnknown() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<5 {
            let file = root.appendingPathComponent("file\(index)")
            try Data().write(to: file)
            try setDate(longAgo, at: file)
        }
        try setDate(longAgo, at: root)

        #expect(OrphanLeftoverScanPolicy.contentAge(of: root, cutoff: cutoff, entryLimit: 2) == .unknown)
    }

    /// HTTPStorages cookie files are leftovers on their own.
    @Test
    func singleFileUsesItsOwnDate() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cookies = root.appendingPathComponent("com.gone.App.binarycookies")
        try Data("c".utf8).write(to: cookies)
        try setDate(longAgo, at: cookies)

        guard case .untouchedSince = OrphanLeftoverScanPolicy.contentAge(of: cookies, cutoff: cutoff) else {
            Issue.record("an old cookie file was not reported as untouched")
            return
        }
        try setDate(Date(), at: cookies)
        #expect(OrphanLeftoverScanPolicy.contentAge(of: cookies, cutoff: cutoff) == .recent)
    }

    // MARK: The scan's decision

    /// A leftover on disk: a data folder with one file, all backdated.
    private func makeLeftover(named name: String, in root: URL) throws -> URL {
        let leftover = root.appendingPathComponent(name, isDirectory: true)
        let data = leftover.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let image = data.appendingPathComponent("data.img")
        try Data("disk".utf8).write(to: image)
        try setDate(longAgo, at: image)
        try setDate(longAgo, at: data)
        try setDate(longAgo, at: leftover)
        return leftover
    }

    /// The function the scanner calls for every entry runs all three checks:
    /// the owner, whether installed code claims it, and the age of everything
    /// inside. Each expectation fails if one check is dropped.
    @Test
    func orphanCandidateRunsEveryCheck() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let orbStack = try makeLeftover(named: "HUAQ24HBR6.dev.orbstack", in: root)
        let cutoff = OrphanLeftoverScanPolicy.staleCutoff(staleDays: 30)
        let installed = index(apps: ["dev.kdrag0n.MacVirt"], teams: ["HUAQ24HBR6"])
        let removed = index(apps: ["com.vendor.Other"], teams: ["ZZZZZZZZZZ"])

        // Claimed by OrbStack's team: kept.
        #expect(OrphanLeftoverScanPolicy.orphanCandidate(
            at: orbStack, category: .groupContainers, installed: installed, cutoff: cutoff
        ) == nil)

        // OrbStack gone and nothing touched: offered, dated by the newest file.
        let found = OrphanLeftoverScanPolicy.orphanCandidate(
            at: orbStack, category: .groupContainers, installed: removed, cutoff: cutoff
        )
        #expect(found?.owner == .appGroup("HUAQ24HBR6.dev.orbstack", teamID: "HUAQ24HBR6"))
        if let found {
            #expect(abs(found.lastModified.timeIntervalSince(longAgo)) < 2)
        }

        // Written deep inside today: kept, though the folder's own date is old.
        try Data("disk, written today".utf8).write(to: orbStack.appendingPathComponent("data/data.img"))
        #expect(OrphanLeftoverScanPolicy.orphanCandidate(
            at: orbStack, category: .groupContainers, installed: removed, cutoff: cutoff
        ) == nil)

        // A name that says nothing about its owner: never offered.
        let unnamed = try makeLeftover(named: "randomfolder", in: root)
        #expect(OrphanLeftoverScanPolicy.orphanCandidate(
            at: unnamed, category: .groupContainers, installed: removed, cutoff: cutoff
        ) == nil)
    }

    /// The scan judges with the real index, which must carry evidence. Without
    /// it, helper ids Launch Services cannot resolve read as orphans again.
    @Test
    func realIndexIsBuiltWithEvidence() {
        let installed = OrphanLeftoverScanPolicy.makeInstalledAppIndex()
        // Apple's apps are on every Mac, and these tests run inside Purge.
        #expect(installed.evidence.bundleIDs.contains("com.apple.calculator"))
        if let host = Bundle.main.bundleIdentifier {
            #expect(installed.evidence.bundleIDs.contains(host.lowercased()))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrphanLeftoverScanPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

import Foundation
import Testing
@testable import Purge

@Suite("Installed code evidence finds every claim that keeps a leftover")
struct InstalledCodeEvidenceTests {

    // MARK: Nested code

    /// A fake app with code in each place helpers live, plus decoys the walk
    /// must skip.
    @Test
    func nestedWalkFindsHelpersExtensionsAndXPCServices() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(in: root)

        let found = Set(InstalledCodeEvidence.nestedCodeBundleURLs(in: app).map(\.lastPathComponent))
        #expect(found == ["Share.appex", "Downloader.xpc", "Fake Helper.app", "Inner.app"])
    }

    @Test
    func bundleIdentifierReadsBothPlistLayouts() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mac = root.appendingPathComponent("Mac.app")
        let iOS = root.appendingPathComponent("Phone.app")
        try makeBundle(at: mac, id: "com.vendor.mac")
        try makeBundle(at: iOS, id: "com.vendor.phone", iOSLayout: true)

        #expect(InstalledCodeEvidence.bundleIdentifier(of: mac) == "com.vendor.mac")
        #expect(InstalledCodeEvidence.bundleIdentifier(of: iOS) == "com.vendor.phone")
        #expect(InstalledCodeEvidence.bundleIdentifier(of: root.appendingPathComponent("None.app")) == nil)
    }

    // MARK: Gathering

    /// Every source adds its claims: the app and its nested code, an app
    /// running from elsewhere, and a launchd job's program and ids. Fixture
    /// sources only, so this Mac's apps play no part.
    @Test
    func gatherCollectsEverySource() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(in: root)

        let elsewhere = root.appendingPathComponent("Downloads/Elsewhere.app")
        try makeBundle(at: elsewhere, id: "com.elsewhere.App")

        let updater = root.appendingPathComponent("Support/Updater.app")
        try makeBundle(at: updater, id: "com.agent.UpdaterApp")
        try makeBundle(at: updater.appendingPathComponent("Contents/PlugIns/U.appex"), id: "com.agent.updater.ext")
        let program = updater.appendingPathComponent("Contents/MacOS/updater")
        try FileManager.default.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: program)

        let agents = root.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let job: NSDictionary = [
            "Label": "com.agent.updater",
            "Program": program.path,
            "AssociatedBundleIdentifiers": ["com.agent.Associated"]
        ]
        try job.write(to: agents.appendingPathComponent("com.agent.updater.plist"))

        let evidence = InstalledCodeEvidence.gather(
            userAppBundles: [app],
            systemAppRoots: [],
            runningApps: [.init(bundleID: "com.running.Elsewhere", bundleURL: elsewhere)],
            launchdJobRoots: [agents]
        )

        for id in [
            "com.vendor.fake", "com.vendor.fake.share", "org.sparkle-project.downloader",
            "com.othervendor.helper", "com.vendor.ios",
            "com.running.elsewhere", "com.elsewhere.app",
            "com.agent.updater", "com.agent.associated", "com.agent.updaterapp", "com.agent.updater.ext"
        ] {
            #expect(evidence.bundleIDs.contains(id), "missing \(id)")
        }
        #expect(!evidence.bundleIDs.contains("com.decoy.lproj"))
        #expect(!evidence.bundleIDs.contains("com.decoy.nodemodules"))
        #expect(evidence.userAppSignaturesRead + evidence.userAppSignatureFailures == 1)
    }

    // MARK: launchd

    @Test
    func launchdJobReadsLabelsAssociatedIDsAndProgram() {
        let job = InstalledCodeEvidence.launchdJob(from: [
            "Label": "com.vendor.agent",
            "AssociatedBundleIdentifiers": "com.vendor.App",
            "ProgramArguments": ["/bin/sh", "-c", "true"]
        ])
        #expect(job.bundleIDs == ["com.vendor.agent", "com.vendor.App"])
        #expect(job.program?.path == "/bin/sh")

        let missing = InstalledCodeEvidence.launchdJob(from: [
            "Label": "com.gone.agent",
            "Program": "/nonexistent/\(UUID().uuidString)/agent"
        ])
        #expect(missing.program == nil)
    }

    /// An agent nested in a helper app brings in the outermost app, so the whole
    /// suite's claims are read.
    @Test
    func programInsideABundleResolvesToTheOutermostOne() {
        let nested = URL(fileURLWithPath:
            "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/"
            + "Microsoft Update Assistant.app/Contents/MacOS/Microsoft Update Assistant")
        #expect(InstalledCodeEvidence.outermostCodeBundle(containing: nested)?.lastPathComponent
            == "Microsoft AutoUpdate.app")
        #expect(InstalledCodeEvidence.outermostCodeBundle(
            containing: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.vendor.helper")
        ) == nil)
    }

    // MARK: Signatures

    @Test
    func appGroupsComeFromBothEntitlementKeys() {
        let groups = CodeSignature.appGroups(fromEntitlements: [
            "com.apple.security.application-groups": ["TEAM123456.com.vendor.shared"],
            "com.apple.private.security.restricted-application-groups": "243LU875E5.groups.com.apple.podcasts",
            "com.apple.security.app-sandbox": true
        ])
        #expect(Set(groups) == ["TEAM123456.com.vendor.shared", "243LU875E5.groups.com.apple.podcasts"])
    }

    /// The reader must actually read real signatures. If it silently returned
    /// nothing, every group container would be judged by name again.
    @Test
    func signatureReaderReadsARealSignature() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try #require(FileManager.default.fileExists(atPath: calculator.path))
        let signature = try #require(CodeSignature.read(at: calculator))
        #expect(signature.identifier == "com.apple.calculator")
    }

    @Test
    func signatureReaderReadsAppGroupEntitlements() throws {
        let podcasts = URL(fileURLWithPath: "/System/Applications/Podcasts.app")
        try #require(FileManager.default.fileExists(atPath: podcasts.path))
        let signature = try #require(CodeSignature.read(at: podcasts))
        #expect(!signature.appGroups.isEmpty)
    }

    @Test
    func evidenceLowercasesIDsAndGroupsAndUppercasesTeams() {
        var evidence = InstalledCodeEvidence()
        evidence.add(CodeSignature(identifier: "Com.Vendor.App", teamID: "abcde12345", appGroups: ["ABCDE12345.Com.Vendor"]))
        #expect(evidence.bundleIDs == ["com.vendor.app"])
        #expect(evidence.teamIDs == ["ABCDE12345"])
        #expect(evidence.appGroups == ["abcde12345.com.vendor"])
    }

    // MARK: Fixtures

    private func makeBundle(at url: URL, id: String, iOSLayout: Bool = false) throws {
        let plistFolder = iOSLayout ? url : url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: plistFolder, withIntermediateDirectories: true)
        let plist: NSDictionary = ["CFBundleIdentifier": id]
        try plist.write(to: plistFolder.appendingPathComponent("Info.plist"))
    }

    /// `Fake.app` with an extension, a framework XPC service, a login item, an
    /// iPhone-style wrapped app, and decoys in a localization folder, a
    /// `node_modules` tree, and behind a symbolic link.
    private func makeFakeApp(in root: URL) throws -> URL {
        let app = root.appendingPathComponent("Fake.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try makeBundle(at: app, id: "com.vendor.fake")
        try makeBundle(at: contents.appendingPathComponent("PlugIns/Share.appex"), id: "com.vendor.fake.share")
        try makeBundle(
            at: contents.appendingPathComponent("Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"),
            id: "org.sparkle-project.Downloader"
        )
        try makeBundle(at: contents.appendingPathComponent("Library/LoginItems/Fake Helper.app"), id: "com.othervendor.helper")
        try makeBundle(at: app.appendingPathComponent("Wrapper/Inner.app"), id: "com.vendor.ios", iOSLayout: true)
        try makeBundle(at: contents.appendingPathComponent("Resources/en.lproj/Decoy.app"), id: "com.decoy.lproj")
        try makeBundle(
            at: contents.appendingPathComponent("Resources/app/node_modules/pkg/Decoy.app"),
            id: "com.decoy.nodemodules"
        )

        let outside = root.appendingPathComponent("Outside.appex", isDirectory: true)
        try makeBundle(at: outside, id: "com.decoy.link")
        try FileManager.default.createSymbolicLink(
            at: contents.appendingPathComponent("PlugIns/Linked.appex"),
            withDestinationURL: outside
        )
        return app
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstalledCodeEvidenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

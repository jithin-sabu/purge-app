import Foundation
import Testing
@testable import Purge

@Suite("Apple Intelligence model records are read from Apple's own files")
struct AppleIntelligenceModelReaderTests {
    /// Record names as seen on macOS 26.6 and 27.0.
    @Test func recordNamesYieldTypeSpecifierAndVersion() {
        let quinn = AppleIntelligenceModelReader.identity(fromFileName:
            "AutoAssetDescriptors_Entry_com.apple.MobileAsset.UAF.Siri.TextToSpeech_com.apple.siri.tts.voice.en_US.quinn.neural.premium_1219.0.0.13.202389_0.state")
        #expect(quinn?.type == "com.apple.MobileAsset.UAF.Siri.TextToSpeech")
        #expect(quinn?.specifier == "com.apple.siri.tts.voice.en_US.quinn.neural.premium")
        #expect(quinn?.version == "1219.0.0.13.202389")

        let code = AppleIntelligenceModelReader.identity(fromFileName:
            "AutoAssetDescriptors_Entry_com.apple.MobileAsset.UAF.FM.CodeLM_com.apple.fm.code.generate_small_v1.base_600.0.81600.13.202072_0.state")
        #expect(code?.specifier == "com.apple.fm.code.generate_small_v1.base")
        #expect(code?.version == "600.0.81600.13.202072")

        #expect(AppleIntelligenceModelReader.identity(fromFileName: "AutoAssetDescriptors_Config.state") == nil)
        #expect(AppleIntelligenceModelReader.identity(fromFileName: "AutoAssetLocker_Entry_x_y_1_0.state") == nil)
    }

    /// The app's half of the rule that a release is never sent with an empty
    /// list, which macOS reads as every asset on the Mac: each request names one
    /// catalog set, so every name has to be a real, distinct one. Types carry no
    /// underscore, or record names would split in the wrong place.
    @Test func everyCatalogSetHasADistinctNameAndAUAFType() {
        let sets = AppleIntelligenceCatalog.sets
        #expect(sets.count == 5)
        #expect(sets.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(Set(sets.map(\.name)).count == sets.count)
        #expect(sets.allSatisfy { $0.assetType.hasPrefix("com.apple.MobileAsset.UAF.") && !$0.assetType.contains("_") })
    }

    @Test func versionsCompareNumerically() {
        #expect(AppleIntelligenceModelReader.versionIsOrdered("600.0.81600.13.202072,0", before: "600.0.81600.13.202073,0"))
        #expect(AppleIntelligenceModelReader.versionIsOrdered("9.0", before: "10.0"))
        #expect(!AppleIntelligenceModelReader.versionIsOrdered("10.0", before: "9.0"))
    }

    /// The descriptor is a keyed archive inside the record; its fields are read
    /// by key after the archive's references are followed.
    @Test func wrappedDescriptorIsRead() throws {
        let descriptor: NSDictionary = [
            "downloadedFilesystemBytes": 7_000_000_000,
            "isOnFilesystem": true,
            "secureOperationEliminating": false,
            "metadata": ["_UnarchivedSize": 7_000_000_000] as NSDictionary,
        ]
        let blob = try NSKeyedArchiver.archivedData(withRootObject: descriptor, requiringSecureCoding: false)
        let wrapper: [String: Any] = [
            "SUCorePersistedStatePolicyFields": ["entryStatus": "LOADED"],
            "SUCorePersistedStatePolicySecureCodedObjectsFields": ["assetDescriptor": blob],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: wrapper, format: .binary, options: 0)
        let record = AppleIntelligenceModelReader.record(
            identity: ("com.apple.MobileAsset.UAF.FM.GenerativeModels", "com.apple.fm.language.base", "1.2.3"), data: data)
        #expect(record.bytes == 7_000_000_000)
        #expect(record.isOnFilesystem)
        #expect(!record.isEliminating)
    }

    @Test func unreadableDescriptorHasNoSizeAndCountsAsAbsent() {
        let record = AppleIntelligenceModelReader.record(
            identity: ("com.apple.MobileAsset.UAF.FM.Visual", "x", "1"), data: Data("not a plist".utf8))
        #expect(record.bytes == nil)
        #expect(!record.isOnFilesystem)
    }

    private func record(_ specifier: String, _ version: String, _ bytes: Int64?, onDisk: Bool = true, eliminating: Bool = false)
        -> AppleIntelligenceModelReader.Record {
        AppleIntelligenceModelReader.Record(
            assetType: "com.apple.MobileAsset.UAF.FM.Visual", specifier: specifier, version: version,
            bytes: bytes, isOnFilesystem: onDisk, isEliminating: eliminating)
    }

    private var visual: AppleIntelligenceModelSet {
        AppleIntelligenceCatalog.sets.first { $0.name == "com.apple.MobileAsset.UAF.FM.Visual" }!
    }

    /// Several versions of one model can be on the filesystem at once; only the
    /// newest counts, or a removal is promised more than it frees.
    @Test func onlyTheNewestVersionOfEachModelIsCounted() {
        let reading = AppleIntelligenceModelReader.measure(visual, records: [
            record("model.a", "1.0,0", 100), record("model.a", "2.0,0", 150), record("model.b", "1.0,0", 20),
            record("model.c", "1.0,0", 999, onDisk: false), record("model.d", "1.0,0", 5, eliminating: true),
        ])
        #expect(reading.latestBytes == 175)
        #expect(reading.recordsOnDisk == 4)
        #expect(reading.eliminating == 1)
    }

    @Test func aRecordWithoutASizeMakesTheSetUnknownNotZero() {
        let reading = AppleIntelligenceModelReader.measure(visual, records: [record("model.a", "1.0,0", nil)])
        #expect(reading.latestBytes == nil)
        #expect(reading.recordsOnDisk == 1)
        let empty = AppleIntelligenceModelReader.measure(visual, records: [])
        #expect(empty.latestBytes == 0)
    }

    @Test func aPartialSumIsNeverShownAsTheWhole() {
        let known = AppleIntelligenceSetReading(set: visual, recordsOnDisk: 1, eliminating: 0, latestBytes: 10, folder: .holdsFiles)
        let unknown = AppleIntelligenceSetReading(set: AppleIntelligenceCatalog.sets[0], recordsOnDisk: 1, eliminating: 0, latestBytes: nil, folder: .holdsFiles)
        let gone = AppleIntelligenceSetReading(set: AppleIntelligenceCatalog.sets[2], recordsOnDisk: 0, eliminating: 0, latestBytes: nil, folder: .empty)
        #expect(AppleIntelligenceReading(sets: [known, gone], readAt: Date()).latestBytes == 10)
        #expect(AppleIntelligenceReading(sets: [known, unknown], readAt: Date()).latestBytes == nil)
        #expect(!gone.isPresent)
    }
}

@Suite("The download block is a profile the user can remove")
struct AppleIntelligenceDownloadBlockTests {
    @Test func theProfileBlocksEachTypeAndNothingElse() throws {
        let types = AppleIntelligenceCatalog.sets.map(\.assetType)
        let plist = try PropertyListSerialization.propertyList(
            from: AppleIntelligenceDownloadBlock.profileData(blocking: types), format: nil) as? [String: Any]
        let payloads = plist?["PayloadContent"] as? [[String: Any]] ?? []
        #expect(payloads.count == 1)
        #expect(payloads.first?["PayloadType"] as? String == "com.apple.ManagedClient.preferences")
        let content = payloads.first?["PayloadContent"] as? [String: Any]
        let forced = (content?[AppleIntelligenceDownloadBlock.domain] as? [String: Any])?["Forced"] as? [[String: Any]]
        let settings = forced?.first?["mcx_preference_settings"] as? [String: String] ?? [:]
        #expect(settings.count == types.count)
        #expect(settings.values.allSatisfy { $0 == AppleIntelligenceDownloadBlock.blockedURL })
        #expect(settings.keys.allSatisfy { $0.hasPrefix(AppleIntelligenceDownloadBlock.keyPrefix) })
        #expect(plist?["PayloadRemovalDisallowed"] as? Bool == false)
    }

    @Test func payloadIdentifiersAreStableAndDistinct() {
        #expect(AppleIntelligenceDownloadBlock.stableUUID("a") == AppleIntelligenceDownloadBlock.stableUUID("a"))
        #expect(AppleIntelligenceDownloadBlock.stableUUID("a") != AppleIntelligenceDownloadBlock.stableUUID("b"))
        #expect(UUID(uuidString: AppleIntelligenceDownloadBlock.stableUUID("io.getpurge")) != nil)
    }

    @Test func aNewProfileKeepsTheBlocksAlreadyInForce() {
        // Sets removed earlier stay blocked when a later removal rewrites the profile.
        let kept = AppleIntelligenceDownloadBlock.typesToBlock(
            installed: ["com.apple.MobileAsset.UAF.FM.Visual", "com.apple.MobileAsset.UAF.FM.GenerativeModels"],
            adding: ["com.apple.MobileAsset.UAF.Siri.Understanding", "com.apple.MobileAsset.UAF.FM.Visual"])
        #expect(kept == [
            "com.apple.MobileAsset.UAF.FM.GenerativeModels",
            "com.apple.MobileAsset.UAF.FM.Visual",
            "com.apple.MobileAsset.UAF.Siri.Understanding",
        ])
        #expect(AppleIntelligenceDownloadBlock.typesToBlock(installed: [], adding: ["a"]) == ["a"])
    }

    /// Only keys with Purge's URL count; another profile's redirect is not Purge's.
    @Test func installedBlocksComeFromTheManagedPreferences() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("purge-ai-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        let managed: [String: Any] = [
            "DownloadServerBaseURLOverride-com.apple.MobileAsset.UAF.FM.Visual": AppleIntelligenceDownloadBlock.blockedURL,
            "DownloadServerBaseURLOverride-com.apple.MobileAsset.Other": "https://example.com/",
            "Unrelated": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: managed, format: .xml, options: 0).write(to: file)
        #expect(AppleIntelligenceDownloadBlock.installedBlocks(path: file.path) == ["com.apple.MobileAsset.UAF.FM.Visual"])
        #expect(AppleIntelligenceDownloadBlock.installedBlocks(path: file.path + ".missing") == [])
    }
}

@Suite("Other accounts are named before the models go")
struct AppleIntelligenceAccountsTests {
    @Test func dsclListingYieldsOtherHumanAccounts() {
        let listing = """
            _spotlight   89
            jithin       501
            guest        502
            root         0
            """
        #expect(AppleIntelligenceAccounts.parse(listing, currentUID: 501) == ["guest"])
        #expect(AppleIntelligenceAccounts.parse(listing, currentUID: 502) == ["jithin"])
    }

    @Test func optInFileSaysWhetherAnAccountUsesIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("purge-home-\(UUID().uuidString)")
        let prefs = home.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(AppleIntelligenceAccounts.usage(home: home.path) == .off)
        let file = prefs.appendingPathComponent("com.apple.CloudSubscriptionFeatures.optIn.plist")
        try PropertyListSerialization.data(fromPropertyList: ["device": true], format: .binary, options: 0).write(to: file)
        #expect(AppleIntelligenceAccounts.usage(home: home.path) == .usesAppleIntelligence)
        try PropertyListSerialization.data(fromPropertyList: ["12345": false, "opted_out_buddy": true], format: .binary, options: 0).write(to: file)
        #expect(AppleIntelligenceAccounts.usage(home: home.path) == .off)
        #expect(AppleIntelligenceAccounts.usage(home: "/nonexistent/home") == .unknown)
    }
}

@Suite("A removal of the models is recorded in history")
@MainActor
struct AppleIntelligenceHistoryTests {
    @Test func olderEntriesWithoutAKindStillDecode() throws {
        let json = """
            {"entries":[{"id":"6F1B3C2A-0000-4000-8000-000000000001","date":"2026-10-01T10:00:00Z","trigger":"manual",
            "bytesMovedToTrash":10,"deletedItems":[],"skippedItems":[]},
            {"id":"6F1B3C2A-0000-4000-8000-000000000002","date":"2026-10-02T10:00:00Z","trigger":"manual","kind":"appleIntelligenceModels",
            "bytesMovedToTrash":0,"bytesReclaimedOnVolume":5,"deletedItems":[{"path":"Core","sizeBytes":9}],"skippedItems":[]},
            {"id":"6F1B3C2A-0000-4000-8000-000000000003","date":"2026-10-03T10:00:00Z","trigger":"manual","kind":"somethingNewer",
            "bytesMovedToTrash":1,"deletedItems":[],"skippedItems":[]}]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(CleanupHistoryFile.self, from: Data(json.utf8))
        #expect(file.entries.count == 3)
        #expect(file.entries[0].kind == nil)
        #expect(file.entries[1].kind == .appleIntelligenceModels)
        #expect(file.entries[2].kind == nil)
    }
}

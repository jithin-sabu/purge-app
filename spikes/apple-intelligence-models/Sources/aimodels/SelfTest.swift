import Foundation

/// Checks the logic that must never go wrong, without touching the system or
/// any private interface: `aimodels selftest`. Also what CI runs.
enum SelfTest {
    static func run() -> Bool {
        var failed = 0
        func check(_ ok: Bool, _ what: String) {
            Log.line((ok ? "pass  " : "FAIL  ") + what)
            if !ok { failed += 1 }
        }

        // Catalog
        check(Set(Catalog.sets.map(\.name)).count == Catalog.sets.count, "asset set names are unique")
        check(Catalog.sets.allSatisfy { !$0.consumers.isEmpty }, "every set names what loses features")
        check(Catalog.sets.allSatisfy { $0.recovery != nil }, "every set can be downloaded again")
        check(Catalog.sets.allSatisfy {
            guard let recovery = $0.recovery else { return false }
            return !recovery.usageAliases.isEmpty || !recovery.assetSetUsages.isEmpty
        }, "every recovery names aliases or usages")
        check((try? Catalog.select(nil))?.count == Catalog.sets.count, "no --sets means every set")
        check((try? Catalog.select("com.apple.modelcatalog, com.apple.modelcatalog"))?.count == 1,
              "--sets drops duplicates")
        check((try? Catalog.select("com.apple.nothing")) == nil, "an unknown set is refused")
        check((try? Catalog.select(",")) == nil, "an empty --sets is refused")

        // Profile
        do {
            let types = Profile.blockedTypes(for: Catalog.sets)
            check(types.count == Catalog.sets.count && types.contains("com.apple.MobileAsset.UAF.FM.GenerativeModels"),
                  "the profile blocks each removed set's own asset type and nothing else")
            let plist = try PropertyListSerialization.propertyList(from: Profile.data(blocking: types), format: nil) as? [String: Any]
            let payloads = plist?["PayloadContent"] as? [[String: Any]] ?? []
            check(payloads.count == 1 && payloads.first?["PayloadType"] as? String == "com.apple.ManagedClient.preferences",
                  "the profile holds one managed-preferences payload and no restrictions")
            let content = payloads.first?["PayloadContent"] as? [String: Any]
            let forced = (content?[Profile.domain] as? [String: Any])?["Forced"] as? [[String: Any]]
            let settings = forced?.first?["mcx_preference_settings"] as? [String: String] ?? [:]
            check(settings.count == types.count && settings.values.allSatisfy { $0 == Profile.blockedURL }
                  && settings.keys.allSatisfy { $0.hasPrefix(Profile.keyPrefix) },
                  "every block points the asset type at the dead loopback URL")
            check(plist?["PayloadRemovalDisallowed"] as? Bool == false, "the profile can be removed by the user")
            check(Profile.uuid("a") == Profile.uuid("a") && Profile.uuid("a") != Profile.uuid("b"),
                  "payload UUIDs are stable and distinct")
        } catch {
            check(false, "the profile builds: \(error)")
        }

        // Descriptor parsing on a synthetic record
        do {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aimodels-selftest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let record: [String: Any] = [
                "AssetType": "com.apple.MobileAsset.UAF.FM.Visual",
                "AssetSpecifier": "visual_en",
                "Payload": ["_UnarchivedSize": 1_500_000_000, "_CompressedSize": 900_000_000, "DownloadState": "installed"],
            ]
            let file = temp.appendingPathComponent("AutoAssetDescriptor_test.plist")
            try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0).write(to: file)
            let parsed = Descriptors.parse(path: file.path, fileName: file.lastPathComponent)
            check(parsed.assetType == "com.apple.MobileAsset.UAF.FM.Visual" && parsed.assetSpecifier == "visual_en",
                  "a binary plist record yields its type and specifier")
            check(parsed.countedSize?.bytes == 1_500_000_000 && parsed.countedSize?.key == "Payload._UnarchivedSize",
                  "the unarchived size wins over the compressed size")
            check(parsed.hints["Payload.DownloadState"] == "installed", "state-like keys are kept as hints")
            let junk = temp.appendingPathComponent("AutoAssetDescriptor_com.apple.MobileAsset.UAF.FM.GenerativeModels_x.state")
            try Data("not a plist".utf8).write(to: junk)
            let unreadable = Descriptors.parse(path: junk.path, fileName: junk.lastPathComponent)
            check(unreadable.unreadable != nil && unreadable.assetType == "com.apple.MobileAsset.UAF.FM.GenerativeModels",
                  "an unreadable record keeps its reason and the type from its name")
            let reading = DescriptorReading(records: [parsed, unreadable],
                                            lockEntries: ["AutoAssetLocker_Entry_com.apple.MobileAsset.UAF.FM.Visual_visual_en_1.state"],
                                            errors: [])
            let measured = Descriptors.measure(Catalog.sets, reading: reading)
            let visual = measured.first { $0.set.name == Catalog.visual }
            check(visual?.bytes == 1_500_000_000 && visual?.locks.count == 1, "a set sums its records and counts its locks")
            check(measured.first { $0.set.name == Catalog.foundation }?.bytes == nil,
                  "a set whose only record is unreadable has an unknown size, not zero")
            check(measured.first { $0.set.name == Catalog.code }?.bytes == nil, "a set with no record is unknown, not zero")
            let gone = Descriptors.record(from: [
                "SUCorePersistedStatePolicySecureCodedObjectsFields": [
                    "assetDescriptor!": ["downloadedFilesystemBytes": 5, "isOnFilesystem": false]] as [String: Any],
            ] as [String: Any], path: "/x", fileName: "AutoAssetDescriptors_Entry_com.apple.MobileAsset.UAF.FM.CodeLM_a_1_0.state")
            let goneOnly = Descriptors.measure([Catalog.set(named: Catalog.code)!],
                                               reading: DescriptorReading(records: [gone], lockEntries: [], errors: []))
            check(goneOnly.first?.bytes == 0 && goneOnly.first?.onDisk == 0, "a record that is off the filesystem counts as known zero")
        } catch {
            check(false, "descriptor parsing works on fixtures: \(error)")
        }

        // Record file names as seen on a macOS 26 runner, and the archive blob inside
        let quinn = Descriptors.identity(fromFileName:
            "AutoAssetDescriptors_Entry_com.apple.MobileAsset.UAF.Siri.TextToSpeech_com.apple.siri.tts.voice.en_US.quinn.neural.premium_1219.0.0.13.202389_0.state")
        check(quinn?.type == "com.apple.MobileAsset.UAF.Siri.TextToSpeech"
              && quinn?.specifier == "com.apple.siri.tts.voice.en_US.quinn.neural.premium" && quinn?.version == "1219.0.0.13.202389",
              "a record name yields type, specifier with underscores, and version")
        let eligibility = Descriptors.identity(fromFileName:
            "AutoAssetDescriptors_Entry_com.apple.MobileAsset.OSEligibility_Parameters_0.0.0.0.12_0.state")
        check(eligibility?.type == "com.apple.MobileAsset.OSEligibility" && eligibility?.specifier == "Parameters"
              && eligibility?.version == "0.0.0.0.12", "a short record name parses the same way")
        check(Descriptors.identity(fromFileName: "AutoAssetDescriptors_Config.state") == nil, "the config record has no identity")
        let lock = Descriptors.identity(fromFileName:
            "AutoAssetLocker_Entry_com.apple.MobileAsset.UAF.FM.GenerativeModels_com.apple.fm.language.base_1.0_0.state")
        check(lock?.type == "com.apple.MobileAsset.UAF.FM.GenerativeModels", "a lock entry name yields its type")
        do {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aimodels-archive-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            // A real keyed archive, shaped like the descriptor the macOS 26 runner
            // showed: flat fields on the root, the catalog metadata as a dictionary.
            let descriptor: NSDictionary = [
                "downloadedFilesystemBytes": 7_000_000_000, "downloadedNetworkBytes": 4_000_000_000,
                "isOnFilesystem": true, "secureOperationEliminating": false, "neverBeenLocked": false,
                "metadata": ["_UnarchivedSize": 7_000_000_000, "_DownloadSize": 4_000_000_000,
                             "__AssetDefaultGarbageCollectionBehavior": "NeverCollected"] as NSDictionary,
            ]
            let blob = try NSKeyedArchiver.archivedData(withRootObject: descriptor, requiringSecureCoding: false)
            check(KeyedArchive.isArchive(try PropertyListSerialization.propertyList(from: blob, format: nil)),
                  "an NSKeyedArchiver blob is recognised")
            let wrapper: [String: Any] = [
                "SUCorePersistedStatePolicyFields": ["entryStatus": "LOADED"],
                "SUCorePersistedStatePolicySecureCodedObjectsFields": ["assetDescriptor": blob],
            ]
            let file = temp.appendingPathComponent(
                "AutoAssetDescriptors_Entry_com.apple.MobileAsset.UAF.FM.GenerativeModels_com.apple.fm.language.base_1.2.3_0.state")
            try PropertyListSerialization.data(fromPropertyList: wrapper, format: .binary, options: 0).write(to: file)
            let parsed = Descriptors.parse(path: file.path, fileName: file.lastPathComponent)
            check(parsed.assetType == "com.apple.MobileAsset.UAF.FM.GenerativeModels" && parsed.assetVersion == "1.2.3",
                  "a wrapped record takes its identity from the file name")
            check(parsed.countedSize?.bytes == 7_000_000_000
                  && parsed.countedSize?.key == "SUCorePersistedStatePolicySecureCodedObjectsFields.assetDescriptor!.downloadedFilesystemBytes",
                  "the on-disk bytes inside the archive are found by key path")
            check(parsed.sizes["SUCorePersistedStatePolicySecureCodedObjectsFields.assetDescriptor!.metadata._UnarchivedSize"] == 7_000_000_000,
                  "the metadata dictionary's UID references are resolved")
            check(parsed.isOnFilesystem == true && parsed.isEliminating == false && parsed.neverBeenLocked == false
                  && parsed.collectionBehavior == "NeverCollected", "the descriptor's flags are read")
            check(parsed.hints["SUCorePersistedStatePolicyFields.entryStatus"] == "LOADED", "the entry status is a hint")
            let dumped = parsed.raw.map { Format.json(Descriptors.dumpable($0), pretty: false) } ?? ""
            check(dumped.contains("assetDescriptor!") && dumped.contains("_UnarchivedSize"), "the dump shows the decoded blob")
        } catch {
            check(false, "archive decoding works on fixtures: \(error)")
        }

        // CacheDelete filter verdict
        let service = CacheDeleteCheck.defaultService
        let others = ["com.apple.photolibraryd.cache-delete", service]
        var verdict = CacheDeleteCheck.judge(
            filtered: ["CACHE_DELETE_AMOUNT": 5_000_000_000],
            unfiltered: ["CACHE_DELETE_AMOUNT": 9_000_000_000], service: service, otherServices: others)
        check(verdict.honoured, "a lower filtered figure passes")
        verdict = CacheDeleteCheck.judge(
            filtered: ["CACHE_DELETE_AMOUNT": 9_000_000_000],
            unfiltered: ["CACHE_DELETE_AMOUNT": 9_000_000_000], service: service, otherServices: others)
        check(!verdict.honoured, "the same figure with and without the filter fails")
        verdict = CacheDeleteCheck.judge(
            filtered: ["CACHE_DELETE_AMOUNT": 1, "services": ["com.apple.photolibraryd.cache-delete": 1]],
            unfiltered: ["CACHE_DELETE_AMOUNT": 9], service: service, otherServices: others)
        check(!verdict.honoured, "a filtered reply naming another service fails")
        verdict = CacheDeleteCheck.judge(filtered: [:], unfiltered: ["CACHE_DELETE_AMOUNT": 9], service: service, otherServices: others)
        check(!verdict.honoured, "a filtered reply without an amount fails")
        verdict = CacheDeleteCheck.judge(filtered: ["CACHE_DELETE_AMOUNT": 0], unfiltered: ["CACHE_DELETE_AMOUNT": 0],
                                         service: service, otherServices: others)
        check(!verdict.honoured, "zero on both sides cannot pass")
        let request = CacheDeleteCheck.request(service: service, urgency: 2, amount: 10)
        check((request["CACHE_DELETE_SERVICES"] as? [String]) == [service] && request["CACHE_DELETE_VOLUME"] as? String == "/",
              "a purge request carries the service filter and the root volume")

        // Account opt-in reading
        do {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aimodels-home-\(UUID().uuidString)")
            let prefs = temp.appendingPathComponent("Library/Preferences")
            try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            check(Accounts.usage(home: temp.path) == .neverChose, "a readable home without the opt-in file never chose")
            let file = prefs.appendingPathComponent("com.apple.CloudSubscriptionFeatures.optIn.plist")
            try PropertyListSerialization.data(fromPropertyList: ["device": true], format: .binary, options: 0).write(to: file)
            check(Accounts.usage(home: temp.path) == .usesAppleIntelligence, "a true opt-in counts as using it")
            try PropertyListSerialization.data(fromPropertyList: ["12345": false, "opted_out_buddy": true], format: .binary, options: 0).write(to: file)
            check(Accounts.usage(home: temp.path) == .optedOut, "false and opted-out keys count as off")
            check(Accounts.usage(home: "/nonexistent/home") == .unknown, "an unreadable home is unknown")
        } catch {
            check(false, "account reading works on fixtures: \(error)")
        }

        // JSON safety for raw replies
        let safe = Format.jsonSafe(["date": Date(), "data": Data([1, 2]), "n": 3, "nested": ["x": NSNull()]])
        check(JSONSerialization.isValidJSONObject(safe), "raw replies with dates and data serialize")

        Log.line(failed == 0 ? "all checks passed" : "\(failed) check(s) failed")
        return failed == 0
    }
}

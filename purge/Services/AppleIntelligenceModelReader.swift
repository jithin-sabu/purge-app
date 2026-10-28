import Foundation

/// Reads MobileAsset's persisted records to measure the Apple Intelligence
/// models, with no private API: plain reads of world-readable property lists
/// under `/System/Library/AssetsV2/persisted/AutoAssetDescriptors`.
///
/// Each record is named `AutoAssetDescriptors_Entry_<type>_<specifier>_<version>_0.state`
/// and wraps the descriptor as a keyed archive under
/// `SUCorePersistedStatePolicySecureCodedObjectsFields.assetDescriptor`, whose
/// root holds `downloadedFilesystemBytes`, `isOnFilesystem` and
/// `secureOperationEliminating`. Confirmed on macOS 26.6 and 27.0 by the spike
/// in `spikes/apple-intelligence-models`.
///
/// The byte counts are Apple's. On macOS 27 the volume gave back about half the
/// summed figure when the models went (the rest was already counted as
/// purgeable), so the app shows them as Apple's estimate and records the
/// measured delta after a removal.
nonisolated enum AppleIntelligenceModelReader {
    static let descriptorsRoot = "/System/Library/AssetsV2/persisted/AutoAssetDescriptors"
    static let assetsRoot = "/System/Library/AssetsV2"

    /// One parsed record: identity from the file name, figures from the archive.
    nonisolated struct Record: Equatable, Sendable {
        let assetType: String
        let specifier: String
        let version: String
        let bytes: Int64?
        let isOnFilesystem: Bool
        let isEliminating: Bool
    }

    static func read(fileManager: FileManager = .default) -> AppleIntelligenceReading {
        let records = readRecords(fileManager: fileManager)
        let sets = AppleIntelligenceCatalog.sets.map { set in
            measure(set, records: records.filter { $0.assetType == set.assetType }, fileManager: fileManager)
        }
        return AppleIntelligenceReading(sets: sets, readAt: Date())
    }

    static func readRecords(fileManager: FileManager = .default, root: String = descriptorsRoot) -> [Record] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        let wanted = Set(AppleIntelligenceCatalog.sets.map(\.assetType))
        var records: [Record] = []
        for name in names {
            guard let identity = identity(fromFileName: name), wanted.contains(identity.type) else { continue }
            guard let data = fileManager.contents(atPath: root + "/" + name) else { continue }
            records.append(record(identity: identity, data: data))
        }
        return records
    }

    /// Sums only records on the filesystem, newest version of each model.
    static func measure(_ set: AppleIntelligenceModelSet, records: [Record],
                        fileManager: FileManager = .default, root: String = assetsRoot) -> AppleIntelligenceSetReading {
        let onDisk = records.filter(\.isOnFilesystem)
        var latest: [String: Record] = [:]
        for record in onDisk {
            if let known = latest[record.specifier], !versionIsOrdered(known.version, before: record.version) { continue }
            latest[record.specifier] = record
        }
        var total: Int64 = 0
        var allKnown = true
        for record in latest.values {
            if let bytes = record.bytes { total += bytes } else { allKnown = false }
        }
        let folder = folderState(set.assetType, root: root, fileManager: fileManager)
        // No readable record but files in the folder: a size nobody knows, not zero.
        let bytes: Int64?
        if onDisk.isEmpty {
            bytes = folder == .holdsFiles ? nil : 0
        } else {
            bytes = allKnown ? total : nil
        }
        return AppleIntelligenceSetReading(
            set: set,
            recordsOnDisk: onDisk.count,
            eliminating: records.filter(\.isEliminating).count,
            latestBytes: bytes,
            folder: folder
        )
    }

    // MARK: Records

    /// Asset types are reverse-DNS names with no underscore, so the first
    /// underscore after the prefix ends the type; the version is the
    /// second-to-last component and the specifier, which can hold underscores,
    /// is what lies between.
    static func identity(fromFileName fileName: String) -> (type: String, specifier: String, version: String)? {
        let prefix = "AutoAssetDescriptors_Entry_"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".state") else { return nil }
        let name = String(fileName.dropFirst(prefix.count).dropLast(".state".count))
        guard let underscore = name.firstIndex(of: "_") else { return nil }
        let type = String(name[..<underscore])
        let rest = name[name.index(after: underscore)...].split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard type.hasPrefix("com."), rest.count >= 3 else { return nil }
        let version = rest[rest.count - 2]
        let specifier = rest[0..<(rest.count - 2)].joined(separator: "_")
        return (type, specifier, version)
    }

    static func record(identity: (type: String, specifier: String, version: String), data: Data) -> Record {
        var descriptor: [String: Any] = [:]
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let coded = plist["SUCorePersistedStatePolicySecureCodedObjectsFields"] as? [String: Any],
           let blob = coded["assetDescriptor"] as? Data,
           let archive = try? PropertyListSerialization.propertyList(from: blob, format: nil),
           let root = KeyedArchiveReader.root(of: archive) as? [String: Any] {
            descriptor = root
        }
        let bytes = (descriptor["downloadedFilesystemBytes"] as? NSNumber)?.int64Value
        return Record(
            assetType: identity.type,
            specifier: identity.specifier,
            version: identity.version,
            bytes: bytes,
            isOnFilesystem: (descriptor["isOnFilesystem"] as? Bool) ?? !descriptor.isEmpty,
            isEliminating: (descriptor["secureOperationEliminating"] as? Bool) ?? false
        )
    }

    /// Orders versions like `600.0.81600.13.202072,0` numerically, component
    /// by component, so 10 sorts after 9.
    static func versionIsOrdered(_ lhs: String, before rhs: String) -> Bool {
        let left = lhs.split(whereSeparator: { $0 == "." || $0 == "," }).map { Int($0) ?? 0 }
        let right = rhs.split(whereSeparator: { $0 == "." || $0 == "," }).map { Int($0) ?? 0 }
        for (a, b) in zip(left, right) where a != b { return a < b }
        return left.count < right.count
    }

    // MARK: Folders

    /// macOS will not list these folders, even to an admin, but it still says how
    /// many entries a folder has and whether a named entry exists. After a
    /// removal a folder keeps at most `purpose_auto` with the catalog XML and its
    /// `.purged` copy; anything else counts as files (RemoveMacAI's rule).
    static func folderState(_ assetType: String, root: String = assetsRoot,
                            fileManager: FileManager = .default) -> AppleIntelligenceFolderState {
        let name = assetType.replacingOccurrences(of: ".", with: "_")
        let folder = root + "/" + name
        var info = stat()
        if lstat(folder, &info) != 0 { return errno == ENOENT ? .missing : .unknown }
        guard let top = entryCount(folder) else { return .unknown }
        let purpose = folder + "/purpose_auto"
        guard fileManager.fileExists(atPath: purpose) else { return top > 0 ? .holdsFiles : .empty }
        guard let inner = entryCount(purpose) else { return .unknown }
        let catalog = [name + ".xml", name + ".xml.purged"].filter { fileManager.fileExists(atPath: purpose + "/" + $0) }
        return (top > 1 || inner > catalog.count) ? .holdsFiles : .empty
    }

    /// Entries in a folder from its attributes rather than a listing, or nil.
    static func entryCount(_ path: String) -> Int? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.dirattr = attrgroup_t(ATTR_DIR_ENTRYCOUNT)
        var reply: (length: UInt32, count: UInt32) = (0, 0)
        let status = withUnsafeMutableBytes(of: &reply) { buffer in
            getattrlist(path, &request, buffer.baseAddress, buffer.count, 0)
        }
        return status == 0 && reply.length >= UInt32(MemoryLayout.size(ofValue: reply)) ? Int(reply.count) : nil
    }
}

/// Rebuilds the root object of an NSKeyedArchiver archive read as a plain
/// property list, so a descriptor's fields can be read by key without
/// unarchiving Apple's private classes. PropertyListSerialization returns UID
/// references as opaque values whose description is
/// `<CFKeyedArchiverUID 0x…>{value = N}`; N indexes `$objects`.
nonisolated enum KeyedArchiveReader {
    static func root(of plist: Any) -> Any? {
        guard let archive = plist as? [String: Any],
              archive["$archiver"] as? String == "NSKeyedArchiver",
              let objects = archive["$objects"] as? [Any],
              let top = archive["$top"] as? [String: Any],
              let reference = top["root"] ?? top.values.first
        else { return nil }
        var visiting = Set<Int>()
        return resolve(reference, objects: objects, visiting: &visiting, depth: 0)
    }

    static func uid(_ value: Any) -> Int? {
        let description = String(describing: value)
        guard description.hasPrefix("<CFKeyedArchiverUID"), let open = description.range(of: "{value = "),
              let close = description.range(of: "}", range: open.upperBound..<description.endIndex)
        else { return nil }
        return Int(description[open.upperBound..<close.lowerBound])
    }

    private static func resolve(_ value: Any, objects: [Any], visiting: inout Set<Int>, depth: Int) -> Any {
        guard depth < 64 else { return NSNull() }
        if let index = uid(value) {
            guard index >= 0, index < objects.count, !visiting.contains(index) else { return NSNull() }
            visiting.insert(index)
            defer { visiting.remove(index) }
            return resolve(objects[index], objects: objects, visiting: &visiting, depth: depth + 1)
        }
        if let text = value as? String { return text == "$null" ? NSNull() : text }
        if let array = value as? [Any] {
            return array.map { resolve($0, objects: objects, visiting: &visiting, depth: depth + 1) }
        }
        guard let dictionary = value as? [String: Any] else { return value }
        if let keys = dictionary["NS.keys"] as? [Any], let values = dictionary["NS.objects"] as? [Any], keys.count == values.count {
            var out: [String: Any] = [:]
            for (key, inner) in zip(keys, values) {
                let name = resolve(key, objects: objects, visiting: &visiting, depth: depth + 1)
                out[(name as? String) ?? String(describing: name)] = resolve(inner, objects: objects, visiting: &visiting, depth: depth + 1)
            }
            return out
        }
        if let values = dictionary["NS.objects"] as? [Any], dictionary["NS.keys"] == nil {
            return values.map { resolve($0, objects: objects, visiting: &visiting, depth: depth + 1) }
        }
        var out: [String: Any] = [:]
        for (key, inner) in dictionary where key != "$class" {
            out[key] = resolve(inner, objects: objects, visiting: &visiting, depth: depth + 1)
        }
        return out
    }
}

/// The configuration profile that keeps removed models from downloading again.
/// It forces `DownloadServerBaseURLOverride-<assetType>` in `com.apple.MobileAsset`
/// to a dead loopback URL, which `mobileassetd` reads from
/// `/Library/Managed Preferences` (technique from pared). It holds nothing
/// else; removing it is the whole undo, and only the user can do that.
nonisolated enum AppleIntelligenceDownloadBlock {
    static let profileIdentifier = "io.getpurge.app.apple-intelligence-models"
    static let domain = "com.apple.MobileAsset"
    static let keyPrefix = "DownloadServerBaseURLOverride-"
    static let blockedURL = "https://127.0.0.1:9/purge-blocked/"
    static let managedPreferences = "/Library/Managed Preferences/com.apple.MobileAsset.plist"

    /// The name System Settings lists the profile under. The steps that send the
    /// user there quote it, so both read this one value (#187).
    static var profileDisplayName: String { String(localized: "Purge: Apple Intelligence models removed") }

    /// The types a new profile has to block: the ones already in force plus the
    /// ones being removed now. The profile keeps one identifier and UUID, so
    /// installing it replaces the earlier one; a profile that named only the
    /// sets removed today would silently free the ones removed last time.
    static func typesToBlock(installed: [String], adding: [String]) -> [String] {
        Array(Set(installed).union(adding)).sorted()
    }

    static func profileData(blocking types: [String]) throws -> Data {
        var settings: [String: Any] = [:]
        for type in types { settings[keyPrefix + type] = blockedURL }
        let payloadID = profileIdentifier + ".mobileasset"
        let payload: [String: Any] = [
            "PayloadType": "com.apple.ManagedClient.preferences",
            "PayloadVersion": 1,
            "PayloadIdentifier": payloadID,
            "PayloadUUID": stableUUID(payloadID),
            "PayloadDisplayName": String(localized: "Block Apple Intelligence model downloads"),
            "PayloadContent": [domain: ["Forced": [["mcx_preference_settings": settings]]]],
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": profileIdentifier,
            "PayloadUUID": stableUUID(profileIdentifier),
            "PayloadDisplayName": profileDisplayName,
            "PayloadDescription": String(localized:
                "Stops macOS downloading the Apple Intelligence models Purge removed. Remove this profile, or choose Download Again in Purge, to let them come back."),
            "PayloadOrganization": "Purge",
            "PayloadScope": "System",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [payload],
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// A stable name-based UUID per identifier, so installing a new version
    /// replaces the old one instead of adding a second profile. Version 5 shape
    /// over a SHA-256 prefix; the hash only has to be stable, not standard.
    static func stableUUID(_ name: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in name.utf8.enumerated() {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
            bytes[index % 16] ^= UInt8(truncatingIfNeeded: hash >> UInt64((index % 8) * 8))
        }
        for index in 0..<16 { bytes[index] ^= UInt8(truncatingIfNeeded: hash >> UInt64((index % 8) * 8)) }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }

    /// The asset types the installed managed preferences block with Purge's URL.
    /// Empty when no profile is in force. Read from the file `mobileassetd`
    /// itself reads, so it says what the daemon sees.
    static func installedBlocks(path: String = managedPreferences, fileManager: FileManager = .default) -> [String] {
        guard let data = fileManager.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        return plist.compactMap { key, value -> String? in
            guard key.hasPrefix(keyPrefix), value as? String == blockedURL else { return nil }
            return String(key.dropFirst(keyPrefix.count))
        }.sorted()
    }

    /// Where the profile is written for System Settings to pick up: a folder of
    /// Purge's own under the user's temporary directory. Earlier versions wrote
    /// it to Downloads, which put a file there and could prompt for access (#179).
    static var profileDirectoryURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("io.getpurge.app.profiles", isDirectory: true)
    }

    static let profileFileName = "Purge Apple Intelligence Models.mobileconfig"

    /// Writes the profile and returns where. The write is atomic: it lands in a
    /// temporary file that then replaces whatever is at the path, so a link
    /// planted there is replaced rather than followed.
    @discardableResult
    static func writeProfile(_ data: Data, in directory: URL = profileDirectoryURL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(profileFileName)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Removes the profile Purge wrote, and only that: a regular file at the
    /// path. The delete comes after a wait of up to ten minutes, so anything
    /// else that turned up there meanwhile, a folder or a link, is left alone.
    /// The attributes are read without following a link.
    static func removeProfile(at url: URL, fileManager: FileManager = .default) {
        guard let type = try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
              type == .typeRegular
        else { return }
        try? fileManager.removeItem(at: url)
    }

    static let profilesPaneURLs = [
        "x-apple.systempreferences:com.apple.Profiles-Settings.extension",
        "x-apple.systempreferences:com.apple.preferences.configurationprofiles",
    ]
}

/// Other accounts on this Mac, from `dscl`, and whether each uses Apple
/// Intelligence according to its opt-in preference file. Another account's
/// Library is not readable from this one, which reads as unknown.
nonisolated enum AppleIntelligenceAccounts {
    static let optInPlist = "Library/Preferences/com.apple.CloudSubscriptionFeatures.optIn.plist"

    static func others() async -> [AppleIntelligenceAccount] {
        guard let listing = await ProcessRunner.runAsync(
            executablePath: "/usr/bin/dscl", arguments: [".", "-list", "/Users", "UniqueID"], timeout: 15
        ), listing.succeeded else { return [] }
        return parse(listing.stdoutText, currentUID: Int(getuid())).map { name in
            AppleIntelligenceAccount(name: name, usage: usage(home: "/Users/\(name)"))
        }
    }

    /// Account names with a user id of 500 or more, other than the current one.
    static func parse(_ listing: String, currentUID: Int) -> [String] {
        var names: [String] = []
        for line in listing.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let uid = Int(parts[parts.count - 1]), uid >= 500, uid != currentUID else { continue }
            names.append(String(parts[0]))
        }
        return names.sorted()
    }

    /// With no Apple Account signed in the key is `device`; signed in, it is the
    /// account's DSID. Any true boolean counts as using it; an opted-out key does not.
    static func usage(home: String, fileManager: FileManager = .default) -> AppleIntelligenceAccount.Usage {
        let path = home + "/" + optInPlist
        guard fileManager.isReadableFile(atPath: path) else {
            return fileManager.isReadableFile(atPath: home + "/Library/Preferences") ? .off : .unknown
        }
        guard let data = fileManager.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return .unknown }
        for (key, value) in plist {
            guard let flag = value as? Bool, flag else { continue }
            if key.lowercased().contains("opt_out") || key.lowercased().contains("opted_out") { continue }
            return .usesAppleIntelligence
        }
        return .off
    }
}

/// Runs the embedded `io.getpurge.assetworker` for one private call and reads
/// its JSON reply. A crash of the worker is reported as such, not as a Purge crash.
nonisolated enum AppleIntelligenceWorker {
    nonisolated struct Outcome {
        let ok: Bool
        let result: [String: Any]
        let error: String?

        var problem: String { error ?? String(localized: "no reason given") }
    }

    static var executableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/io.getpurge.assetworker")
    }

    static func run(_ op: String, _ input: [String: Any] = [:], timeout: TimeInterval) async -> Outcome {
        let path = executableURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return Outcome(ok: false, result: [:], error: String(localized: "Purge's asset worker is missing from the app"))
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: input),
              let json = String(data: payload, encoding: .utf8)
        else { return Outcome(ok: false, result: [:], error: String(localized: "request could not be encoded")) }
        guard let output = await ProcessRunner.runAsync(executablePath: path, arguments: [op, json], timeout: timeout + 10)
        else { return Outcome(ok: false, result: [:], error: String(localized: "Purge's asset worker could not be started")) }
        if output.timedOut {
            return Outcome(ok: false, result: [:], error: String(localized: "No answer in \(Int(timeout)) seconds"))
        }
        guard let reply = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
            // No JSON at all: the worker died before answering, which on a signal
            // means the private interface no longer looks the way it did.
            return Outcome(ok: false, result: [:],
                           error: String(localized: "The asset service call stopped without an answer (status \(Int(output.status)))"))
        }
        return Outcome(ok: reply["ok"] as? Bool ?? false,
                       result: reply["result"] as? [String: Any] ?? [:],
                       error: reply["error"] as? String)
    }
}

/// Free blocks only, with no purgeable accounting. On macOS 27 freshly
/// downloaded models are purgeable, so they vanish from the figure System
/// Settings shows but not from this one; the two together say what a removal
/// really gave back.
nonisolated enum VolumeRawCapacityReader {
    static func readAvailableBytes(for url: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let available = values.volumeAvailableCapacity
        else { return nil }
        return Int64(available)
    }
}

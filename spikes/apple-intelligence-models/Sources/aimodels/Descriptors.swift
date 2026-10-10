import Foundation

/// One record under AutoAssetDescriptors, read as a property list. The key
/// names are not documented anywhere the spike could reach, so every record
/// keeps what it found under likely names and can dump itself whole.
struct DescriptorRecord {
    let path: String
    let fileName: String
    /// From the record, or inferred from the file name when the record has no type key.
    let assetType: String?
    let assetSpecifier: String?
    let assetVersion: String?
    /// Every numeric value whose key mentions Size or Bytes, keyed by its path in the plist.
    let sizes: [String: Int64]
    /// Every value whose key looks like a state, keyed by its path in the plist.
    let hints: [String: String]
    let raw: Any?
    let unreadable: String?

    /// The size the spike counts, and the key it came from.
    var countedSize: (bytes: Int64, key: String)? {
        for preferred in Descriptors.preferredSizeKeys {
            if let match = sizes.first(where: { $0.key.hasSuffix(preferred) }) {
                return (match.value, match.key)
            }
        }
        guard let largest = sizes.max(by: { $0.value < $1.value }) else { return nil }
        return (largest.value, largest.key)
    }
}

/// Whether a set's folder under /System/Library/AssetsV2 still holds files.
enum FolderState: String {
    case missing
    case empty
    case holdsFiles
    case unknown
}

struct SetMeasurement {
    let set: ModelSet
    let records: [DescriptorRecord]
    let bytes: Int64?
    let sizeKeys: Set<String>
    let locks: [String]
    let folder: FolderState

    var summary: [String: Any] {
        var out: [String: Any] = [
            "assetSet": set.name,
            "assetType": set.assetType,
            "records": records.count,
            "locks": locks.count,
            "folder": folder.rawValue,
            "sizeKeys": sizeKeys.sorted(),
        ]
        if let bytes { out["bytes"] = bytes }
        return out
    }
}

struct DescriptorReading {
    let records: [DescriptorRecord]
    let lockEntries: [String]
    let errors: [String]
    var unreadable: [DescriptorRecord] { records.filter { $0.unreadable != nil } }
}

/// Reads MobileAsset's persisted per-asset records and lock entries. Plain file
/// reads of world-readable files: no private API, nothing changes.
enum Descriptors {
    static let root = "/System/Library/AssetsV2/persisted/AutoAssetDescriptors"
    static let locker = root + "/AutoAssetLocker"
    static let assetsRoot = "/System/Library/AssetsV2"

    static let preferredSizeKeys = [
        "_UnarchivedSize", "com.apple.UnifiedAssetFramework.UnarchivedSize", "UnarchivedSize",
        "_MeasuredSize", "MeasuredSize", "_CompressedSize", "_DownloadSize",
    ]

    static func read(fileManager: FileManager = .default) -> DescriptorReading {
        var errors: [String] = []
        var records: [DescriptorRecord] = []
        do {
            let names = try fileManager.contentsOfDirectory(atPath: root)
            for name in names.sorted() {
                let path = root + "/" + name
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue
                else { continue }
                records.append(parse(path: path, fileName: name))
            }
        } catch {
            errors.append("\(root): \(error.localizedDescription)")
        }
        // The locker folder only exists while something holds a lock (a macOS 26
        // runner with no Apple Intelligence sets has none), so a missing one is
        // no lock entries, not a failure.
        var locks: [String] = []
        if fileManager.fileExists(atPath: locker) {
            do {
                locks = try fileManager.contentsOfDirectory(atPath: locker).sorted()
            } catch {
                errors.append("\(locker): \(error.localizedDescription)")
            }
        }
        return DescriptorReading(records: records, lockEntries: locks, errors: errors)
    }

    /// Reads one record. Binary and XML plists both go through
    /// PropertyListSerialization; JSON is tried next; anything else is kept as
    /// unreadable with the reason, never silently dropped.
    static func parse(path: String, fileName: String) -> DescriptorRecord {
        guard let data = FileManager.default.contents(atPath: path) else {
            return DescriptorRecord(path: path, fileName: fileName, assetType: inferType(fileName),
                                    assetSpecifier: nil, assetVersion: nil, sizes: [:], hints: [:],
                                    raw: nil, unreadable: "could not be read")
        }
        var object: Any?
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            object = plist
        } else if let json = try? JSONSerialization.jsonObject(with: data) {
            object = json
        }
        guard let object else {
            return DescriptorRecord(path: path, fileName: fileName, assetType: inferType(fileName),
                                    assetSpecifier: nil, assetVersion: nil, sizes: [:], hints: [:],
                                    raw: nil, unreadable: "neither a property list nor JSON (\(data.count) bytes)")
        }
        return record(from: object, path: path, fileName: fileName)
    }

    /// The file name carries the identity: on macOS 26 the records are named
    /// `AutoAssetDescriptors_Entry_<assetType>_<specifier>_<version>_<n>.state`
    /// (seen on a CI runner). Asset types are reverse-DNS names with no
    /// underscore, so the first underscore after the prefix ends the type; the
    /// version is the second-to-last underscore component and the specifier,
    /// which can hold underscores itself, is what lies between.
    static func identity(fromFileName fileName: String) -> (type: String, specifier: String?, version: String?)? {
        var name = fileName
        for prefix in ["AutoAssetDescriptors_Entry_", "AutoAssetDescriptor_", "AutoAssetLocker_Entry_"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        if let dot = name.lastIndex(of: "."), name[dot...] == ".state" || name[dot...] == ".plist" {
            name = String(name[..<dot])
        }
        guard let underscore = name.firstIndex(of: "_") else {
            return name.hasPrefix("com.") ? (name, nil, nil) : nil
        }
        let type = String(name[..<underscore])
        guard type.hasPrefix("com.") else { return nil }
        let rest = name[name.index(after: underscore)...].split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard rest.count >= 3 else { return (type, rest.joined(separator: "_"), nil) }
        let version = rest[rest.count - 2]
        let specifier = rest[0..<(rest.count - 2)].joined(separator: "_")
        return (type, specifier, version)
    }

    static func record(from object: Any, path: String, fileName: String) -> DescriptorRecord {
        var strings: [String: String] = [:]
        var sizes: [String: Int64] = [:]
        var hints: [String: String] = [:]
        walk(object, at: "") { keyPath, key, value in
            let lowered = key.lowercased()
            if let text = value as? String {
                strings[key] = strings[key] ?? text
                if stateKey(lowered) { hints[keyPath] = text }
            } else if let number = value as? NSNumber {
                if lowered.contains("size") || lowered.contains("bytes") {
                    sizes[keyPath] = number.int64Value
                } else if stateKey(lowered) {
                    hints[keyPath] = number.stringValue
                }
            }
        }
        let named = identity(fromFileName: fileName)
        let type = strings["AssetType"] ?? strings["_AssetType"] ?? strings["assetType"] ?? named?.type ?? inferType(fileName)
        let specifier = strings["AssetSpecifier"] ?? strings["_AssetSpecifier"] ?? strings["assetSpecifier"] ?? named?.specifier
        let version = strings["AssetVersion"] ?? strings["_AssetVersion"] ?? strings["assetVersion"] ?? named?.version
        return DescriptorRecord(path: path, fileName: fileName, assetType: type, assetSpecifier: specifier,
                                assetVersion: version, sizes: sizes, hints: hints, raw: object, unreadable: nil)
    }

    private static func stateKey(_ lowered: String) -> Bool {
        ["state", "status", "present", "installed", "purge", "eliminat", "released", "lock"]
            .contains { lowered.contains($0) }
    }

    /// Visits every key/value pair in nested dictionaries and arrays. A Data
    /// value that is itself a property list (the records wrap the descriptor in
    /// a keyed archive under `assetDescriptor`) is decoded and walked too, with
    /// `!` after the key that held it, so its keys reach the size and state
    /// heuristics and the dump.
    static func walk(_ value: Any, at keyPath: String, depth: Int = 0, visit: (String, String, Any) -> Void) {
        guard depth < 12 else { return }
        if let dictionary = value as? [String: Any] {
            for (key, inner) in dictionary {
                let path = keyPath.isEmpty ? key : keyPath + "." + key
                visit(path, key, inner)
                walk(inner, at: path, depth: depth + 1, visit: visit)
            }
        } else if let array = value as? [Any] {
            for (index, inner) in array.enumerated() {
                walk(inner, at: keyPath + "[\(index)]", depth: depth + 1, visit: visit)
            }
        } else if let data = value as? Data, let embedded = embeddedPropertyList(data) {
            walk(embedded, at: keyPath + "!", depth: depth + 1, visit: visit)
        }
    }

    /// A property list hidden in a Data value, or nil. Keyed archives are
    /// binary plists whose `$objects` hold each encoded object's keys.
    static func embeddedPropertyList(_ data: Data) -> Any? {
        guard data.count > 8 else { return nil }
        let head = data.prefix(6)
        guard head == Data("bplist".utf8) || head.first == UInt8(ascii: "<") else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    /// The property list a record holds under `assetDescriptor`, decoded, for the dump.
    static func dumpable(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, inner) in dictionary {
                if let data = inner as? Data, let embedded = embeddedPropertyList(data) {
                    out[key + "!"] = dumpable(embedded)
                } else {
                    out[key] = dumpable(inner)
                }
            }
            return out
        }
        if let array = object as? [Any] { return array.map(dumpable) }
        return object
    }

    /// The longest catalog asset type the file name contains, so
    /// `...UAF.FM.GenerativeModels...` is not read as a shorter type's record.
    static func inferType(_ fileName: String) -> String? {
        let types = Catalog.sets.map(\.assetType) + Catalog.sets.flatMap { $0.recovery?.additionalAssetSets ?? [] }
        return types.filter { fileName.contains($0) }.max { $0.count < $1.count }
    }

    /// Sums the records of each set. A set with no readable record of its type
    /// gets `bytes == nil`, never zero: nil means not known, zero means known empty.
    static func measure(_ sets: [ModelSet], reading: DescriptorReading) -> [SetMeasurement] {
        sets.map { set in
            let records = reading.records.filter { $0.assetType == set.assetType }
            var total: Int64 = 0
            var keys = Set<String>()
            var counted = false
            for record in records {
                if let size = record.countedSize {
                    total += size.bytes
                    keys.insert(size.key)
                    counted = true
                }
            }
            let locks = reading.lockEntries.filter { $0.contains(set.assetType) }
            let bytes: Int64? = records.isEmpty ? nil : (counted ? total : nil)
            return SetMeasurement(set: set, records: records, bytes: bytes, sizeKeys: keys,
                                  locks: locks, folder: folderState(set.assetType))
        }
    }

    /// macOS will not list some asset folders even to an admin, but it still
    /// says how many entries a folder has and whether a named entry exists.
    /// After removal a folder keeps at most purpose_auto with the catalog XML
    /// and its .purged copy. Anything else counts as files (RemoveMacAI's rule).
    static func folderState(_ assetType: String, root: String = assetsRoot) -> FolderState {
        let name = assetType.replacingOccurrences(of: ".", with: "_")
        let folder = root + "/" + name
        var info = stat()
        if lstat(folder, &info) != 0 { return errno == ENOENT ? .missing : .unknown }
        let files = FileManager.default
        guard let top = entryCount(folder) else { return .unknown }
        let purpose = folder + "/purpose_auto"
        guard files.fileExists(atPath: purpose) else { return top > 0 ? .holdsFiles : .empty }
        guard let inner = entryCount(purpose) else { return .unknown }
        let catalog = [name + ".xml", name + ".xml.purged"].filter { files.fileExists(atPath: purpose + "/" + $0) }
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

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
        var locks: [String] = []
        do {
            locks = try fileManager.contentsOfDirectory(atPath: locker).sorted()
        } catch {
            errors.append("\(locker): \(error.localizedDescription)")
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
        let type = strings["AssetType"] ?? strings["_AssetType"] ?? strings["assetType"] ?? inferType(fileName)
        let specifier = strings["AssetSpecifier"] ?? strings["_AssetSpecifier"] ?? strings["assetSpecifier"]
        let version = strings["AssetVersion"] ?? strings["_AssetVersion"] ?? strings["assetVersion"]
        return DescriptorRecord(path: path, fileName: fileName, assetType: type, assetSpecifier: specifier,
                                assetVersion: version, sizes: sizes, hints: hints, raw: object, unreadable: nil)
    }

    private static func stateKey(_ lowered: String) -> Bool {
        ["state", "status", "present", "installed", "purge", "eliminat", "released", "lock"]
            .contains { lowered.contains($0) }
    }

    /// Visits every key/value pair in nested dictionaries and arrays.
    static func walk(_ value: Any, at keyPath: String, visit: (String, String, Any) -> Void) {
        if let dictionary = value as? [String: Any] {
            for (key, inner) in dictionary {
                let path = keyPath.isEmpty ? key : keyPath + "." + key
                visit(path, key, inner)
                walk(inner, at: path, visit: visit)
            }
        } else if let array = value as? [Any] {
            for (index, inner) in array.enumerated() {
                walk(inner, at: keyPath + "[\(index)]", visit: visit)
            }
        }
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

import Foundation

/// Rebuilds the object graph of an NSKeyedArchiver archive read as a plain
/// property list, so the descriptor's fields can be read by key path without
/// unarchiving Apple's private classes. PropertyListSerialization hands UID
/// references back as opaque CFKeyedArchiverUID values whose description is
/// `<CFKeyedArchiverUID 0x…>{value = N}`; N indexes `$objects`.
enum KeyedArchive {
    static func isArchive(_ plist: Any) -> Bool {
        guard let dictionary = plist as? [String: Any] else { return false }
        return dictionary["$archiver"] as? String == "NSKeyedArchiver" && dictionary["$objects"] is [Any]
    }

    /// The archive's root object with every reference followed, or nil when
    /// the plist is not a keyed archive. Dictionaries keep their keys, arrays
    /// their order, `$class` entries are dropped, `$null` becomes NSNull.
    static func resolved(_ plist: Any) -> Any? {
        guard isArchive(plist), let archive = plist as? [String: Any],
              let objects = archive["$objects"] as? [Any],
              let top = archive["$top"] as? [String: Any]
        else { return nil }
        let rootReference = top["root"] ?? top.values.first
        guard let rootReference else { return nil }
        var visiting = Set<Int>()
        return resolve(rootReference, objects: objects, visiting: &visiting, depth: 0)
    }

    static func uid(_ value: Any) -> Int? {
        let description = String(describing: value)
        guard description.hasPrefix("<CFKeyedArchiverUID"), let open = description.range(of: "{value = "),
              let close = description.range(of: "}", range: open.upperBound..<description.endIndex)
        else { return nil }
        return Int(description[open.upperBound..<close.lowerBound])
    }

    private static func resolve(_ value: Any, objects: [Any], visiting: inout Set<Int>, depth: Int) -> Any {
        guard depth < 64 else { return "<too deep>" }
        if let index = uid(value) {
            guard index >= 0, index < objects.count else { return "<bad reference \(index)>" }
            guard !visiting.contains(index) else { return "<cycle to \(index)>" }
            visiting.insert(index)
            defer { visiting.remove(index) }
            return resolve(objects[index], objects: objects, visiting: &visiting, depth: depth + 1)
        }
        if let text = value as? String {
            return text == "$null" ? NSNull() : text
        }
        if let array = value as? [Any] {
            return array.map { resolve($0, objects: objects, visiting: &visiting, depth: depth + 1) }
        }
        guard let dictionary = value as? [String: Any] else { return value }
        // NSDictionary and NSArray are encoded as parallel NS.keys/NS.objects lists.
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
        if let text = dictionary["NS.string"] as? String { return text }
        if let data = dictionary["NS.data"] { return data }
        if let time = dictionary["NS.time"] as? Double { return Date(timeIntervalSinceReferenceDate: time) }
        var out: [String: Any] = [:]
        for (key, inner) in dictionary where key != "$class" {
            out[key] = resolve(inner, objects: objects, visiting: &visiting, depth: depth + 1)
        }
        return out
    }
}

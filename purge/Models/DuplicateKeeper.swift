import Foundation

/// Suggests which copy in a duplicate group is worth keeping, so the "keep one,
/// delete the rest" action can pre-select a survivor.
///
/// This only *suggests*. The user always sees the choice and can pick a different
/// copy before anything moves to Trash. Issue #17 rejected choosing the survivor
/// *silently*; a visible, overridable suggestion is a different thing.
///
/// The pick is deterministic and based only on the path, because that is all a
/// duplicate group agrees on. Every copy is byte-identical and the same size, so
/// content tells them apart in no way. Signals, most important first:
///
/// 1. **Where it lives.** A copy in a cache or temporary folder is disposable;
///    one in Downloads or on the Desktop is a landing zone; anything else is
///    treated as a real home. Keep the realest home.
/// 2. **What it's called.** A name Finder's Duplicate gave it, in any language
///    (`… copy`, `… Kopie 2`, `…_副本`), or a browser's `… (1)`, is the copy, not
///    the original. Keep the canonical name.
/// 3. **Tie-breakers.** Fewer path components, then the path itself, so the same
///    group always suggests the same keeper across scans.
nonisolated enum DuplicateKeeper {
    /// The id of the copy to keep, or nil for an empty group.
    static func suggestedKeeperID(among files: [LargeFile]) -> String? {
        files.min { sortKey(for: $0) < sortKey(for: $1) }?.id
    }

    /// Lower sorts first, and first is the keeper.
    private static func sortKey(for file: LargeFile) -> (Int, Int, Int, String) {
        let path = file.id // already the standardized path
        let base = file.path.deletingPathExtension().lastPathComponent
        return (
            locationRank(path),
            copyNameRank(base),
            path.split(separator: "/").count,
            path
        )
    }

    /// Folders whose copy is the disposable one, compared without case. Only
    /// folders a duplicate can be found in: the Large Files walk never enters
    /// hidden, build or dependency folders (`LargeFileScanPolicy`), so markers
    /// such as `node_modules` or `DerivedData` could never match (#190).
    /// `.cache` is here because AI model rows come from `~/.cache` and
    /// `~/Library/Caches`.
    static let disposableFolders = ["/caches/", "/.cache/", "/tmp/"]

    /// 0 for a real home, 1 for a landing zone (Downloads/Desktop), 2 for a
    /// disposable location. The keeper wants the lowest.
    private static func locationRank(_ path: String) -> Int {
        let lower = path.lowercased()
        if disposableFolders.contains(where: lower.contains) { return 2 }
        if lower.contains("/downloads/") || lower.contains("/desktop/") { return 1 }
        return 0
    }

    /// The names Finder's Duplicate gives a copy, in every language macOS
    /// ships: the first copy, then the numbered ones. `{name}` is the original
    /// name and `{n}` the number. Read from FinderKit's
    /// `LocalizableMerged.loctable` (`N4_V1` and `N4_V2`) on macOS 27.
    static let finderCopyNames = [
        "{name} copy", "{name} copy {n}", // en
        "نسخة من {name}", "نسخة {n} من {name}", // ar
        "{name} (còpia)", "{name} (còpia {n})", // ca
        "{name} (kopie)", "{name} (kopie {n})", // cs
        "{name}-kopi", "{name}-kopi {n}", // da, no
        "{name} Kopie", "{name} Kopie {n}", // de
        "{name} αντίγραφο", "{name} αντίγραφο {n}", // el
        "{name} copia", "{name} copia {n}", // es, it
        "Copia de {name}", "Copia de {name} {n}", // es_419, es_US
        "{name} kopio", "{name} kopio {n}", // fi
        "{name} copie", "{name} copie {n}", // fr
        "עותק של {name}", "עותק {n} של {name}", // he
        "{name} कॉपी", "{name} कॉपी {n}", // hi
        "{name} kopija", "{name} kopija {n}", // hr, sl
        "{name} másolat", "{name} másolat {n}", // hu
        "Salinan {name}", "Salinan {name} {n}", // id
        "{name}のコピー", "{name}のコピー{n}", // ja
        "{name} 복사본", "{name} 복사본 {n}", // ko
        "salinan {name}", "salinan {n} {name}", // ms
        "{name} kopie", "{name} kopie {n}", // nl
        "{name}-kopia", "{name}-kopia {n}", // pl
        "{name} - cópia", "{name} - cópia {n}", // pt
        "{name} - copie", "{name} - copie {n}", // ro
        "{name}\u{00A0}— копия", "{name}\u{00A0}— копия {n}", // ru
        "{name} - kópia", "{name} - kópia {n}", // sk
        "{name} (kopia)", "{name} (kopia {n})", // sv
        "{name} สำเนา", "{name} สำเนา {n}", // th
        "{name} kopyası", "{name} kopyası {n}", // tr
        "{name} копія", "{name} копія {n}", // uk
        "Bản sao {name}", "Bản sao {name} {n}", // vi
        "{name}_副本", "{name}_副本{n}", // zh_CN
        "{name}副本", "{name}副本{n}", // zh_HK
        "{name}拷貝", "{name}拷貝{n}", // zh_TW
    ]

    /// Finder's names, plus the `report (1)` a browser gives a second download.
    private static let copyNamePatterns: [NSRegularExpression] =
        (finderCopyNames + ["{name} ({n})"]).compactMap { template in
            let body = template.precomposedStringWithCanonicalMapping
                .components(separatedBy: "{name}")
                .map { part in
                    part.components(separatedBy: "{n}")
                        .map(NSRegularExpression.escapedPattern(for:))
                        .joined(separator: #"\d+"#)
                }
                .joined(separator: ".+")
            return try? NSRegularExpression(pattern: "^\(body)$", options: [.caseInsensitive])
        }

    /// 1 when the name looks like a copy Finder or a browser made, else 0. The
    /// keeper wants 0.
    private static func copyNameRank(_ base: String) -> Int {
        // A name can reach the disk decomposed (`cópia` as `o` plus a combining
        // accent), which the precomposed patterns would not match.
        let name = base.precomposedStringWithCanonicalMapping
        let range = NSRange(name.startIndex..., in: name)
        return copyNamePatterns.contains { $0.firstMatch(in: name, range: range) != nil } ? 1 : 0
    }
}

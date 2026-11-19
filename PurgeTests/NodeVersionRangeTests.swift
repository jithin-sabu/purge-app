import Testing
@testable import Purge

/// The npm version ranges Vite+ pins are read with (#398).
@Suite("Node version ranges (#398)")
struct NodeVersionRangeTests {

    private func takes(_ range: String, _ version: String) -> Bool {
        guard let parsed = NodeVersionRange(range), let version = NodeVersionRange.Version(version) else {
            Issue.record("could not read \(range) or \(version)")
            return false
        }
        return parsed.contains(version)
    }

    @Test(arguments: [
        ("22.1.0", "22.1.0", true), ("22.1.0", "22.1.1", false), ("v22.1.0", "22.1.0", true),
        ("=22.1.0", "22.1.0", true), ("22", "22.9.9", true), ("22", "23.0.0", false),
        ("22.x", "22.0.0", true), ("22.1", "22.1.9", true), ("22.1", "22.2.0", false),
        ("22.1.x", "22.1.4", true), ("*", "1.0.0", true), ("", "4.0.0", true), ("x", "9.9.9", true),
        ("^22.1.0", "22.9.0", true), ("^22.1.0", "22.0.9", false), ("^22.1.0", "23.0.0", false),
        ("^0.2.3", "0.2.9", true), ("^0.2.3", "0.3.0", false), ("^0.0.3", "0.0.4", false),
        ("^0.0", "0.0.9", true), ("^0.0", "0.1.0", false), ("^0", "0.9.0", true), ("^22", "22.0.0", true),
        ("~22.1.0", "22.1.9", true), ("~22.1.0", "22.2.0", false), ("~22", "22.9.0", true),
        ("~22", "23.0.0", false), ("~>22.1", "22.1.3", true),
        (">=22.1.0", "22.1.0", true), (">=22.1.0", "22.0.9", false), (">22.1.0", "22.1.0", false),
        (">22.1", "22.2.0", true), (">22.1", "22.1.9", false), (">22", "23.0.0", true), (">22", "22.9.0", false),
        ("<22.1.0", "22.0.9", true), ("<22.1.0", "22.1.0", false), ("<22", "21.9.9", true), ("<22", "22.0.0", false),
        ("<=22.1", "22.1.9", true), ("<=22.1", "22.2.0", false), ("<=22.1.0", "22.1.0", true),
        (">= 20 < 22", "21.5.0", true), (">=20 <22", "22.0.0", false),
        ("20 - 22", "22.9.0", true), ("20 - 22", "23.0.0", false), ("20.1 - 22.1.0", "20.0.9", false),
        ("20.1 - 22.1.0", "22.1.0", true), ("20.1 - 22.1.0", "22.1.1", false),
        ("^20.19.0 || ^22.12.0 || >=24.0.0", "22.13.0", true), ("^20.19.0 || ^22.12.0 || >=24.0.0", "22.11.0", false),
        ("^20.19.0 || ^22.12.0 || >=24.0.0", "26.0.0", true), (">*", "1.0.0", false), ("<*", "1.0.0", false),
    ])
    func rangesTakeWhatNpmTakes(range: String, version: String, expected: Bool) {
        #expect(takes(range, version) == expected, "\(range) on \(version)")
    }

    @Test(arguments: [
        "lts/*", "latest", "node", "hydrogen", "22.1.0-rc.1", "^22.1.0-rc.1", "22.1.0+build", "1.2.3.4",
        "22.x.1", ">=", "> = 22", "22 -", "abc || 22", "22.1.0 && 23", "v", ">=v", "１２",
    ])
    func everythingElseIsUnread(text: String) {
        #expect(NodeVersionRange(text) == nil, "\(text)")
    }

    @Test
    func theNewestInstalledMatchIsPicked() {
        let installed = ["20.1.0", "20.9.0", "22.1.0", "22.10.0", "22.9.0", "27.0.0-rc.1", "junk"]
        #expect(NodeVersionRange("^22")?.newestMatch(in: installed) == "22.10.0")
        #expect(NodeVersionRange(">=20 <22")?.newestMatch(in: installed) == "20.9.0")
        #expect(NodeVersionRange(">=27")?.newestMatch(in: installed) == nil)
        #expect(NodeVersionRange("*")?.newestMatch(in: installed) == "22.10.0")
    }
}

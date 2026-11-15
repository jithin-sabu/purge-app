import Foundation

/// Merges cache scan rows that share the same `explanations.json` definition key.
enum DefinitionCacheGrouper {
    nonisolated static func group(_ items: [CacheItem]) -> [CacheItem] {
        var ungrouped: [CacheItem] = []
        var byKey: [String: [CacheItem]] = [:]

        for item in items {
            guard let key = item.definitionKey else {
                ungrouped.append(item)
                continue
            }
            byKey[key, default: []].append(item)
        }

        var grouped: [CacheItem] = []
        for (key, members) in byKey {
            grouped.append(merge(key: key, members: members))
        }

        let combined = ungrouped + grouped
        return combined.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private nonisolated static func merge(key: String, members: [CacheItem]) -> CacheItem {
        if members.count == 1, let only = members.first, only.locations.count == 1 {
            return only
        }

        var seenPaths = Set<String>()
        var locations: [CacheLocation] = []
        for member in members {
            for loc in member.locations {
                let pathKey = loc.path.standardizedFileURL.path
                guard !seenPaths.contains(pathKey) else { continue }
                seenPaths.insert(pathKey)
                locations.append(loc)
            }
        }
        locations.sort { $0.sizeBytes > $1.sizeBytes }

        let isSelected = members.contains(where: \.isSelected)
        let safetyInfo = mergedSafetyInfo(key: key, members: members)
        let appName = safetyInfo.headline

        return CacheItem(
            definitionKey: key,
            locations: locations,
            appName: appName,
            isSelected: isSelected,
            safetyInfo: safetyInfo,
            reinstallSafety: members.map(\.reinstallSafety).max(by: reinstallPriority) ?? .notApplicable,
            gitStatus: members.map(\.gitStatus).max(by: gitPriority) ?? .unknown
        )
    }

    private nonisolated static func mergedSafetyInfo(key: String, members: [CacheItem]) -> SafetyInfo {
        var infos: [SafetyInfo] = []
        for member in members {
            for loc in member.locations {
                let fallback = member.appName
                if let pathOverride = UserOverridesStore.read(path: loc.path) {
                    infos.append(UserOverridesStore.safetyInfo(from: pathOverride, friendlyHeadline: fallback))
                } else {
                    infos.append(member.safetyInfo)
                }
            }
        }

        if let record = ExplanationDatabase.record(forKey: key) {
            let bundled = ExplanationDatabase.safetyInfo(from: record)
            if infos.isEmpty {
                return bundled
            }
            let level = infos.map(\.level).max(by: { $0.sortOrder < $1.sortOrder }) ?? bundled.level
            let primary = infos.first { $0.level == level } ?? bundled
            if primary.level == bundled.level && UserOverridesStore.read(path: members[0].path) == nil {
                return bundled
            }
            return SafetyInfo(
                level: level,
                headline: bundled.headline,
                explanation: primary.explanation,
                recoverySteps: primary.recoverySteps,
                reinstallCommand: primary.reinstallCommand
            )
        }

        guard let first = infos.first else {
            return members[0].safetyInfo
        }
        let level = infos.map(\.level).max(by: { $0.sortOrder < $1.sortOrder }) ?? first.level
        let primary = infos.first { $0.level == level } ?? first
        return SafetyInfo(
            level: level,
            headline: primary.headline,
            explanation: primary.explanation,
            recoverySteps: primary.recoverySteps,
            reinstallCommand: primary.reinstallCommand
        )
    }

    private nonisolated static func reinstallPriority(_ a: ReinstallSafetyStatus, _ b: ReinstallSafetyStatus) -> Bool {
        reinstallRank(a) < reinstallRank(b)
    }

    private nonisolated static func reinstallRank(_ status: ReinstallSafetyStatus) -> Int {
        switch status {
        case .missingLockfile: return 2
        case .reinstallable: return 1
        case .notApplicable: return 0
        }
    }

    private nonisolated static func gitPriority(_ a: GitWorktreeStatus, _ b: GitWorktreeStatus) -> Bool {
        gitRank(a) < gitRank(b)
    }

    private nonisolated static func gitRank(_ status: GitWorktreeStatus) -> Int {
        switch status {
        case .dirty: return 2
        case .unknown: return 1
        case .clean: return 0
        }
    }
}

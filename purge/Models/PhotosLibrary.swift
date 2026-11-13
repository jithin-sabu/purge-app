import Foundation

nonisolated enum PhotosAccess: Sendable {
    case notDetermined, allowed, limited, denied, restricted

    var canRead: Bool { self == .allowed || self == .limited }
}

nonisolated enum PhotosCategory: CaseIterable, Identifiable, Sendable {
    case videos, bursts, rawPairs, screenRecordings, screenshots

    var id: Self { self }
    var title: String {
        switch self {
        case .videos: String(localized: "Videos")
        case .bursts: String(localized: "Bursts")
        case .rawPairs: String(localized: "RAW+JPEG pairs")
        case .screenRecordings: String(localized: "Screen recordings")
        case .screenshots: String(localized: "Screenshots")
        }
    }
}

/// Value metadata only. No library URLs or filesystem deletion handles leave PhotoKit.
nonisolated struct PhotosAssetMetadata: Equatable, Sendable, Identifiable {
    enum Kind: Sendable { case photo, video }

    let id: String
    var filename: String
    var kind: Kind = .photo
    var created: Date?
    var modified: Date?
    var width = 0
    var height = 0
    var duration: Double = 0
    var isScreenshot = false
    var isScreenRecording = false
    var burstID: String?
    var isBurstPick = false
    var isBurstRepresentative = false
    var isRAWJPEGPair = false
    /// Two original photos in one asset, such as RAW+JPEG or RAW+HEIF. Removing
    /// the asset removes both, so it is never offered.
    var hasPairedOriginals = false
    var isFavorite = false
    var isHidden = false
    var canDelete = true
    /// Detect resource changes as well as changes to the asset's properties.
    var resources: [String] = []
}

nonisolated struct PhotosLibraryItem: Identifiable, Sendable {
    let metadata: PhotosAssetMetadata
    var originalBytes: Int64?
    var id: String { metadata.id }
}

nonisolated struct PhotosLibrarySnapshot: Sendable {
    var items: [PhotosLibraryItem] = []

    var burstKeepers: Set<String> {
        Self.burstKeepers(in: items.map(\.metadata))
    }

    static func burstKeepers(in assets: [PhotosAssetMetadata]) -> Set<String> {
        let groups = Dictionary(grouping: assets.filter { $0.burstID != nil }, by: { $0.burstID! })
        return Set(groups.values.flatMap { members in
            let picks = members.filter { $0.isBurstPick || $0.isBurstRepresentative }
            // Missing pick metadata must never allow the last burst member to go.
            return (picks.isEmpty ? Array(members.sorted { $0.id < $1.id }.prefix(1)) : picks).map(\.id)
        })
    }

    func canSelect(_ item: PhotosLibraryItem) -> Bool {
        Self.canRemove(item.metadata, keepers: burstKeepers)
    }

    static func canRemove(_ asset: PhotosAssetMetadata, keepers: Set<String>) -> Bool {
        asset.canDelete && !asset.isHidden && !asset.isRAWJPEGPair && !asset.hasPairedOriginals
            && !keepers.contains(asset.id)
            && (asset.kind == .video || asset.isScreenshot || asset.burstID != nil)
    }

    func items(in category: PhotosCategory) -> [PhotosLibraryItem] {
        items.filter { item in
            let asset = item.metadata
            guard !asset.isHidden else { return false }
            switch category {
            case .videos: return asset.kind == .video
            case .bursts: return asset.burstID != nil
            case .rawPairs: return asset.isRAWJPEGPair
            case .screenRecordings: return asset.isScreenRecording
            case .screenshots: return asset.isScreenshot
            }
        }.sorted { lhs, rhs in
            if category == .bursts, lhs.metadata.burstID != rhs.metadata.burstID {
                return (lhs.metadata.burstID ?? "") < (rhs.metadata.burstID ?? "")
            }
            // Unknown never means zero; available original sizes sort first.
            if lhs.originalBytes != rhs.originalBytes {
                return (lhs.originalBytes ?? -1) > (rhs.originalBytes ?? -1)
            }
            return lhs.id < rhs.id
        }
    }
}

nonisolated struct PhotosRemovalPlan: Identifiable, Sendable {
    let id = UUID()
    let assets: [PhotosAssetMetadata]
    let bursts: [String: [PhotosAssetMetadata]]

    init?(snapshot: PhotosLibrarySnapshot, selectedIDs: Set<String>) {
        let selected = snapshot.items.filter { selectedIDs.contains($0.id) }
        let keepers = snapshot.burstKeepers
        guard !selected.isEmpty, selected.count == selectedIDs.count,
              selected.allSatisfy({ PhotosLibrarySnapshot.canRemove($0.metadata, keepers: keepers) }) else { return nil }
        assets = selected.map(\.metadata)
        let burstIDs = Set(assets.compactMap(\.burstID))
        bursts = Dictionary(grouping: snapshot.items.map(\.metadata).filter {
            $0.burstID.map(burstIDs.contains) ?? false
        }, by: { $0.burstID! })
    }

    /// All or nothing: a changed selection needs another review, never a broader delete.
    func validate(against fresh: [PhotosAssetMetadata]) -> Bool {
        guard !assets.isEmpty, Set(assets.map(\.id)).count == assets.count else { return false }
        let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keepers = PhotosLibrarySnapshot.burstKeepers(in: fresh)
        guard assets.allSatisfy({
            byID[$0.id] == $0 && PhotosLibrarySnapshot.canRemove($0, keepers: keepers)
        }) else { return false }
        for (id, members) in bursts {
            let now = fresh.filter { $0.burstID == id }.sorted { $0.id < $1.id }
            guard now == members.sorted(by: { $0.id < $1.id }) else { return false }
        }
        return true
    }
}

nonisolated enum PhotosLibraryError: Error, LocalizedError {
    case access, changed, failed

    var errorDescription: String? {
        switch self {
        case .access: String(localized: "Photos access is unavailable. Check Photos permissions in System Settings.")
        case .changed: String(localized: "The library changed. Nothing was removed. Refresh and review your selection again.")
        case .failed: String(localized: "Photos could not complete the request. Refresh the library before trying again.")
        }
    }
}

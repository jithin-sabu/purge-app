import Foundation
import Photos
import UniformTypeIdentifiers

/// PhotoKit is the sole authority for library reads and changes. Never hand its
/// resources to FileDeleter, Finder, or a filesystem scanner.
nonisolated enum PhotoKitLibrary {
    static func access() -> PhotosAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: .notDetermined
        case .authorized: .allowed
        case .limited: .limited
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .restricted
        }
    }

    static func requestAccess() async -> PhotosAccess {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return access()
    }

    @concurrent static func scan(sizes: PhotosSizeCache = .shared) async throws -> PhotosLibrarySnapshot {
        guard access().canRead else { throw PhotosLibraryError.access }
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        let fetched = PHAsset.fetchAssets(with: options)
        var items: [PhotosLibraryItem] = []
        for index in 0..<fetched.count {
            try Task.checkCancellation()
            let asset = fetched.object(at: index)
            guard asset.mediaType == .image || asset.mediaType == .video else { continue }
            let resources = PHAssetResource.assetResources(for: asset)
            let value = metadata(asset, resources: resources)
            guard value.kind == .video || value.isScreenshot || value.burstID != nil || value.isRAWJPEGPair else { continue }
            var bytes: Int64?
            if let original = resources.first(where: { $0.type == .video }) {
                if let size = knownSize(original) {
                    bytes = size
                } else if let size = sizes.size(for: value) {
                    bytes = size
                } else {
                    // Public, local-only streaming on older systems. Keep only a byte
                    // count, never a whole video in memory or an exported library file.
                    // Streaming reads the whole video, so each one is measured once.
                    bytes = await localSize(of: original)
                    if let bytes { sizes.store(bytes, for: value) }
                }
            }
            try Task.checkCancellation()
            items.append(PhotosLibraryItem(metadata: value, originalBytes: bytes))
        }
        guard access().canRead else { throw PhotosLibraryError.access }
        return PhotosLibrarySnapshot(items: items)
    }

    static func metadata(_ asset: PHAsset, resources: [PHAssetResource]? = nil) -> PhotosAssetMetadata {
        let resources = resources ?? PHAssetResource.assetResources(for: asset)
        var value = PhotosAssetMetadata(id: asset.localIdentifier, filename: resources.first.map(filename) ?? String(localized: "Untitled photo"))
        value.kind = asset.mediaType == .video ? .video : .photo
        value.created = asset.creationDate
        value.modified = asset.modificationDate
        value.width = asset.pixelWidth
        value.height = asset.pixelHeight
        value.duration = asset.duration
        value.isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        value.isScreenRecording = asset.mediaSubtypes.contains(.videoScreenRecording)
        value.burstID = asset.burstIdentifier
        value.isBurstPick = !asset.burstSelectionTypes.intersection([.autoPick, .userPick]).isEmpty
        value.isBurstRepresentative = asset.representsBurst
        let types = resources.map { ($0.type, $0.uniformTypeIdentifier) }
        value.isRAWJPEGPair = isRAWJPEGPair(types)
        value.hasPairedOriginals = hasPairedOriginals(types)
        value.isFavorite = asset.isFavorite
        value.isHidden = asset.isHidden
        value.canDelete = asset.canPerform(.delete)
        value.resources = resources.map { resource in
            var signature = "\(resource.type.rawValue)|\(resource.uniformTypeIdentifier)|\(filename(resource))"
            if let size = knownSize(resource) { signature += "|\(size)" }
            return signature
        }.sorted()
        return value
    }

    static func isRAWJPEGPair(_ resources: [(PHAssetResourceType, String)]) -> Bool {
        // An edited RAW can have a rendered JPEG too. Only two original photo
        // resources constitute a pair; adjustment previews and edits do not.
        let originals = resources.filter { $0.0 == .photo || $0.0 == .alternatePhoto }
            .compactMap { UTType($0.1) }
        return originals.contains(where: { $0.conforms(to: .rawImage) })
            && originals.contains(where: { $0.conforms(to: .jpeg) })
    }

    /// Any second original photo, whatever its type: RAW+HEIF, RAW+JPEG, or a
    /// type PhotoKit reports that Purge does not know. Deleting the asset would
    /// remove both, so this gate does not depend on recognising the types.
    static func hasPairedOriginals(_ resources: [(PHAssetResourceType, String)]) -> Bool {
        resources.filter { $0.0 == .photo || $0.0 == .alternatePhoto }.count > 1
    }

    private static func filename(_ resource: PHAssetResource) -> String {
        // CI also builds with the macOS 26 SDK. Keep the newer API optional at
        // compile time as well as at runtime; older SDKs use the streaming path.
        #if compiler(>=6.4)
        if #available(macOS 27, *) { return resource.filename ?? String(localized: "Untitled photo") }
        #endif
        return resource.originalFilename
    }

    private static func knownSize(_ resource: PHAssetResource) -> Int64? {
        #if compiler(>=6.4)
        if #available(macOS 27, *), let size = resource.dataSize, size >= 0 { return Int64(size) }
        #endif
        return nil
    }

    @concurrent static func remove(_ plan: PhotosRemovalPlan) async throws {
        guard access().canRead else { throw PhotosLibraryError.access }
        try Task.checkCancellation()
        let validation = PhotosChangeValidation()
        // The second fetch and gate live in the change block: no asynchronous
        // sizing or UI work may separate validation from the deletion request.
        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard access().canRead else { return }
                let options = PHFetchOptions()
                options.includeAllBurstAssets = true
                let selected = PHAsset.fetchAssets(withLocalIdentifiers: plan.assets.map(\.id), options: options)
                var byID: [String: PHAsset] = [:]
                selected.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
                for burstID in plan.bursts.keys {
                    PHAsset.fetchAssets(withBurstIdentifier: burstID, options: options).enumerateObjects { asset, _, _ in
                        byID[asset.localIdentifier] = asset
                    }
                }
                guard plan.validate(against: byID.values.map { metadata($0) }) else { return }
                let assets = plan.assets.compactMap { byID[$0.id] }
                guard assets.count == plan.assets.count else { return }
                validation.accept()
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch let error where isUserCancellation(error) {
            // Photos asked the user to confirm and they declined. Nothing changed.
            throw CancellationError()
        }
        guard validation.accepted else { throw PhotosLibraryError.changed }
    }

    static func isUserCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.Code.userCancelled.rawValue
    }

    private static func localSize(of resource: PHAssetResource) async -> Int64? {
        let request = PhotosDataRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard request.begin(continuation) else { return }
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = false
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options) {
                    request.add($0.count)
                } completionHandler: { error in
                    request.finish(success: error == nil)
                }
                request.attach(id)
            }
        } onCancel: {
            request.cancel()
        }
    }
}

/// Sizes measured by streaming, kept for the app session. The key holds the
/// modification date and resource list, so an edited or replaced video is
/// measured again. Only finished measurements are kept, never an unknown size.
/// Sizes only order rows and are never a deletion gate.
nonisolated final class PhotosSizeCache: @unchecked Sendable {
    static let shared = PhotosSizeCache()

    private struct Key: Hashable {
        let id: String
        let modified: Date?
        let resources: [String]

        init(_ asset: PhotosAssetMetadata) {
            id = asset.id
            modified = asset.modified
            resources = asset.resources
        }
    }

    private let lock = NSLock()
    private var sizes: [Key: Int64] = [:]

    func size(for asset: PhotosAssetMetadata) -> Int64? {
        lock.withLock { sizes[Key(asset)] }
    }

    func store(_ size: Int64, for asset: PhotosAssetMetadata) {
        lock.withLock { sizes[Key(asset)] = size }
    }
}

/// PhotoKit callbacks and cancellation can race on arbitrary queues.
private nonisolated final class PhotosChangeValidation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var accepted: Bool { lock.withLock { value } }
    func accept() { lock.withLock { value = true } }
}

nonisolated final class PhotosDataRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int64?, Never>?
    private var id: PHAssetResourceDataRequestID?
    private var cancelled = false
    private var bytes: Int64 = 0
    private var overflowed = false
    private let cancelRequest: @Sendable (PHAssetResourceDataRequestID) -> Void

    init(cancelRequest: @escaping @Sendable (PHAssetResourceDataRequestID) -> Void = {
        PHAssetResourceManager.default().cancelDataRequest($0)
    }) {
        self.cancelRequest = cancelRequest
    }

    func begin(_ continuation: CheckedContinuation<Int64?, Never>) -> Bool {
        let proceed = lock.withLock {
            guard !cancelled else { return false }
            self.continuation = continuation
            return true
        }
        if !proceed { continuation.resume(returning: nil) }
        return proceed
    }

    func attach(_ id: PHAssetResourceDataRequestID) {
        let shouldCancel = lock.withLock { self.id = id; return cancelled }
        if shouldCancel { cancelRequest(id) }
    }

    func add(_ count: Int) {
        lock.withLock {
            let sum = bytes.addingReportingOverflow(Int64(count))
            bytes = sum.partialValue
            overflowed = overflowed || sum.overflow
        }
    }

    func finish(success: Bool) {
        let result = lock.withLock { () -> (CheckedContinuation<Int64?, Never>?, Int64?) in
            defer { continuation = nil }
            return (continuation, success && !cancelled && !overflowed ? bytes : nil)
        }
        result.0?.resume(returning: result.1)
    }

    func cancel() {
        let result = lock.withLock { () -> (PHAssetResourceDataRequestID?, CheckedContinuation<Int64?, Never>?) in
            cancelled = true
            defer { continuation = nil }
            return (id, continuation)
        }
        if let id = result.0 { cancelRequest(id) }
        result.1?.resume(returning: nil)
    }
}

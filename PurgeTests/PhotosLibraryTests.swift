import Foundation
import Photos
import Testing
@testable import Purge

nonisolated enum PhotosFixtures {
    static func video(_ id: String, size: Int64? = nil) -> PhotosLibraryItem {
        var asset = PhotosAssetMetadata(id: id, filename: "\(id).mov", kind: .video)
        asset.created = Date(timeIntervalSince1970: 1_780_000_000)
        asset.duration = 120
        return PhotosLibraryItem(metadata: asset, originalBytes: size)
    }

    static func burst(_ id: String, group: String = "burst-1", pick: Bool = false, representative: Bool = false) -> PhotosLibraryItem {
        var asset = PhotosAssetMetadata(id: id, filename: "\(id).jpg")
        asset.burstID = group
        asset.isBurstPick = pick
        asset.isBurstRepresentative = representative
        return PhotosLibraryItem(metadata: asset)
    }

    static var screenshot: PhotosLibraryItem {
        var asset = PhotosAssetMetadata(id: "screenshot", filename: "Screenshot.png")
        asset.isScreenshot = true
        return PhotosLibraryItem(metadata: asset)
    }

    static var rawPair: PhotosLibraryItem {
        var asset = PhotosAssetMetadata(id: "raw-pair", filename: "Landscape.RAW + Landscape.JPG")
        asset.isRAWJPEGPair = true
        return PhotosLibraryItem(metadata: asset)
    }

    static var library: PhotosLibrarySnapshot {
        var recording = video("Screen recording", size: 400_000_000)
        var metadata = recording.metadata
        metadata.isScreenRecording = true
        recording = PhotosLibraryItem(metadata: metadata, originalBytes: recording.originalBytes)
        return PhotosLibrarySnapshot(items: [
            video("Holiday", size: 2_400_000_000), video("Cloud-only"), recording,
            burst("IMG_1001", pick: true), burst("IMG_1002"), burst("IMG_1003"),
            screenshot, rawPair
        ])
    }
}

@Suite("Photos removal policy")
struct PhotosLibraryPolicyTests {
    @Test func rawEditsAreNotMistakenForTwoOriginals() {
        #expect(PhotoKitLibrary.isRAWJPEGPair([(.photo, "public.jpeg"), (.alternatePhoto, "com.adobe.raw-image")]))
        #expect(PhotoKitLibrary.isRAWJPEGPair([(.alternatePhoto, "public.jpeg"), (.photo, "com.adobe.raw-image")]))
        #expect(!PhotoKitLibrary.isRAWJPEGPair([(.photo, "com.adobe.raw-image"), (.fullSizePhoto, "public.jpeg")]))
        #expect(!PhotoKitLibrary.isRAWJPEGPair([(.photo, "public.jpeg"), (.pairedVideo, "com.apple.quicktime-movie")]))
        #expect(!PhotoKitLibrary.isRAWJPEGPair([(.photo, "unknown-resource-type")]))
    }

    @Test func anySecondOriginalPhotoIsAPair() {
        #expect(PhotoKitLibrary.hasPairedOriginals([(.photo, "public.heic"), (.alternatePhoto, "com.adobe.raw-image")]))
        #expect(PhotoKitLibrary.hasPairedOriginals([(.photo, "com.adobe.raw-image"), (.alternatePhoto, "public.jpeg")]))
        #expect(PhotoKitLibrary.hasPairedOriginals([(.photo, "public.heic"), (.alternatePhoto, "unknown-resource-type")]))
        #expect(!PhotoKitLibrary.hasPairedOriginals([(.photo, "com.adobe.raw-image"), (.fullSizePhoto, "public.jpeg")]))
        #expect(!PhotoKitLibrary.hasPairedOriginals([(.photo, "public.heic"), (.pairedVideo, "com.apple.quicktime-movie")]))
        #expect(!PhotoKitLibrary.hasPairedOriginals([(.photo, "public.heic")]))
        // RAW+HEIF is not listed as RAW+JPEG, but it is still a pair.
        #expect(!PhotoKitLibrary.isRAWJPEGPair([(.photo, "public.heic"), (.alternatePhoto, "com.adobe.raw-image")]))
    }

    @Test func aBurstMemberWithTwoOriginalsCannotBeRemoved() {
        var asset = PhotosFixtures.burst("raw-heif").metadata
        asset.hasPairedOriginals = true
        let pair = PhotosLibraryItem(metadata: asset)
        let library = PhotosLibrarySnapshot(items: [PhotosFixtures.burst("pick", pick: true), pair])
        #expect(!library.canSelect(pair))
        #expect(PhotosRemovalPlan(snapshot: library, selectedIDs: [pair.id]) == nil)
    }

    @Test func failedOrCancelledResourceReadsHaveUnknownSize() async {
        let failed = PhotosDataRequest(cancelRequest: { _ in })
        let failedSize = await withCheckedContinuation { continuation in
            _ = failed.begin(continuation)
            failed.add(128)
            failed.finish(success: false)
            failed.finish(success: true) // A late callback must not resume twice.
        }
        #expect(failedSize == nil)
        let cancelled = PhotosDataRequest(cancelRequest: { _ in })
        cancelled.cancel()
        let cancelledSize = await withCheckedContinuation { continuation in
            #expect(!cancelled.begin(continuation))
        }
        #expect(cancelledSize == nil)
    }

    @Test func cancellationBetweenRequestAndIdentifierCancelsTheRequest() async {
        nonisolated final class Cancellations: @unchecked Sendable {
            let lock = NSLock()
            private var ids: [Int32] = []
            func add(_ id: Int32) { lock.withLock { ids.append(id) } }
            var all: [Int32] { lock.withLock { ids } }
        }
        let cancellations = Cancellations()
        let request = PhotosDataRequest(cancelRequest: { cancellations.add($0) })
        let size = await withCheckedContinuation { continuation in
            _ = request.begin(continuation)
            request.add(128)
            request.cancel()
            request.attach(42)
            request.finish(success: true)
        }
        #expect(size == nil)
        #expect(cancellations.all == [42])
    }

    @Test func overflowingResourceSizeIsUnknown() async {
        let request = PhotosDataRequest(cancelRequest: { _ in })
        let size = await withCheckedContinuation { continuation in
            _ = request.begin(continuation)
            request.add(Int.max)
            request.add(1)
            request.finish(success: true)
        }
        #expect(size == nil)
    }

    @Test func unknownSizesSortAfterKnownSizesAndDoNotBecomeZero() {
        let library = PhotosLibrarySnapshot(items: [
            PhotosFixtures.video("unknown"), PhotosFixtures.video("small", size: 10),
            PhotosFixtures.video("large", size: 100), PhotosFixtures.video("empty", size: 0)
        ])
        #expect(library.items(in: .videos).map(\.id) == ["large", "small", "empty", "unknown"])
        #expect(library.items(in: .videos).last?.originalBytes == nil)
    }

    @Test func categoriesUseMetadataAndSelectionRefusesOrdinaryPhotos() {
        let library = PhotosFixtures.library
        #expect(library.items(in: .screenRecordings).count == 1)
        #expect(library.items(in: .screenshots).map(\.id) == ["screenshot"])
        #expect(library.items(in: .rawPairs).map(\.id) == ["raw-pair"])
        let photo = PhotosLibraryItem(metadata: PhotosAssetMetadata(id: "ordinary", filename: "ordinary.jpg"))
        #expect(!PhotosLibrarySnapshot(items: [photo]).canSelect(photo))
    }

    @Test func pairsCannotBeDeletedEvenWhenAlsoInABurst() {
        var asset = PhotosFixtures.rawPair.metadata
        asset.burstID = "burst-1"
        let pair = PhotosLibraryItem(metadata: asset)
        let library = PhotosLibrarySnapshot(items: [PhotosFixtures.burst("pick", pick: true), pair])
        #expect(!library.canSelect(pair))
        #expect(PhotosRemovalPlan(snapshot: library, selectedIDs: [pair.id]) == nil)
    }

    @Test func everyPickAndRepresentativeIsProtected() {
        let assets = [
            PhotosFixtures.burst("user-pick", pick: true),
            PhotosFixtures.burst("auto-pick", pick: true),
            PhotosFixtures.burst("representative", representative: true),
            PhotosFixtures.burst("other")
        ]
        let library = PhotosLibrarySnapshot(items: assets)
        #expect(library.burstKeepers == ["user-pick", "auto-pick", "representative"])
        #expect(assets.map { library.canSelect($0) } == [false, false, false, true])
    }

    @Test func noPickKeepsOneDeterministicallyAndSingleMemberNeverGoes() {
        let members = [PhotosFixtures.burst("b"), PhotosFixtures.burst("a")]
        let library = PhotosLibrarySnapshot(items: members)
        #expect(library.burstKeepers == ["a"])
        #expect(PhotosLibrarySnapshot(items: members.reversed()).burstKeepers == ["a"])
        let single = PhotosLibrarySnapshot(items: [members[0]])
        #expect(!single.canSelect(members[0]))
    }

    @Test func emptyUnknownAndMixedUnsafeSelectionsCannotMakeAPlan() {
        let library = PhotosFixtures.library
        #expect(PhotosRemovalPlan(snapshot: library, selectedIDs: []) == nil)
        #expect(PhotosRemovalPlan(snapshot: library, selectedIDs: ["missing"]) == nil)
        #expect(PhotosRemovalPlan(snapshot: library, selectedIDs: ["Holiday", "raw-pair"]) == nil)
        #expect(PhotosRemovalPlan(snapshot: library, selectedIDs: ["IMG_1001"]) == nil)
    }

    @Test func deletedAssetAbortsTheWholePlan() throws {
        let library = PhotosFixtures.library
        let plan = try #require(PhotosRemovalPlan(snapshot: library, selectedIDs: ["Holiday", "screenshot"]))
        #expect(plan.validate(against: library.items.map(\.metadata)))
        #expect(!plan.validate(against: library.items.filter { $0.id != "Holiday" }.map(\.metadata)))
    }

    @Test(arguments: ["edited", "hidden", "read-only", "raw-pair", "paired-originals", "resources", "favorite"])
    func changedAssetRequiresReview(_ change: String) throws {
        let library = PhotosFixtures.library
        let plan = try #require(PhotosRemovalPlan(snapshot: library, selectedIDs: ["Holiday"]))
        var fresh = library.items.map(\.metadata)
        let index = try #require(fresh.firstIndex { $0.id == "Holiday" })
        switch change {
        case "edited": fresh[index].modified = .now
        case "hidden": fresh[index].isHidden = true
        case "read-only": fresh[index].canDelete = false
        case "raw-pair": fresh[index].isRAWJPEGPair = true
        case "paired-originals": fresh[index].hasPairedOriginals = true
        case "resources": fresh[index].resources = ["new resource"]
        case "favorite": fresh[index].isFavorite = true
        default: Issue.record("Unexpected fixture")
        }
        #expect(!plan.validate(against: fresh))
    }

    @Test(arguments: ["new-pick", "member-added", "keeper-removed", "representative"])
    func burstChangesRequireReview(_ change: String) throws {
        let library = PhotosFixtures.library
        let plan = try #require(PhotosRemovalPlan(snapshot: library, selectedIDs: ["IMG_1002", "IMG_1003"]))
        var fresh = library.items.map(\.metadata)
        let index = try #require(fresh.firstIndex { $0.id == "IMG_1002" })
        switch change {
        case "new-pick": fresh[index].isBurstPick = true
        case "member-added": fresh.append(PhotosFixtures.burst("new").metadata)
        case "keeper-removed": fresh.removeAll { $0.id == "IMG_1001" }
        case "representative": fresh[index].isBurstRepresentative = true
        default: Issue.record("Unexpected fixture")
        }
        #expect(!plan.validate(against: fresh))
    }

    @Test func measuredSizesAreReusedUntilTheVideoChanges() {
        let cache = PhotosSizeCache()
        var asset = PhotosFixtures.video("clip").metadata
        asset.modified = Date(timeIntervalSince1970: 1_780_000_000)
        asset.resources = ["2|com.apple.quicktime-movie|clip.mov"]
        #expect(cache.size(for: asset) == nil)
        cache.store(1_000, for: asset)
        #expect(cache.size(for: asset) == 1_000)
        var edited = asset
        edited.modified = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(cache.size(for: edited) == nil)
        var replaced = asset
        replaced.resources = ["2|com.apple.quicktime-movie|other.mov"]
        #expect(cache.size(for: replaced) == nil)
        let another = PhotosAssetMetadata(id: "other", filename: asset.filename, kind: .video, modified: asset.modified, resources: asset.resources)
        #expect(cache.size(for: another) == nil)
    }

    @Test func decliningPhotosOwnPromptIsACancellation() {
        let cancelled = PHPhotosError.Code.userCancelled.rawValue
        #expect(PhotoKitLibrary.isUserCancellation(NSError(domain: PHPhotosErrorDomain, code: cancelled)))
        #expect(!PhotoKitLibrary.isUserCancellation(NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.accessUserDenied.rawValue)))
        #expect(!PhotoKitLibrary.isUserCancellation(NSError(domain: NSCocoaErrorDomain, code: cancelled)))
        #expect(!PhotoKitLibrary.isUserCancellation(PhotosLibraryError.failed))
    }

    @Test func unrelatedChangesDoNotBroadenOrBlockThePlan() throws {
        let library = PhotosFixtures.library
        let plan = try #require(PhotosRemovalPlan(snapshot: library, selectedIDs: ["screenshot"]))
        var fresh = library.items.map(\.metadata)
        fresh.append(PhotosFixtures.video("new").metadata)
        #expect(plan.validate(against: fresh))
        #expect(plan.assets.map(\.id) == ["screenshot"])
    }
}

private actor FakePhotosLibrary {
    var status: PhotosAccess = .notDetermined
    var requestedStatus: PhotosAccess = .allowed
    var library = PhotosFixtures.library
    var accessCalls = 0
    var permissionCalls = 0
    var scanCalls = 0
    var removed: [[String]] = []
    var failScan = false
    var failRemoval = false
    var cancelRemoval = false
    var delayScan = false
    var holdAccess = false
    var heldAccess: CheckedContinuation<Void, Never>?
    var holdRemoval = false
    var heldRemoval: CheckedContinuation<Void, Never>?

    nonisolated var client: PhotosLibraryClient {
        PhotosLibraryClient(access: { await self.access() }, requestAccess: { await self.request() }, scan: {
            try await self.scan()
        }, remove: { try await self.remove($0) })
    }

    func access() async -> PhotosAccess {
        accessCalls += 1
        if holdAccess { await withCheckedContinuation { heldAccess = $0 } }
        return status
    }
    func request() -> PhotosAccess { permissionCalls += 1; status = requestedStatus; return status }
    func setStatus(_ status: PhotosAccess) { self.status = status }
    func setRequestedStatus(_ status: PhotosAccess) { requestedStatus = status }
    func setFailScan() { failScan = true }
    func setFailRemoval() { failRemoval = true }
    func setCancelRemoval() { cancelRemoval = true }
    func setDelayScan(_ delay: Bool = true) { delayScan = delay }
    func setHoldAccess() { holdAccess = true }
    func finishAccess() { holdAccess = false; heldAccess?.resume(); heldAccess = nil }
    func setHoldRemoval() { holdRemoval = true }
    func finishRemoval() { holdRemoval = false; heldRemoval?.resume(); heldRemoval = nil }
    func changeLibrary() { library.items.removeAll { $0.id == "Holiday" } }

    func scan() async throws -> PhotosLibrarySnapshot {
        scanCalls += 1
        if delayScan { try await Task.sleep(for: .seconds(30)) }
        if failScan { throw PhotosLibraryError.failed }
        return library
    }

    func remove(_ plan: PhotosRemovalPlan) async throws {
        if holdRemoval { await withCheckedContinuation { heldRemoval = $0 } }
        guard !failRemoval else { throw PhotosLibraryError.failed }
        // What PhotoKitLibrary.remove throws when the user declines Photos' prompt.
        guard !cancelRemoval else { throw CancellationError() }
        guard plan.validate(against: library.items.map(\.metadata)) else { throw PhotosLibraryError.changed }
        removed.append(plan.assets.map(\.id))
        library.items.removeAll { plan.assets.map(\.id).contains($0.id) }
    }
}

@MainActor
@Suite("Photos store", .timeLimit(.minutes(1)))
struct PhotosLibraryStoreTests {
    private func settle(_ model: PhotosLibraryStore) async {
        while model.isScanning { await Task.yield() }
    }

    @Test func initializationDoesNotRequestOrReadPhotos() async {
        let fake = FakePhotosLibrary()
        let model = PhotosLibraryStore(client: fake.client)
        #expect(await fake.accessCalls == 0)
        #expect(await fake.permissionCalls == 0)
        #expect(await fake.scanCalls == 0)
        #expect(model.selectedIDs.isEmpty)
    }

    @Test func openingRequestsPermissionOnceAndNothingStartsSelected() async {
        let fake = FakePhotosLibrary()
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        await settle(model)
        #expect(await fake.permissionCalls == 1)
        #expect(model.hasScanned)
        #expect(model.selectedIDs.isEmpty)
        await model.open()
        await settle(model)
        #expect(await fake.permissionCalls == 1)
    }

    @Test(arguments: [PhotosAccess.denied, .restricted])
    func deniedPermissionNeverFetches(_ status: PhotosAccess) async {
        let fake = FakePhotosLibrary()
        await fake.setRequestedStatus(status)
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        #expect(model.access == status)
        #expect(await fake.scanCalls == 0)
        model.refresh()
        #expect(!model.isScanning)
    }

    @Test func categoryChangeAndRefreshClearSelectionsAndConfirmation() async throws {
        let fake = FakePhotosLibrary()
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        await settle(model)
        let video = try #require(model.visibleItems.first)
        model.select(video, selected: true)
        model.requestRemoval()
        #expect(model.pendingRemoval != nil)
        model.category = .screenshots
        #expect(model.selectedIDs.isEmpty)
        #expect(model.pendingRemoval == nil)
        model.select(PhotosFixtures.screenshot, selected: true)
        model.refresh()
        #expect(model.selectedIDs.isEmpty)
        await settle(model)
        #expect(model.selectedIDs.isEmpty)
    }

    @Test func hiddenCategoryAndProtectedItemsCannotBeSelected() async {
        let fake = FakePhotosLibrary()
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        await settle(model)
        model.select(PhotosFixtures.screenshot, selected: true)
        model.category = .rawPairs
        model.select(PhotosFixtures.rawPair, selected: true)
        model.category = .bursts
        model.select(PhotosFixtures.burst("IMG_1001", pick: true), selected: true)
        model.requestRemoval()
        #expect(model.pendingRemoval == nil)
        #expect(model.selectedIDs.isEmpty)
    }

    @Test func removalNeedsTheExactPendingConfirmationAndIsNotRepeated() async throws {
        let fake = FakePhotosLibrary()
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        await settle(model)
        let video = try #require(model.visibleItems.first)
        let unconfirmed = try #require(PhotosRemovalPlan(snapshot: model.snapshot, selectedIDs: [video.id]))
        await model.confirmRemoval(unconfirmed)
        #expect(await fake.removed.isEmpty)
        model.select(video, selected: true)
        model.requestRemoval()
        let plan = try #require(model.pendingRemoval)
        await model.confirmRemoval(plan)
        await model.confirmRemoval(plan)
        #expect(await fake.removed == [[video.id]])
        #expect(model.removedCount == 1)
        #expect(model.selectedIDs.isEmpty)
        #expect(!model.snapshot.items.contains { $0.id == video.id })
    }

    @Test func cancelledConfirmationCannotDeleteLater() async throws {
        let fake = FakePhotosLibrary()
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        await settle(model)
        model.select(try #require(model.visibleItems.first), selected: true)
        model.requestRemoval()
        let plan = try #require(model.pendingRemoval)
        model.pendingRemoval = nil
        await model.confirmRemoval(plan)
        #expect(await fake.removed.isEmpty)
    }

    @Test(arguments: ["permission", "changed", "failure"])
    func failedOrStaleRemovalNeverReportsSuccess(_ failure: String) async throws {
        let fake = FakePhotosLibrary()
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        await settle(model)
        model.select(try #require(model.visibleItems.first { $0.id == "Holiday" }), selected: true)
        model.requestRemoval()
        let plan = try #require(model.pendingRemoval)
        switch failure {
        case "permission": await fake.setStatus(.denied)
        case "changed": await fake.changeLibrary()
        case "failure": await fake.setFailRemoval()
        default: Issue.record("Unexpected fixture")
        }
        await model.confirmRemoval(plan)
        #expect(await fake.removed.isEmpty)
        #expect(model.removedCount == nil)
        #expect(model.message != nil)
        #expect(model.selectedIDs.isEmpty)
        #expect(model.snapshot.items.isEmpty)
    }

    @Test func failedScanHasNoDeletableResults() async {
        let fake = FakePhotosLibrary()
        await fake.setFailScan()
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        await settle(model)
        #expect(model.message != nil)
        #expect(model.snapshot.items.isEmpty)
        model.requestRemoval()
        #expect(model.pendingRemoval == nil)
    }

    @Test func stoppedScanCannotLandLater() async {
        let fake = FakePhotosLibrary()
        await fake.setDelayScan()
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        while await fake.scanCalls == 0 { await Task.yield() }
        model.stop()
        for _ in 0..<10 { await Task.yield() }
        #expect(!model.isScanning)
        #expect(model.snapshot.items.isEmpty)
        #expect(model.selectedIDs.isEmpty)
    }

    @Test func photosNeverJoinsAutomaticCleanTabs() {
        #expect(PurgeStore.Tab.reviewTabs.contains(.photos))
        #expect(!PurgeStore.Tab.cleanTabs.contains(.photos))
    }

    @Test func leavingWhileAccessIsCheckedDoesNotPromptOrScanLater() async {
        let fake = FakePhotosLibrary()
        await fake.setHoldAccess()
        let model = PhotosLibraryStore(client: fake.client)
        let opening = Task { await model.open() }
        while await fake.accessCalls == 0 { await Task.yield() }
        model.leave()
        await fake.finishAccess()
        await opening.value
        #expect(await fake.permissionCalls == 0)
        #expect(await fake.scanCalls == 0)
        #expect(!model.isScanning)
    }

    @Test func returningToThePageKeepsResultsAndSelectionWithoutAnotherScan() async throws {
        let fake = FakePhotosLibrary()
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        await settle(model)
        let video = try #require(model.visibleItems.first)
        model.select(video, selected: true)
        model.leave()
        await model.open()
        await settle(model)
        #expect(await fake.scanCalls == 1)
        #expect(model.hasScanned)
        #expect(model.selectedIDs == [video.id])
        model.requestRemoval()
        #expect(model.pendingRemoval?.assets.map(\.id) == [video.id])
    }

    @Test func leavingDuringAScanStopsItAndReturningScansAgain() async {
        let fake = FakePhotosLibrary()
        await fake.setDelayScan()
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        while await fake.scanCalls == 0 { await Task.yield() }
        model.leave()
        #expect(!model.isScanning)
        await fake.setDelayScan(false)
        await model.open()
        await settle(model)
        #expect(await fake.scanCalls == 2)
        #expect(model.hasScanned)
        #expect(model.selectedIDs.isEmpty)
    }

    @Test func accessChangedWhileAwayIsAppliedOnReturn() async throws {
        let fake = FakePhotosLibrary()
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        await settle(model)
        model.select(try #require(model.visibleItems.first), selected: true)
        model.leave()
        await fake.setStatus(.denied)
        await model.open()
        #expect(model.access == .denied)
        #expect(model.snapshot.items.isEmpty)
        #expect(model.selectedIDs.isEmpty)
        await fake.setStatus(.allowed)
        await model.open()
        await settle(model)
        #expect(await fake.scanCalls == 2)
        #expect(model.hasScanned)
        #expect(model.selectedIDs.isEmpty)
    }

    @Test func decliningPhotosPromptKeepsTheReviewAndRemovesNothing() async throws {
        let fake = FakePhotosLibrary()
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        await settle(model)
        let video = try #require(model.visibleItems.first)
        model.select(video, selected: true)
        model.requestRemoval()
        let plan = try #require(model.pendingRemoval)
        await fake.setCancelRemoval()
        await model.confirmRemoval(plan)
        #expect(await fake.removed.isEmpty)
        #expect(model.removedCount == nil)
        #expect(model.message == nil)
        #expect(!model.isRemoving)
        #expect(model.hasScanned)
        #expect(model.snapshot.items.contains { $0.id == video.id })
        #expect(model.selectedIDs == [video.id])
        #expect(model.pendingRemoval == nil)
        await model.confirmRemoval(plan)
        #expect(await fake.removed.isEmpty)
    }

    @Test func limitedAccessReadsOnlyTheProvidedLibraryWithoutAnotherPrompt() async {
        let fake = FakePhotosLibrary()
        await fake.setStatus(.limited)
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        await settle(model)
        #expect(model.access == .limited)
        #expect(await fake.permissionCalls == 0)
        #expect(model.hasScanned)
        #expect(model.selectedIDs.isEmpty)
    }

    @Test func aRemovalInFlightCannotStartAnotherOperation() async throws {
        let fake = FakePhotosLibrary()
        let model = PhotosLibraryStore(client: fake.client)
        await model.open()
        await settle(model)
        model.select(try #require(model.visibleItems.first), selected: true)
        model.requestRemoval()
        let plan = try #require(model.pendingRemoval)
        await fake.setHoldRemoval()
        let removal = Task { await model.confirmRemoval(plan) }
        while await fake.heldRemoval == nil { await Task.yield() }
        model.refresh()
        await model.open()
        await model.confirmRemoval(plan)
        #expect(!model.isScanning)
        #expect(await fake.scanCalls == 1)
        await fake.finishRemoval()
        await removal.value
        #expect(await fake.removed.count == 1)
    }
}

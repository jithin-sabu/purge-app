import Combine
import Foundation

/// The injected boundary keeps tests and UI fixtures away from the real library.
nonisolated struct PhotosLibraryClient: Sendable {
    var access: @Sendable () async -> PhotosAccess
    var requestAccess: @Sendable () async -> PhotosAccess
    var scan: @Sendable () async throws -> PhotosLibrarySnapshot
    var remove: @Sendable (PhotosRemovalPlan) async throws -> Void

    static let live = Self(
        access: { PhotoKitLibrary.access() },
        requestAccess: { await PhotoKitLibrary.requestAccess() },
        scan: { try await PhotoKitLibrary.scan() },
        remove: { try await PhotoKitLibrary.remove($0) }
    )
}

@MainActor
final class PhotosLibraryStore: ObservableObject {
    @Published private(set) var access = PhotosAccess.notDetermined
    @Published private(set) var snapshot = PhotosLibrarySnapshot()
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isRemoving = false
    @Published private(set) var hasScanned = false
    @Published private(set) var message: String?
    @Published private(set) var removedCount: Int?
    @Published var pendingRemoval: PhotosRemovalPlan?
    @Published var category = PhotosCategory.videos {
        didSet { if category != oldValue { selectedIDs = []; pendingRemoval = nil } }
    }

    private let client: PhotosLibraryClient
    private var scanTask: Task<Void, Never>?
    private var generation = 0
    private var isOpening = false

    /// No authorization check, fetch or observer registration at app startup.
    init(client: PhotosLibraryClient = .live) { self.client = client }

    var visibleItems: [PhotosLibraryItem] { snapshot.items(in: category) }

    /// Called only by the opened Photos page. Returning to it rechecks permission,
    /// but keeps finished results and the selection unless access changed: the
    /// change block validates every selected item again before any removal.
    func open() async {
        guard !isRemoving, !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        let pass = generation
        let status = await client.access()
        guard !isRemoving, pass == generation else { return }
        let granted = status == .notDetermined ? await client.requestAccess() : status
        guard !isRemoving, pass == generation else { return }
        let changed = granted != access
        access = granted
        guard access.canRead else { clearLibrary(); return }
        if changed || (!hasScanned && !isScanning) { refresh() }
    }

    /// Called when the Photos page goes away. Stops library reads, including a
    /// permission check still in flight, and keeps what already finished.
    func leave() {
        generation += 1
        pendingRemoval = nil
        if isScanning { stop() }
    }

    func refresh() {
        guard access.canRead, !isRemoving else { return }
        stop()
        generation += 1
        let pass = generation
        selectedIDs = []
        pendingRemoval = nil
        snapshot = PhotosLibrarySnapshot()
        hasScanned = false
        message = nil
        removedCount = nil
        isScanning = true
        scanTask = Task {
            do {
                let result = try await client.scan()
                guard !Task.isCancelled, pass == generation else { return }
                snapshot = result
                hasScanned = true
            } catch is CancellationError {
                // Stop leaves no partial library or stale selection to delete.
            } catch {
                guard pass == generation else { return }
                message = error.localizedDescription
            }
            if pass == generation { isScanning = false; scanTask = nil }
        }
    }

    func stop() {
        generation += 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        selectedIDs = []
        pendingRemoval = nil
    }

    func select(_ item: PhotosLibraryItem, selected: Bool) {
        guard !isScanning, !isRemoving, pendingRemoval == nil,
              let current = visibleItems.first(where: { $0.id == item.id }), snapshot.canSelect(current) else { return }
        if selected { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
    }

    func requestRemoval() {
        guard !isScanning, !isRemoving, access.canRead else { return }
        pendingRemoval = PhotosRemovalPlan(snapshot: snapshot, selectedIDs: selectedIDs)
    }

    func confirmRemoval(_ plan: PhotosRemovalPlan) async {
        guard pendingRemoval?.id == plan.id, !isRemoving, !isScanning else { return }
        pendingRemoval = nil
        isRemoving = true
        message = nil
        removedCount = nil
        defer { isRemoving = false }
        do {
            access = await client.access()
            guard access.canRead else { throw PhotosLibraryError.access }
            try await client.remove(plan)
            let removed = Set(plan.assets.map(\.id))
            snapshot.items.removeAll { removed.contains($0.id) }
            removedCount = removed.count
        } catch is CancellationError {
            // Declining Photos' own confirmation removes nothing, so the review
            // and the selection stay. Another removal builds and checks a new plan.
            return
        } catch {
            // A denied or failed request is not a successful removal or freed space.
            message = error.localizedDescription
            snapshot = PhotosLibrarySnapshot()
            hasScanned = false
        }
        selectedIDs = []
    }

    private func clearLibrary() {
        stop()
        snapshot = PhotosLibrarySnapshot()
        hasScanned = false
        message = nil
        removedCount = nil
    }
}

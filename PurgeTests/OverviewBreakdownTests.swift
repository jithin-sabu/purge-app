import Foundation
import Testing
@testable import Purge

@Suite("The Overview counts each byte once")
struct OverviewBreakdownTests {
    private let gb: Int64 = 1_000_000_000

    private func item(_ path: String, _ bytes: Int64) -> OverviewSizedItem {
        OverviewSizedItem(path: path, bytes: bytes)
    }

    @Test func usedAndFreeComeFromTheVolume() {
        let breakdown = OverviewBreakdown(totalBytes: 500 * gb, freeBytes: 180 * gb, sources: [:])
        #expect(breakdown.usedBytes == 320 * gb)
        #expect(breakdown.everythingElseBytes == 320 * gb)
        #expect(breakdown.categoryBytes.isEmpty)
    }

    @Test func everythingElseIsUsedMinusWhatPurgeSorted() {
        let breakdown = OverviewBreakdown(
            totalBytes: 500 * gb,
            freeBytes: 180 * gb,
            sources: [
                .appCaches: .live([item("/Users/a/Library/Caches/com.x", 3 * gb)]),
                .largeFiles: .live([item("/Users/a/Movies/trip.mov", 12 * gb)]),
            ]
        )
        #expect(breakdown.bytes(for: .appCaches) == 3 * gb)
        #expect(breakdown.bytes(for: .largeFiles) == 12 * gb)
        #expect(breakdown.everythingElseBytes == 305 * gb)
    }

    @Test func anAppKeepsOnlyWhatAppCachesDidNotCount() {
        let breakdown = OverviewBreakdown(
            totalBytes: 500 * gb,
            freeBytes: 100 * gb,
            sources: [
                .appCaches: .live([item("/Users/a/Library/Caches/com.x", 2 * gb)]),
                .apps: .live([
                    item("/Applications/X.app", 1 * gb),
                    item("/Users/a/Library/Caches/com.x", 2 * gb),
                ]),
            ]
        )
        #expect(breakdown.bytes(for: .appCaches) == 2 * gb)
        #expect(breakdown.bytes(for: .apps) == 1 * gb)
    }

    @Test func aFolderLosesTheCacheFoundInsideIt() {
        let breakdown = OverviewBreakdown(
            totalBytes: 500 * gb,
            freeBytes: 100 * gb,
            sources: [
                .appCaches: .live([item("/Users/a/Library/Application Support/Chrome/Default/Cache", 3 * gb)]),
                .apps: .live([item("/Users/a/Library/Application Support/Chrome", 5 * gb)]),
            ]
        )
        #expect(breakdown.bytes(for: .apps) == 2 * gb)
    }

    @Test func aFileInsideACountedFolderAddsNothing() {
        let breakdown = OverviewBreakdown(
            totalBytes: 500 * gb,
            freeBytes: 100 * gb,
            sources: [
                .devTools: .live([item("/Users/a/Library/Developer/Xcode/DerivedData", 4 * gb)]),
                .largeFiles: .live([item("/Users/a/Library/Developer/Xcode/DerivedData/big.o", 1 * gb)]),
            ]
        )
        #expect(breakdown.bytes(for: .largeFiles) == 0)
    }

    @Test func nestedClaimsAreNotSubtractedTwice() {
        // Leftovers contains an app folder which itself contains a cache.
        let breakdown = OverviewBreakdown(
            totalBytes: 500 * gb,
            freeBytes: 100 * gb,
            sources: [
                .appCaches: .live([item("/L/Support/App/Cache", 1 * gb)]),
                .apps: .live([item("/L/Support/App", 3 * gb)]),
                .leftovers: .live([item("/L/Support", 10 * gb)]),
            ]
        )
        #expect(breakdown.bytes(for: .appCaches) == 1 * gb)
        #expect(breakdown.bytes(for: .apps) == 2 * gb)
        #expect(breakdown.bytes(for: .leftovers) == 7 * gb)
        #expect(breakdown.sortedBytes == 10 * gb)
    }

    @Test func siblingPathsWithASharedPrefixDoNotOverlap() {
        let breakdown = OverviewBreakdown(
            totalBytes: 500 * gb,
            freeBytes: 100 * gb,
            sources: [
                .appCaches: .live([item("/Users/a/Library/Caches/com.app", 1 * gb)]),
                .leftovers: .live([item("/Users/a/Library/Caches/com.app-helper", 2 * gb)]),
            ]
        )
        #expect(breakdown.bytes(for: .leftovers) == 2 * gb)
    }

    @Test func aRecordedTotalCountsAsIs() {
        let breakdown = OverviewBreakdown(
            totalBytes: 500 * gb,
            freeBytes: 100 * gb,
            sources: [.largeFiles: .recorded(40 * gb), .apps: .none]
        )
        #expect(breakdown.bytes(for: .largeFiles) == 40 * gb)
        #expect(breakdown.categoryBytes[.apps] == nil)
    }

    @Test func everythingElseNeverGoesNegative() {
        // Hard links counted by two scans can add up to more than the used space.
        let breakdown = OverviewBreakdown(
            totalBytes: 100 * gb,
            freeBytes: 90 * gb,
            sources: [.largeFiles: .live([item("/Users/me/Movies/big.mov", 40 * gb)])]
        )
        #expect(breakdown.everythingElseBytes == 0)
    }

    @Test func aRecordedTotalOnlyFillsWhatTheLiveFiguresLeave() {
        // After Stop: App Caches is live, Installed apps is last launch's record,
        // which also counted the cache folder App Caches has now.
        let breakdown = OverviewBreakdown(
            totalBytes: 100 * gb,
            freeBytes: 20 * gb,
            sources: [
                .appCaches: .live([item("/Users/me/Library/Caches/com.app", 30 * gb)]),
                .apps: .recorded(70 * gb)
            ]
        )
        #expect(breakdown.bytes(for: .apps) == 50 * gb)
        #expect(breakdown.sortedBytes == breakdown.usedBytes)
        #expect(breakdown.sortedBytes + breakdown.everythingElseBytes + breakdown.freeBytes == breakdown.totalBytes)
    }

    @Test func aFolderUnderVarAndPrivateVarIsCountedOnce() {
        let breakdown = OverviewBreakdown(
            totalBytes: 500 * gb,
            freeBytes: 100 * gb,
            sources: [
                .appCaches: .live([item("/private/var/folders/ab/C/com.app", 2 * gb)]),
                .apps: .live([item("/var/folders/ab/C/com.app", 2 * gb), item("/Applications/App.app", 1 * gb)])
            ]
        )
        #expect(breakdown.bytes(for: .appCaches) == 2 * gb)
        #expect(breakdown.bytes(for: .apps) == 1 * gb)
    }

    @Test func trailingSlashesDoNotHideAnOverlap() {
        let breakdown = OverviewBreakdown(
            totalBytes: 500 * gb,
            freeBytes: 100 * gb,
            sources: [
                .appCaches: .live([item("/Users/a/Library/Caches/com.x/", 2 * gb)]),
                .apps: .live([item("/Users/a/Library/Caches/com.x", 2 * gb)]),
            ]
        )
        #expect(breakdown.bytes(for: .apps) == 0)
    }

    @Test func shareIsAFractionOfTheWholeDisk() {
        let breakdown = OverviewBreakdown(totalBytes: 400 * gb, freeBytes: 100 * gb, sources: [:])
        #expect(breakdown.share(of: 100 * gb) == 0.25)
        #expect(breakdown.share(of: 800 * gb) == 1)
    }
}

@Suite("The Overview bar and labels")
struct OverviewPresentationTests {

    @Test func smallSegmentsStayVisibleAndTheBarStillFits() {
        let widths = OverviewDiskBar.widths(for: [3, 4, 300, 200], in: 400)
        #expect(widths.allSatisfy { $0 >= 4 })
        let gaps: CGFloat = 2 * 3
        #expect(abs(widths.reduce(0, +) + gaps - 400) < 0.001)
    }

    @Test func widthsFollowTheBytesWhenNothingIsTiny() {
        let widths = OverviewDiskBar.widths(for: [100, 300], in: 402)
        #expect(abs(widths[0] - 100) < 0.001)
        #expect(abs(widths[1] - 300) < 0.001)
    }

    @Test func anEmptyDiskDrawsNothing() {
        #expect(OverviewDiskBar.widths(for: [], in: 400).isEmpty)
        #expect(OverviewDiskBar.widths(for: [0, 0], in: 400) == [0, 0])
    }

    @Test func emptySegmentsKeepTheirPlaceAtZeroWidth() {
        let layout = OverviewDiskBar.layout(for: [100, 0, 300], in: 402)
        #expect(layout.count == 3)
        #expect(layout[0] == .init(x: 0, width: 100))
        // The empty one sits where the next segment starts, so it can grow from there.
        #expect(layout[1].width == 0)
        #expect(abs(layout[2].x - 102) < 0.001)
        #expect(abs(layout[2].x + layout[2].width - 402) < 0.001)
    }

    @Test func hoveringTheBarFindsTheSegmentAndGapsGoToTheNearest() {
        let layout = OverviewDiskBar.layout(for: [100, 0, 300], in: 402)
        #expect(OverviewDiskBar.segmentIndex(at: 50, in: layout) == 0)
        #expect(OverviewDiskBar.segmentIndex(at: 250, in: layout) == 2)
        // In the 2 pt gap, a hair nearer the first segment. The empty one never wins.
        #expect(OverviewDiskBar.segmentIndex(at: 100.5, in: layout) == 0)
        #expect(OverviewDiskBar.segmentIndex(at: 101.5, in: layout) == 2)
    }

    @MainActor
    @Test func aCategoryQueuedForARescanShowsNoFigure() {
        let store = PurgeStore()
        store.scanQueue.enqueue([.cachesAndDevTools])
        #expect(store.overviewPhase(for: .appCaches) == .waiting)
        #expect(!store.isShowingRecordedFigure(for: .appCaches))
        let breakdown = store.overviewBreakdown(totalBytes: 500_000_000_000, freeBytes: 200_000_000_000)
        #expect(breakdown.bytes(for: .appCaches) == 0)
    }

    @MainActor
    @Test func devToolsWaitsWhileAppCachesScans() {
        let store = PurgeStore()
        store.markCacheScanStarting()
        #expect(store.overviewPhase(for: .appCaches) == .scanning)
        #expect(store.overviewPhase(for: .devTools) == .waiting)
    }

    @Test func sharesUnderATenthOfAPercentSaySo() {
        #expect(OverviewCategoryStyle.shareText(0) == "0%")
        #expect(OverviewCategoryStyle.shareText(0.0004) == "<0.1%")
        #expect(OverviewCategoryStyle.shareText(0.078) == "7.8%")
    }

    @MainActor
    @Test func overviewIsTheFirstTab() {
        #expect(PurgeStore.Tab.allCases.first == .overview)
    }
}

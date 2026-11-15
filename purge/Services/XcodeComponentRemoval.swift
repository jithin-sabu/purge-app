import Foundation

/// Outcome of asking `xcodebuild` to delete an optional Xcode component (#132).
nonisolated enum XcodeComponentRemoval: Sendable, Equatable {
    /// `xcodebuild` no longer lists it as installed and its asset folder is gone.
    /// `freed` is what the volume gave back.
    case removed(freed: VolumeCapacityReader.SettledGain)
    /// Not attempted: `xcodebuild` no longer lists it and the ticked asset folder
    /// is gone. Another tool removed it, or a delete that timed out finished
    /// later. Nothing is booked, and a Retry drops the row.
    case alreadyGone
    /// Not attempted: no full Xcode to run `xcodebuild` from, or the component
    /// changed since the scan.
    case refused(String)
    /// `xcodebuild` could not be read, failed, timed out, or still listed the
    /// component afterwards. The row offers Retry.
    case failed(String)
}

nonisolated extension FileDeleter {
    /// `xcodebuild -deleteComponent` asks the asset service to remove the
    /// download, which can finish after the command exits. So success is
    /// `-showComponent` no longer saying installed and the asset folder being
    /// gone, not the exit code.
    static let xcodeComponentDeleteTimeout: TimeInterval = 180
    static let xcodeComponentPollInterval: TimeInterval = 1

    /// The gate for an Xcode component row, read again from disk right before the
    /// delete: a full Xcode is still selected, and `xcodebuild` still names the
    /// same asset folder the scan offered. Then `xcodebuild -deleteComponent`
    /// runs, and the volume is read until it settles. Purge deletes no files here.
    static func removeXcodeComponent(
        _ kind: XcodeComponent.Kind,
        expectedAsset: URL,
        runXcodebuild: XcodeBuildTool.Runner = XcodeBuildTool.run,
        assetsRoot: URL = SimulatorRuntime.mobileAssetRoot,
        readAvailableBytes: @Sendable () -> Int64? = { VolumeCapacityReader.read()?.availableBytes },
        pollInterval: TimeInterval = xcodeComponentPollInterval,
        goneDeadline: TimeInterval = xcodeComponentDeleteTimeout,
        settleInterval: Duration = .seconds(1)
    ) async -> XcodeComponentRemoval {
        // The runner returns nil when no full Xcode is selected any more, or its
        // xcodebuild can't run. Then nothing can be checked, so nothing is asked.
        guard let before = runXcodebuild(["-showComponent", kind.rawValue, "-json"], XcodeBuildTool.showComponentTimeout) else {
            return .refused("no Xcode to run xcodebuild from")
        }
        guard before.succeeded,
              let status = XcodeComponent.parseShowComponent(before.stdout, kind: kind, assetsRoot: assetsRoot)
        else {
            return .failed(describe(before, command: "-showComponent"))
        }
        guard let installed = status.installedAsset else {
            // Gone only when the folder the user ticked is gone too. A folder
            // still on disk that xcodebuild doesn't list stays a refusal.
            if !FileManager.default.fileExists(atPath: expectedAsset.path) { return .alreadyGone }
            return .refused("xcodebuild no longer lists \(kind.rawValue) as installed in AssetsV2")
        }
        guard installed.standardizedFileURL.path == expectedAsset.standardizedFileURL.path else {
            return .refused("xcodebuild names a different \(kind.rawValue) download than the scan found")
        }
        // -deleteComponent takes no asset ID. With a second download there it
        // could remove more than the user ticked.
        guard XcodeComponent.isOnlyDownload(installed, kind: kind, in: assetsRoot) else {
            return .refused("more than one \(kind.rawValue) download in AssetsV2")
        }

        let availableBefore = readAvailableBytes()
        guard let result = runXcodebuild(["-deleteComponent", kind.rawValue], xcodeComponentDeleteTimeout) else {
            return .failed("Could not launch xcodebuild")
        }
        if result.timedOut {
            return .failed("xcodebuild -deleteComponent timed out after \(Int(xcodeComponentDeleteTimeout))s")
        }
        if result.status != 0 {
            return .failed(describe(result, command: "-deleteComponent"))
        }

        let deadline = Date().addingTimeInterval(goneDeadline)
        var gone = false
        while Date() < deadline {
            // A status that can't be read never counts as gone.
            let after = XcodeBuildTool.status(of: kind, run: runXcodebuild, assetsRoot: assetsRoot)
            if let after, after.installedAsset == nil, !FileManager.default.fileExists(atPath: installed.path) {
                gone = true
                break
            }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        guard gone else {
            return .failed("\(kind.rawValue) still installed after \(Int(goneDeadline))s")
        }

        let freed = await VolumeCapacityReader.settle(
            since: availableBefore,
            interval: settleInterval,
            read: readAvailableBytes
        )
        return .removed(freed: freed)
    }

    /// The bytes a removed component is booked at: what the volume gave back. A
    /// gain that settled under the noise floor books nothing. With no settled
    /// reading the scan's size stands, since the asset folder is known to be gone.
    static func xcodeComponentRemovedBytes(listed: Int64, freed: VolumeCapacityReader.SettledGain) -> Int64 {
        switch freed {
        case .gained(let bytes): return bytes
        case .belowNoiseFloor: return 0
        case .unknown: return listed
        }
    }

    private static func describe(_ output: ProcessRunner.Output, command: String) -> String {
        if output.timedOut { return "xcodebuild \(command) timed out" }
        let text = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "xcodebuild \(command) failed (exit \(output.status))" : text
    }
}

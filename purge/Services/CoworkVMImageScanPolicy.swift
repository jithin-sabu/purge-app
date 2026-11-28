import Darwin
import Foundation

/// The disk image of the Linux VM Claude's desktop app runs Cowork in (#468).
///
/// Claude keeps the VM in
/// `~/Library/Application Support/Claude/vm_bundles/claudevm.bundle`:
///
/// - `rootfs.img`, the VM's system disk, 10 GiB and fully allocated;
/// - `rootfs.img.zst`, about 1.3 GB, which Claude calls its compressed cache of
///   the same image;
/// - `vmlinuz`, `initrd`, `initrd-micro` and `efivars.fd`, the boot files;
/// - `sessiondata.img`, `.cowork-adopted` and `machineIdentifier`, user data;
/// - `.<file>.origin` next to each downloaded file, holding the bundle version
///   it came from.
///
/// Read from Claude 1.6.28899.2's `app.asar`: Claude's own `deleteVMBundle`
/// (its Reinstall button, the retry after a VM start fails, and the cleanup when
/// the VM isn't supported) deletes `rootfs.img`, the boot files, their
/// `.origin` files and any `*.partial`, and keeps `sessiondata.img` and the
/// compressed cache. When `rootfs.img` is missing and `.rootfs.img.zst.origin`
/// names the current bundle, the next Cowork start unpacks it from the cache
/// and checks its checksum, with no download. Even Claude's reset of its app
/// data keeps `sessiondata.*` and `.cowork-adopted`.
///
/// So Purge offers only `rootfs.img` and its `.rootfs.img.origin`, as one Check
/// First row in Dev Tools, and only while all of these hold:
///
/// - `rootfs.img.zst` is a regular file that isn't empty, and
///   `.rootfs.img.zst.origin` names the same version as `.rootfs.img.origin`,
///   so the rebuild is local;
/// - Claude is not running;
/// - `rootfs.img` is a regular file with one name, not a link, and no folder on
///   the way to it is a link;
/// - `lsof` shows no process using `rootfs.img`. When `lsof` can't be read,
///   nothing is offered. The main-thread filter (`.quick`) skips `lsof`; the
///   scan and the move run it.
///
/// The origin file goes only after the image: right before its move it is
/// refused while `rootfs.img` is still there. So when the image's move is
/// refused or fails, the two stay together, as Claude wrote them.
///
/// Nothing else in the bundle, and not the bundle itself, is ever offered.
nonisolated enum CoworkVMImageScanPolicy {

    static let label = "Claude Cowork VM Disk"
    static let explanationKey = "claude-cowork-vm-image"
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    static let imageName = "rootfs.img"
    static let imageOriginName = ".rootfs.img.origin"
    static let cacheName = "rootfs.img.zst"
    static let cacheOriginName = ".rootfs.img.zst.origin"
    /// An origin file holds a 40-character version. Anything this big is not one.
    static let originSizeLimit = 1024

    /// The folders from home to the bundle, each of which must be a real folder.
    static let folderChain = ["Library", "Application Support", "Claude", "vm_bundles", "claudevm.bundle"]

    static func bundleFolder(home: String) -> String {
        ([home] + folderChain).joined(separator: "/")
    }

    nonisolated enum Entry: Equatable, Sendable {
        /// `rootfs.img`.
        case image
        /// `.rootfs.img.origin`.
        case imageOrigin
    }

    // MARK: Shape

    /// What `path` is by its place and name alone. Nil for everything else,
    /// including the bundle folder and every other file in it.
    static func entry(at path: String, home: String) -> Entry? {
        guard let name = OldToolVersionScanPolicy.onlyChild(path, of: bundleFolder(home: home)) else { return nil }
        switch name {
        case imageName: return .image
        case imageOriginName: return .imageOrigin
        default: return nil
        }
    }

    /// Shape only, for `evaluate`. Whether the files allow it is checked by
    /// `refusesDeletion` and `passesImmediateTrashBoundary`.
    static func isWhitelistedPath(_ path: String, home: String) -> Bool {
        entry(at: path, home: home) != nil
    }

    // MARK: Context

    nonisolated struct Context: Sendable {
        /// Whether Claude's desktop app is running.
        var isClaudeRunning: @Sendable () -> Bool
        /// The `lsof` listing. Never read by a `.quick` check.
        var openFiles: OpenFileCheck.Lister

        static func current() -> Context {
            Context(
                isClaudeRunning: { DeletionSafetyPolicy.isAppRunning(bundleID: CoworkVMImageScanPolicy.claudeBundleID) },
                openFiles: OpenFileCheck.liveListing
            )
        }
    }

    // MARK: Gate

    /// Whether the file at `path` is offered now, judged as far as `check` goes.
    /// `.quick` reads a few small files and the running apps, so it is safe on
    /// the main thread. `.scan` adds `lsof`. `.move` adds `lsof` too, and keeps
    /// the origin file while the image is still there.
    static func isOffered(
        _ path: String,
        home: String,
        context: Context,
        check: NvmNodeVersionPolicy.Check
    ) -> Bool {
        guard let entry = entry(at: path, home: home),
              hasRealFolderChain(home: home),
              !PathContainment.containsSymlinkComponent(URL(fileURLWithPath: path), home: home) else { return false }
        let bundle = bundleFolder(home: home)
        let image = "\(bundle)/\(imageName)"
        switch entry {
        case .image:
            return isImageOffered(image, bundle: bundle, context: context, check: check)
        case .imageOrigin:
            guard isSingleNameRegularFile(path) else { return false }
            switch check {
            case .quick, .scan:
                return isImageOffered(image, bundle: bundle, context: context, check: check)
            case .move:
                // The image went first. Its origin is all that's left of it.
                return !exists(image) && isLocalRebuildReady(bundle: bundle) && !context.isClaudeRunning()
            }
        }
    }

    private static func isImageOffered(
        _ image: String,
        bundle: String,
        context: Context,
        check: NvmNodeVersionPolicy.Check
    ) -> Bool {
        guard isSingleNameRegularFile(image),
              isLocalRebuildReady(bundle: bundle),
              !context.isClaudeRunning() else { return false }
        switch check {
        case .quick:
            return true
        case .scan, .move:
            return OpenFileCheck.check(folders: [URL(fileURLWithPath: image)], lister: context.openFiles) == .free
        }
    }

    /// The compressed cache is there and is of the same version as the image,
    /// so Claude unpacks the image again without a download.
    static func isLocalRebuildReady(bundle: String) -> Bool {
        let cache = "\(bundle)/\(cacheName)"
        var info = stat()
        guard lstat(cache, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0,
              let imageVersion = originVersion("\(bundle)/\(imageOriginName)"),
              let cacheVersion = originVersion("\(bundle)/\(cacheOriginName)") else { return false }
        return imageVersion == cacheVersion
    }

    /// The version in an origin file, trimmed. Nil when it isn't a small regular
    /// file, can't be read, or is empty.
    static func originVersion(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= originSizeLimit,
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// A regular file, not a link, with no second name a hard link could keep.
    static func isSingleNameRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1
    }

    /// Every folder from `~/Library` to the bundle is a real folder, not a link.
    static func hasRealFolderChain(home: String) -> Bool {
        var path = home
        for name in folderChain {
            path += "/\(name)"
            guard OldToolVersionScanPolicy.isRealFolder(path) else { return false }
        }
        return true
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    // MARK: Hooks

    /// For `isOfferedForCleanup`, which the main-thread filter calls on every
    /// scan flush: the `.quick` check. False for every other path.
    static func refusesDeletion(
        _ url: URL,
        home: String = DeletionSafetyPolicy.cachedHomePath,
        context: Context? = nil
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard entry(at: path, home: home) != nil else { return false }
        return !isOffered(path, home: home, context: context ?? .current(), check: .quick)
    }

    /// `FileDeleter`'s last check before it moves either file: every rule again,
    /// `lsof` included. True for every other path, which other rules judge.
    static func passesImmediateTrashBoundary(
        _ url: URL,
        home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
        context: Context? = nil
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard entry(at: path, home: home) != nil else { return true }
        return isOffered(path, home: home, context: context ?? .current(), check: .move)
    }

    // MARK: Scan

    /// The row a scan offers: the image, then its origin file, in that order so
    /// a clean moves the image first. Empty when the image isn't offered.
    static func definitions(home: String, context: Context) -> [(label: String, paths: [URL])] {
        let bundle = bundleFolder(home: home)
        let image = "\(bundle)/\(imageName)"
        let origin = "\(bundle)/\(imageOriginName)"
        guard isOffered(image, home: home, context: context, check: .scan) else { return [] }
        var paths = [URL(fileURLWithPath: image)]
        // `.quick` for the origin: the image's `lsof` read just above covers it.
        if isOffered(origin, home: home, context: context, check: .quick) {
            paths.append(URL(fileURLWithPath: origin))
        }
        return [(label, paths)]
    }
}

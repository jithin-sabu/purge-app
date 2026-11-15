import AppKit
import QuickLookUI

@MainActor
enum QuickLookPreview {
    private static let dataSource = DataSource()

    static func show(url: URL) {
        dataSource.url = url.standardizedFileURL
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = dataSource
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
}

private final class DataSource: NSObject, QLPreviewPanelDataSource {
    /// The panel maps the file it shows, which moves the access time Large
    /// Files shows as "Last used". The ledger keeps the one from before (#373).
    var url = URL(fileURLWithPath: "/") {
        didSet { FileAccessLedger.shared.watch(url) }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL
    }
}

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

    /// The panel, only when it already exists. `QLPreviewPanel.shared()` would
    /// create one just to ask.
    private static var existingPanel: QLPreviewPanel? {
        QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
    }

    /// True while our preview is on screen.
    static var isVisible: Bool {
        guard let panel = existingPanel else { return false }
        return panel.isVisible && panel.dataSource === dataSource
    }

    static func isPreviewWindow(_ window: NSWindow?) -> Bool {
        guard let window, isVisible else { return false }
        return window === existingPanel
    }

    /// Points the open preview at another file, as the keyboard highlight moves (#96).
    static func update(url: URL) {
        guard isVisible, let panel = existingPanel else { return }
        let url = url.standardizedFileURL
        guard url != dataSource.url else { return }
        dataSource.url = url
        panel.reloadData()
    }

    static func close() {
        guard isVisible else { return }
        existingPanel?.orderOut(nil)
    }
}

private final class DataSource: NSObject, QLPreviewPanelDataSource {
    var url = URL(fileURLWithPath: "/")

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL
    }
}

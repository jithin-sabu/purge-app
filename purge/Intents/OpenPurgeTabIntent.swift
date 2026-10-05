import AppIntents

struct OpenPurgeTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Purge to a Tab"
    static let description = IntentDescription(
        "Opens Purge on Overview, App Caches, Dev Tools, Large Files or the App Uninstaller.",
        searchKeywords: ["open", "show", "overview", "caches", "dev tools", "large files", "big files", "uninstaller", "storage"]
    )
    static let openAppWhenRun = true

    @Parameter(title: "Tab", default: .overview)
    var tab: PurgeTabOption

    static var parameterSummary: some ParameterSummary {
        Summary("Open Purge to \(\.$tab)")
    }

    init() {}

    init(tab: PurgeTabOption) {
        self.tab = tab
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.open(tab: tab.tab)
        return .result()
    }
}

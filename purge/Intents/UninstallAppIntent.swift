import AppIntents

struct UninstallAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Uninstall an App"
    static let description = IntentDescription(
        "Opens Purge's uninstall review for this app, listing the app and everything it leaves behind. Nothing is removed until you confirm in Purge.",
        searchKeywords: [
            "uninstall", "remove", "delete", "get rid of", "trash", "uninstall app",
            "remove app", "delete app", "app", "apps", "leftovers",
        ]
    )
    static let openAppWhenRun = true

    @Parameter(title: "App")
    var app: InstalledAppEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Uninstall \(\.$app) with Purge")
    }

    init() {}

    init(app: InstalledAppEntity) {
        self.app = app
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Not awaited: loading the app list can take a while, and Spotlight
        // would wait on it. The window shows the progress instead.
        let app = app
        Task { await IntentRouter.shared.showUninstaller(appID: app.id, name: app.name) }
        return .result()
    }
}

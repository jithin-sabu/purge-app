import AppIntents

struct UninstallAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Uninstall an App"
    static let description = IntentDescription(
        "Opens Purge's App Uninstaller with this app ticked, so you can review what it leaves behind. Nothing is removed until you confirm in Purge."
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
        IntentRouter.shared.showUninstaller(appID: app.id, name: app.name)
        return .result()
    }
}

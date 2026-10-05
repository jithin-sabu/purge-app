import AppIntents

/// The tabs an intent can open. Settings and About are left out: they are not
/// places anyone asks Siri or Spotlight to take them.
nonisolated enum PurgeTabOption: String, AppEnum {
    case overview
    case appCaches
    case devTools
    case largeFiles
    case uninstaller

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Purge Tab"

    /// No synonyms ("Caches", "Big Files"): they need macOS 14, and this list has
    /// to be a fixed value, so it cannot switch on the macOS version. The phrases
    /// and search keywords on each action cover other wordings instead.
    static let caseDisplayRepresentations: [PurgeTabOption: DisplayRepresentation] = [
        .overview: DisplayRepresentation(title: "Overview", image: .init(systemName: "square.grid.2x2")),
        .appCaches: DisplayRepresentation(title: "App Caches", image: .init(systemName: "internaldrive")),
        .devTools: DisplayRepresentation(title: "Dev Tools", image: .init(systemName: "hammer")),
        .largeFiles: DisplayRepresentation(title: "Large Files", image: .init(systemName: "tray.full")),
        .uninstaller: DisplayRepresentation(title: "App Uninstaller", image: .init(systemName: "trash")),
    ]

    var tab: PurgeStore.Tab {
        switch self {
        case .overview: return .overview
        case .appCaches: return .appCaches
        case .devTools: return .devTools
        case .largeFiles: return .largeFiles
        case .uninstaller: return .uninstaller
        }
    }
}

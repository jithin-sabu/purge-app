//
//  purgeApp.swift
//  purge
//
//  Created by Jithin Sabu on 05/05/26.
//

import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class PurgeAppDelegate: NSObject, NSApplicationDelegate {
    let updater = PurgeUpdater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the saved appearance before the first paint to avoid a launch flash.
        AppAppearance.apply(AppearanceMode.current)
        // Not in the window's `onAppear`: menu-bar-only mode can launch windowless,
        // and the status item still needs live models behind it.
        AppBootstrapper.bootstrapOnce()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CleaningQuitGuard.shouldAllowTermination() ? .terminateNow : .terminateCancel
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

private struct PurgeAppDelegateKey: EnvironmentKey {
    static let defaultValue: PurgeAppDelegate? = nil
}

extension EnvironmentValues {
    var purgeAppDelegate: PurgeAppDelegate? {
        get { self[PurgeAppDelegateKey.self] }
        set { self[PurgeAppDelegateKey.self] = newValue }
    }
}

@main
struct PurgeApp: App {
    @NSApplicationDelegateAdaptor(PurgeAppDelegate.self) private var appDelegate
    // Adopted from `AppEnvironment`, not created here: these outlive the window.
    @StateObject private var store = AppEnvironment.shared.store
    @StateObject private var diskStore = AppEnvironment.shared.diskStore
    @StateObject private var trashStore = AppEnvironment.shared.trashStore
    @StateObject private var menuModel = AppEnvironment.shared.menuModel
    @AppStorage(AppearanceMode.userDefaultsKey)
    private var appearanceModeRaw = AppearanceMode.system.rawValue
    @State private var systemThemeObserver: NSObjectProtocol?
    @State private var activeColorScheme: ColorScheme = {
        let mode = AppearanceMode.current
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .system: return .light
        }
    }()

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    /// SwiftUI semantic colors need `preferredColorScheme`; AppKit-backed menu
    /// pickers need `NSApp`/`NSWindow` appearance. Apply both together.
    private func applyAppAppearance() {
        AppAppearance.apply(appearanceMode)
        activeColorScheme = appearanceMode.resolvedColorScheme
    }

    init() {
        // Must precede anything that touches user defaults — the gate reads the persisted domain to
        // tell a clean install apart from an update.
        FirstRunGate.resolve()
        LargeFileFilterDefaults.register()
        UNUserNotificationCenter.current().delegate = ScheduledNotificationPresentationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(store)
                .environmentObject(diskStore)
                .environmentObject(trashStore)
                .environmentObject(appDelegate.updater)
                .environment(\.purgeAppDelegate, appDelegate)
                .onAppear {
                    // Model/service wiring lives in `AppBootstrapper` — it has to run
                    // windowless. Only the window-scoped appearance work is left here.
                    applyAppAppearance()
                    systemThemeObserver = AppAppearance.addSystemThemeObserver {
                        guard appearanceMode == .system else { return }
                        applyAppAppearance()
                    }
                }
                .font(.system(.body, design: .rounded))
                .preferredColorScheme(activeColorScheme)
                .onChange(of: appearanceModeRaw) { _ in
                    applyAppAppearance()
                }
                .onDisappear {
                    if let systemThemeObserver {
                        DistributedNotificationCenter.default().removeObserver(systemThemeObserver)
                    }
                }
        }
        .defaultSize(width: AppWindowLayout.width, height: AppWindowLayout.defaultHeight)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            PurgeCommands(store: store)
        }

        MenuBarExtra {
            MenuBarContentView(model: menuModel, store: store)
                .environmentObject(store)
                .environmentObject(diskStore)
                .environmentObject(trashStore)
        } label: {
            MenuBarStatusIcon()
        }
        .menuBarExtraStyle(.window)
    }
}

struct PurgeCommands: Commands {
    let store: PurgeStore

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {}
                .keyboardShortcut(",", modifiers: .command)
                .disabled(true)
        }
        CommandGroup(after: .newItem) {
            Button("Scan All") {
                Task { await store.scanAll() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!store.hasFullDiskAccess || store.isDeleting)
        }
        CommandGroup(replacing: .undoRedo) {}
    }
}

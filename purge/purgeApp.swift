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
    /// Kept alive here: `NSApp.servicesProvider` is an unretained reference.
    private let uninstallService = FinderUninstallService()

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchContext.captureLaunchKind()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The open-application event reaches one of the two launch callbacks; which
        // one varies, so ask again.
        LaunchContext.captureLaunchKind()
        // Apply the saved appearance before the first paint to avoid a launch flash.
        AppAppearance.apply(AppearanceMode.current)
        // Not in the window's `onAppear`: menu-bar-only mode can launch windowless,
        // and the status item still needs live models behind it.
        AppBootstrapper.bootstrapOnce()
        // Finder's "Uninstall with Purge": a request that launched Purge is
        // delivered once this returns, so the provider must be set here.
        NSApp.servicesProvider = uninstallService
        ServicesMenuRegistration.refreshIfNeeded()

        if LaunchContext.shouldSuppressInitialWindow(
            // Read the key directly rather than touching `.shared`: building the
            // store calls `SMAppService.mainApp.status`, an out-of-process read we
            // have no use for at launch.
            showsMenuBarIcon: StartupPreferenceStore.persistedShowsMenuBarIcon(),
            launchedAsLoginItem: LaunchContext.launchedAsLoginItem,
            hasCompletedOnboarding: FirstRunGate.hasCompletedOnboarding
        ) || RemovedAppMonitor.startsWindowless {
            // Started by the deleted-apps watcher: the window appears only if
            // there is something to review (`RemovedAppMonitor`).
            InitialWindowSuppressor.suppressInitialWindow()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CleaningQuitGuard.shouldAllowTermination() ? .terminateNow : .terminateCancel
    }

    /// Always `false`, in both modes. In the menu bar mode closing the window is
    /// not quitting. In on-demand mode it is, but `WindowCloseQuitter` handles
    /// that, because this callback cannot tell the user closing the window from
    /// Purge closing it on a windowless launch.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Covers the Dock icon, and opening Purge from Finder or Spotlight while it
    /// is already running — the only "click the app" route left once the Dock
    /// icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        RemovedAppMonitor.shared.userOpenedWindow()
        guard !hasVisibleWindows else { return true }
        // No window object to raise: let SwiftUI make one rather than guessing.
        guard !AppWindowPresenter.needsNewWindow(windows: sender.windows) else { return true }
        AppWindowPresenter.reveal()
        return false
    }

    /// `purge://` links from the deleted-apps watcher, and app bundles dropped
    /// on the Dock icon (`CFBundleDocumentTypes` in Info.plist).
    func application(_ application: NSApplication, open urls: [URL]) {
        let dropped = urls.filter(\.isFileURL)
        if !dropped.isEmpty {
            ExternalUninstallHandler.handle(urls: dropped)
        }
        for url in urls where !url.isFileURL {
            RemovedAppMonitor.shared.handleOpenURL(url)
        }
    }
}

@main
struct PurgeApp: App {
    @NSApplicationDelegateAdaptor(PurgeAppDelegate.self) private var appDelegate
    // Adopted from `AppEnvironment`, not created here: these outlive the window.
    @StateObject private var store = AppEnvironment.store
    @StateObject private var diskStore = AppEnvironment.diskStore
    @StateObject private var trashStore = AppEnvironment.trashStore
    @StateObject private var menuModel = AppEnvironment.menuModel
    @AppStorage(AppearanceMode.userDefaultsKey)
    private var appearanceModeRaw = AppearanceMode.system.rawValue
    /// Always written by `resolvePersistedModes` in `init()`, so the default is
    /// never used.
    @AppStorage(StartupPreferenceStore.showMenuBarIconKey)
    private var showsMenuBarIcon = false
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

    /// Reads through `@AppStorage` so the scene updates when Settings changes the
    /// mode. Writes go to the store, which is also where a ⌘-drag out of the menu
    /// bar lands: SwiftUI sets this binding to `false` when the user removes the
    /// icon, and that has to switch modes the same way the Settings switch does.
    /// If the login item will not come off, the store keeps the menu bar mode and
    /// the getter still reads `true`, so the icon stays.
    private var menuBarIconBinding: Binding<Bool> {
        Binding(
            get: { showsMenuBarIcon },
            set: { StartupPreferenceStore.shared.setShowsMenuBarIcon($0) }
        )
    }

    init() {
        // Must precede anything that touches user defaults — the gate reads the persisted domain to
        // tell a clean install apart from an update.
        let firstRun = FirstRunGate.resolve()
        // Before the Dock policy below reads the preference it may repair.
        StartupPreferenceStore.resolvePersistedModes(isFreshInstall: firstRun == .freshInstall)
        LargeFileFilterDefaults.register()
        UNUserNotificationCenter.current().delegate = ScheduledNotificationPresentationDelegate.shared
        // As early as the app can act, so a login launch with the Dock icon hidden
        // never flashes into the Dock before hiding itself again.
        DockIconPolicy.apply(hidesDockIcon: StartupPreferenceStore.persistedHidesDockIcon())
    }

    var body: some Scene {
        WindowGroup(id: AppWindowID.main) {
            AppRootView()
                .environmentObject(store)
                .environmentObject(diskStore)
                .environmentObject(trashStore)
                .environmentObject(appDelegate.updater)
                .onAppear {
                    // Model/service wiring lives in `AppBootstrapper` — it has to run
                    // windowless. Only the window-scoped appearance work is left here.
                    applyAppAppearance()
                    systemThemeObserver = AppAppearance.addSystemThemeObserver {
                        guard appearanceMode == .system else { return }
                        applyAppAppearance()
                    }
                }
                .font(AppStyle.Typography.body)
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
            PurgeCommands(store: store, updater: appDelegate.updater)
        }

        MenuBarExtra(isInserted: menuBarIconBinding) {
            MenuBarContentView(model: menuModel, store: store, updater: appDelegate.updater)
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
    let updater: PurgeUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesMenuItem(updater: updater)
        }
        CommandGroup(replacing: .appSettings) {
            SettingsMenuItem(store: store)
        }
        CommandGroup(after: .newItem) {
            Button("Scan Everything") {
                store.scanEverything()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(store.isDeleting)
        }
        CommandGroup(replacing: .undoRedo) {}
        CommandGroup(after: .pasteboard) {
            FindMenuItem()
        }
        CommandGroup(before: .sidebar) {
            TabMenuItems(store: store)
            Divider()
        }
        // Our own Quit item instead of SwiftUI's. AppKit finds the stock one by
        // its identifier the first time the menu opens and slips a hidden ⌥⌘Q
        // "Quit and Keep Windows" alternate in after it. SwiftUI doesn't know
        // about that item, so if anything updates the menus while it is open (a
        // launch scan does, many times a second) SwiftUI resets the menu, the
        // alternate goes, and the open menu is left with a blank row at the bottom.
        CommandGroup(replacing: .appTermination) {
            Button("Quit Purge") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

/// Settings is a tab inside the main window, so this brings the window back
/// first. The window may be closed, or never built after a windowless menu bar
/// launch. Onboarding covers the tabs, so the item waits until it is done.
///
/// A view for the same reason as `CheckForUpdatesMenuItem`: the item has to
/// re-enable when onboarding finishes while the app is running.
private struct SettingsMenuItem: View {
    let store: PurgeStore
    @AppStorage(FirstRunGate.onboardingCompletedKey) private var hasCompletedOnboarding = false

    var body: some View {
        Button("Settings…") {
            IntentRouter.revealWindow()
            store.selectedTab = .settings
        }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(!hasCompletedOnboarding)
    }
}

/// View > Overview … App Uninstaller on ⌘1 … ⌘5. Brings the window back first
/// and waits for onboarding, the same as Settings…
private struct TabMenuItems: View {
    let store: PurgeStore
    @AppStorage(FirstRunGate.onboardingCompletedKey) private var hasCompletedOnboarding = false

    var body: some View {
        ForEach(Array(PurgeStore.Tab.keyboardTabs.enumerated()), id: \.element) { index, tab in
            Button(tab.rawValue) {
                IntentRouter.revealWindow()
                store.selectedTab = tab
            }
            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            .disabled(!hasCompletedOnboarding)
        }
    }
}

/// Puts the cursor in the search field on Large Files and App Uninstaller. The
/// field on screen publishes `findAction`; see `FindAction` for when there is none.
/// A view so `@FocusedValue` re-evaluates it as tabs come and go.
private struct FindMenuItem: View {
    @FocusedValue(\.findAction) private var findAction

    var body: some View {
        Button("Find") { findAction?() }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(findAction == nil)
    }
}

/// A view rather than a plain button so it observes `canCheckForUpdates`;
/// `Commands` bodies don't re-render on a published change by themselves.
private struct CheckForUpdatesMenuItem: View {
    @ObservedObject var updater: PurgeUpdater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}

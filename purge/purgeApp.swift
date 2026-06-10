//
//  purgeApp.swift
//  purge
//
//  Created by Jithin Sabu on 05/05/26.
//

import AppKit
import SwiftUI
import UserNotifications

@main
struct PurgeApp: App {
    @StateObject private var store = PurgeStore()
    @StateObject private var diskStore = DiskSummaryStore()
    @AppStorage(AppearanceMode.userDefaultsKey)
    private var appearanceModeRaw = AppearanceMode.system.rawValue

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    init() {
        UNUserNotificationCenter.current().delegate = ScheduledNotificationPresentationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(store)
                .environmentObject(diskStore)
                .onAppear {
                    diskStore.refresh()
                    ScheduledCleaningRegistrar.shared.attach(store: store)
                }
                .font(.system(.body, design: .rounded))
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .defaultSize(width: AppWindowLayout.width, height: AppWindowLayout.defaultHeight)
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            PurgeCommands(store: store)
        }

        MenuBarExtra(formatBytes(store.safeRecoverableBytes), systemImage: "externaldrive.badge.minus") {
            Button("Open Purge") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("Safe to clean: \(formatBytes(store.safeRecoverableBytes))")
                    .font(.headline)
                Text("\(formatBytes(store.totalRecoveredBytes)) recovered so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            Divider()
            Button("Clean Safe Files Now") {
                Task { await store.performManualSafeCleanNow() }
            }
            Divider()
            Button("Quit Purge") {
                NSApplication.shared.terminate(nil)
            }
        }
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
            .disabled(!store.hasFullDiskAccess)
        }
        CommandGroup(replacing: .undoRedo) {}
    }
}

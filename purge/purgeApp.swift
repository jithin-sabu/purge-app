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

    init() {
        UNUserNotificationCenter.current().delegate = ScheduledNotificationPresentationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onAppear {
                    ScheduledCleaningRegistrar.shared.attach(store: store)
                }
                .font(.system(.body, design: .rounded))
        }
        .defaultSize(width: 980, height: 700)
        .commands {
            PurgeCommands(store: store)
        }

        MenuBarExtra(formatBytes(store.recoverableTotalBytes), systemImage: "externaldrive.badge.minus") {
            Button("Open Purge") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Divider()
            Text("Recoverable: \(formatBytes(store.recoverableTotalBytes))")
            Text("Recovered so far: \(formatBytes(store.totalRecoveredBytes))")
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

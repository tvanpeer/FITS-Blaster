//
//  Simple_Claude_fits_viewerApp.swift
//  Simple Claude fits viewer
//
//  Created by Tom van Peer on 28/02/2026.
//

import SwiftUI

@main
struct Simple_Claude_fits_viewerApp: App {
    @State private var settings = AppSettings()
    @State private var store = ImageStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 900, height: 700)
        .environment(settings)
        .environment(store)
        .commands {
            CommandGroup(after: .newItem) {
                SettingsMenuCommand()
            }
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(settings)
                .environment(store)
        }
        .windowResizability(.contentSize)
    }
}

/// Adds a "Settings… ⌘," menu item to the File menu.
private struct SettingsMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

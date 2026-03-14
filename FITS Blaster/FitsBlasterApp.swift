//
//  FitsBlasterApp.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 28/02/2026.
//

import SwiftUI

// MARK: - App Delegate

/// Handles files and folders dropped onto the dock icon, forwarding them to the
/// active ImageStore via a handler set up once ContentView appears.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by ContentView.onAppear. URLs received before the handler is ready are
    /// buffered and delivered as soon as the handler is installed.
    var openURLsHandler: (([URL]) -> Void)? {
        didSet {
            guard let handler = openURLsHandler, !pendingURLs.isEmpty else { return }
            handler(pendingURLs)
            pendingURLs = []
        }
    }

    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let handler = openURLsHandler {
            handler(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }
}

// MARK: - App

@main
struct FitsBlasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings()
    @State private var store = ImageStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    appDelegate.openURLsHandler = { [store, settings] urls in
                        store.openDroppedItems(urls, settings: settings)
                    }
                }
        }
        .defaultSize(width: 900, height: 700)
        .environment(settings)
        .environment(store)
        .environment(\.dynamicTypeSize, settings.dynamicTypeSize)
        .commands {
            CommandGroup(after: .newItem) {
                SettingsMenuCommand()
            }
            CommandGroup(after: .sidebar) {
                Divider()
                SimpleModeCommand()
                DebayerColourCommand()
            }
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(settings)
                .environment(store)
                .environment(\.dynamicTypeSize, settings.dynamicTypeSize)
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

/// Toggles colour debayering from the View menu.
/// ContentView's onChange(of: settings.debayerColorImages) triggers the reprocess.
private struct DebayerColourCommand: View {
    @FocusedValue(\.debayerColorBinding) var debayerColor
    @FocusedValue(\.debayerKeyString) var keyString

    var body: some View {
        let equiv: KeyEquivalent = keyString.flatMap(\.first).map { KeyEquivalent($0) } ?? KeyEquivalent("c")
        Button(debayerColor?.wrappedValue == true ? "✓ Colour Images" : "Colour Images") {
            debayerColor?.wrappedValue.toggle()
        }
        .disabled(debayerColor == nil)
        .keyboardShortcut(equiv, modifiers: [])
    }
}

/// Toggles Simple/Geek mode from the View menu using the focused window's binding.
private struct SimpleModeCommand: View {
    @FocusedValue(\.simpleModeBinding) var isSimpleMode
    @FocusedValue(\.toggleModeKeyString) var keyString

    var body: some View {
        let equiv: KeyEquivalent = keyString.flatMap(\.first).map { KeyEquivalent($0) } ?? KeyEquivalent("g")
        Button(isSimpleMode?.wrappedValue == true ? "✓ Simple Mode" : "Simple Mode") {
            isSimpleMode?.wrappedValue.toggle()
        }
        .disabled(isSimpleMode == nil)
        .keyboardShortcut(equiv, modifiers: [])
    }
}

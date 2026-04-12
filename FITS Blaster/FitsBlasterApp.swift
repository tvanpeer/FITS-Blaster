//
//  FitsBlasterApp.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 28/02/2026.
//

import Sparkle
import SwiftUI

// MARK: - App Delegate

/// Handles files and folders dropped onto the dock icon, forwarding them to the
/// active ImageStore via a handler set up once ContentView appears.
@MainActor
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
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    init() {
        // NSInitialToolTipDelay is an undocumented AppKit UserDefaults key (milliseconds).
        // Default is ~1500 ms; 500 ms feels more responsive without being distracting.
        UserDefaults.standard.set(500, forKey: "NSInitialToolTipDelay")
    }

    var body: some Scene {
        WindowGroup(id: "main") {
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
            CommandGroup(replacing: .newItem) {
                MainWindowCommand()
                Divider()
                OpenFolderCommand()
                Divider()
                SettingsMenuCommand()
            }
            CommandGroup(after: .windowArrangement) {
                Divider()
                CloseWindowCommand()
            }
            CommandGroup(after: .sidebar) {
                Divider()
                SimpleModeCommand()
                DebayerColourCommand()
            }
            CommandMenu("Select") {
                SelectAllCommand()
                DeselectAllCommand()
                InvertSelectionCommand()
                SelectAllRejectedCommand()
                Divider()
                ToggleFlagCommand()
                DeflagAllCommand()
            }
            CommandGroup(replacing: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
                Divider()
                Button("About FITS Blaster") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "If FITS Blaster saves you time, consider supporting development on Ko-fi.",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                .foregroundColor: NSColor.secondaryLabelColor,
                                .link: URL(string: "https://ko-fi.com/tomvp") as Any
                            ]
                        )
                    ])
                }
            }
            CommandGroup(replacing: .help) {
                Button("FITS Blaster Help") {
                    if let url = URL(string: "https://astrophoto-app.com/faq.html") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Ask Support") {
                    if let url = URL(string: "https://github.com/tvanpeer/FITS-Blaster/issues/new?template=bug_report.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(settings)
                .environment(store)
                .environment(\.dynamicTypeSize, settings.dynamicTypeSize)
        }
    }
}

//
//  FITSToolbar.swift
//  FITS Blaster
//

import SwiftUI

struct FITSToolbar: View {
    let store: ImageStore
    @Environment(AppSettings.self) private var settings
    @State private var showExportSheet = false
    @State private var showAutoRejectSheet = false
    /// The running Open Folder flow (panel, question, scan); one at a time.
    @State private var openFolderTask: Task<Void, Never>?

    var body: some View {
        HStack {
            Button("Open Folder…") {
                startOpenFolder()
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Open a folder of FITS files (⌘O)")
            .onChange(of: store.openFolderRequested) { _, requested in
                // ⌘O from the menu (ContentFocusedValues) asks the toolbar to open.
                guard requested else { return }
                store.openFolderRequested = false
                startOpenFolder()
            }

            Button("Reset") {
                store.reset()
            }
            .disabled(store.entries.isEmpty)
            .help("Remove all loaded images from the list")

            Button {
                settings.debayerColorImages.toggle()
            } label: {
                Label {
                    Text(settings.debayerColorImages ? "Colour" : "Grey")
                } icon: {
                    if settings.debayerColorImages {
                        Image(systemName: "camera.filters")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.red, Color.green, Color.blue)
                    } else {
                        Image(systemName: "camera.filters")
                            .symbolRenderingMode(.monochrome)
                    }
                }
            }
            .help(settings.debayerColorImages ? "Switch to greyscale" : "Switch to colour")

            PlaybackControls()

            Button("Cancel") {
                store.cancelProcessing()
            }
            .disabled(!store.isBatchProcessing)
            .help("Cancel the current batch processing")

            Button("(De)flag", systemImage: "flag") {
                store.toggleFlagSelected()
            }
            .disabled(store.selectedEntry == nil && store.markedForRejectionIDs.isEmpty)
            .help("Flag or unflag the current selection")

            if !store.flaggedEntryIDs.isEmpty {
                Divider().frame(height: 20)
                Text("\(store.flaggedEntryIDs.count) flagged")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !settings.isSimpleMode {
                Button("Auto-Flag", systemImage: "wand.and.stars") {
                    showAutoRejectSheet = true
                }
                .help("Auto-flag frames below quality thresholds")
                .disabled(store.entries.isEmpty)
            }

            Button("Export…", systemImage: "square.and.arrow.up") {
                showExportSheet = true
            }
            .disabled(store.entries.isEmpty)
            .help("Export a list of flagged or rejected frames")

            Button(settings.isSimpleMode ? "Simple" : "Geek",
                   systemImage: settings.isSimpleMode ? "dial.low" : "dial.high") {
                settings.isSimpleMode.toggle()
            }
            .help(settings.isSimpleMode
                  ? "Switch to Geek Mode (\(AppSettings.displayString(for: settings.toggleModeKey)))"
                  : "Switch to Simple Mode (\(AppSettings.displayString(for: settings.toggleModeKey)))")

            if !settings.isSimpleMode {
                Button(settings.showInspector ? "Hide Inspector" : "Show Inspector",
                       systemImage: "sidebar.right") {
                    settings.showInspector.toggle()
                }
                .labelStyle(.iconOnly)
                .help(settings.showInspector ? "Hide Inspector" : "Show Inspector")
            }
        }
        .padding()
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(isPresented: $showExportSheet)
                .environment(store)
                .environment(settings)
        }
        .sheet(isPresented: $showAutoRejectSheet) {
            AutoRejectSheet(isPresented: $showAutoRejectSheet)
                .environment(store)
        }
    }

    private func startOpenFolder() {
        guard openFolderTask == nil else { return }
        openFolderTask = Task {
            await FileDialogs.openFolder(store: store, settings: settings)
            openFolderTask = nil
        }
    }
}

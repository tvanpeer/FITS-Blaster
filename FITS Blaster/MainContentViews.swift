//
//  MainContentViews.swift
//  FITS Blaster
//
//  Main image display area: resizable chart layout, toolbar, image viewer,
//  info bar, and metric chip.
//

import SwiftUI

// MARK: - Resizable Chart Layout

/// A VStack containing the main image and session chart, separated by a draggable
/// handle that persists the chart height across launches via AppStorage.
struct ResizableChartLayout: View {
    @Environment(ImageStore.self) private var store
    @AppStorage("sessionChartHeight") private var chartHeight: Double = 200

    /// Captured at the start of each drag so we can compute relative offset.
    @State private var heightAtDragStart: Double = 200

    var body: some View {
        VStack(spacing: 0) {
            MainContent(store: store)
                .frame(minHeight: 180)

            // Drag handle
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 32, height: 3)
                )
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            // Dragging up = negative translation = chart taller
                            chartHeight = max(80, min(600,
                                heightAtDragStart - value.translation.height))
                        }
                        .onEnded { _ in
                            heightAtDragStart = chartHeight
                        }
                )

            SessionChartView()
                .frame(height: chartHeight)
        }
        .onAppear { heightAtDragStart = chartHeight }
    }
}

// MARK: - Toolbar

struct FITSToolbar: View {
    let store: ImageStore
    @Environment(AppSettings.self) private var settings
    @State private var showExportSheet = false
    @State private var showAutoRejectSheet = false

    var body: some View {
        HStack {
            Button("Open Folder…") {
                store.openFolderPanel(settings: settings)
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Open a folder of FITS files (⌘O)")

            // TODO: Open Files… is hidden until sandbox write-access for parent directories is resolved.
            // Button("Open Files…") { store.openFilesPanel(settings: settings) }
            //     .keyboardShortcut("o", modifiers: [.command, .shift])

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

            // Mode toggle: show the CURRENT mode (like "Colour"/"Grey").
            Button(settings.isSimpleMode ? "Simple" : "Geek",
                   systemImage: settings.isSimpleMode ? "dial.low" : "dial.high") {
                settings.isSimpleMode.toggle()
            }
            .help(settings.isSimpleMode ? "Switch to Geek Mode (\(AppSettings.displayString(for: settings.toggleModeKey)))" : "Switch to Simple Mode (\(AppSettings.displayString(for: settings.toggleModeKey)))")

            if !settings.isSimpleMode {
                Button("", systemImage: "sidebar.right") {
                    settings.showInspector.toggle()
                }
                .help(settings.showInspector ? "Hide Inspector" : "Show Inspector")
            }
        }
        .padding()
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(isPresented: $showExportSheet)
                .environment(store)
        }
        .sheet(isPresented: $showAutoRejectSheet) {
            AutoRejectSheet(isPresented: $showAutoRejectSheet)
                .environment(store)
        }
    }
}

// MARK: - Main Content

struct MainContent: View {
    let store: ImageStore

    var body: some View {
        if let entry = store.selectedEntry {
            if entry.isProcessing {
                ProgressView("Stretching \(entry.fileName)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let displayImage = entry.displayImage {
                VStack(spacing: 0) {
                    Text(entry.fileName)
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: displayImage)
                    }
                    .id(entry.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollIndicators(.hidden)

                    Divider()
                    InfoBar(store: store, entry: entry)
                }
            } else if let error = entry.errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(error)
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack {
                Image(systemName: "star.circle")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.tertiary)
                Text("Ready to Blast through your frames?")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Open a folder with \u{2318}O or drag it onto the window")
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Info Bar

private struct InfoBar: View {
    let store: ImageStore
    let entry: ImageEntry
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack {
            if store.isBatchProcessing {
                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                Text("Processing…").scaledFont(size: 10).foregroundStyle(.secondary)
                Button("Cancel", action: store.cancelProcessing)
                    .scaledFont(size: 10)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else if let msg = store.recolouringMessage {
                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                Text(msg).scaledFont(size: 10).foregroundStyle(.secondary)
            } else if let elapsed = store.batchElapsed {
                Text("\(elapsed, format: .number.precision(.fractionLength(2)))s for \(store.entries.count) images")
                    .scaledFont(size: 10, monospaced: true)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Inline metrics summary (Geek mode only)
            if !settings.isSimpleMode, let m = entry.metrics, m.hasData {
                HStack(spacing: 12) {
                    if let v = m.fwhm        { MetricChip(label: "FWHM", value: "\(v.formatted(.number.precision(.fractionLength(1)))) px") }
                    if let v = m.eccentricity { MetricChip(label: "Ecc",  value: v.formatted(.number.precision(.fractionLength(2)))) }
                    if let v = m.snr          { MetricChip(label: "SNR",  value: v.formatted(.number.precision(.fractionLength(0)))) }
                    if let v = m.starCount     { MetricChip(label: "★",   value: "\(v)") }
                }
            }

            if !entry.imageInfo.isEmpty {
                Text(entry.imageInfo)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

private struct MetricChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
        .scaledFont(size: 10, monospaced: true)
    }
}

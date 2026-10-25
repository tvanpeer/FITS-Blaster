//
//  ExportPanel.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 01/03/2026.
//

import SwiftUI

/// Sheet that lets the user choose export format, rejected-frame inclusion,
/// and FITS header columns before opening an NSSavePanel.
///
/// All controls are pre-populated from `AppSettings`. Per-export edits are kept
/// in local `@State` and never written back to settings. An orange notice appears
/// if the user changes any value from its stored default.
struct ExportSheet: View {
    @Binding var isPresented: Bool
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var format: ExportFormat = .plainText
    @State private var includeRejected: Bool = false
    @State private var pathStyle: PathStyle = .absolute
    /// In export column order: the order from Settings, newly ticked keys at the end.
    @State private var selectedHeaderKeys: [String] = []
    @State private var availableKeys: [String] = []
    @State private var presentKeys: Set<String> = []
    @State private var showHeaderPicker: Bool = false

    private var frameCount: Int {
        includeRejected ? store.entries.count
                        : store.entries.count { !$0.isRejected }
    }

    private var divergesFromDefaults: Bool {
        format != settings.defaultExportFormat
            || includeRejected != settings.includeRejectedInExport
            || pathStyle != settings.exportPathStyle
            || selectedHeaderKeys != settings.exportHeaderKeys
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases, id: \.self) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    Picker("File paths", selection: $pathStyle) {
                        ForEach(PathStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    Toggle("Include rejected frames", isOn: $includeRejected)
                }

                Section {
                    DisclosureGroup(isExpanded: $showHeaderPicker) {
                        Text("Dimmed keys are not present in any currently loaded file. They are still selectable, but empty columns are dropped at export time (the .txt report notes which were skipped).")
                            .scaledFont(size: 10)
                            .foregroundStyle(.secondary)
                        HeaderKeyPicker(
                            selection: $selectedHeaderKeys,
                            availableKeys: availableKeys,
                            presentKeys: presentKeys,
                            minHeight: 140, maxHeight: 220
                        )
                    } label: {
                        HStack {
                            Text("FITS header columns")
                            Spacer()
                            Text("\(selectedHeaderKeys.count) selected")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if divergesFromDefaults {
                Text("Applies to this export only. To change the default, go to Settings → Export.")
                    .scaledFont(size: 10)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Text("\(frameCount) frame\(frameCount == 1 ? "" : "s") will be exported")
                .scaledFont(size: 10)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Save…") {
                    isPresented = false
                    // The sheet's choices, captured before it goes away.
                    let (format, includeRejected, headerKeys, pathStyle) =
                        (format, includeRejected, selectedHeaderKeys, pathStyle)
                    Task {
                        guard let url = await FileDialogs.chooseExportDestination(format: format) else { return }
                        store.export(to: url, format: format, includeRejected: includeRejected,
                                     headerKeys: headerKeys, pathStyle: pathStyle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(frameCount == 0)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 460)
        .onAppear {
            format             = settings.defaultExportFormat
            includeRejected    = settings.includeRejectedInExport
            pathStyle          = settings.exportPathStyle
            selectedHeaderKeys = settings.exportHeaderKeys
            refreshAvailableKeys()
        }
    }

    private func refreshAvailableKeys() {
        (availableKeys, presentKeys) = ExportHeaderKeys.available(in: store.entries,
                                                                  selected: selectedHeaderKeys)
    }
}

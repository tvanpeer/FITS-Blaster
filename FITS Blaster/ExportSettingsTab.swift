//
//  ExportSettingsTab.swift
//  FITS Blaster
//
//  Settings → Export. Lets the user pick the default export format,
//  whether rejected frames are included by default, and which FITS
//  header keys appear as extra columns in CSV/TSV exports.
//

import SwiftUI

struct ExportSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ImageStore.self) private var store

    /// Union of the curated known-key list and the keys actually present in
    /// currently-loaded FITS files. Computing once on appear keeps the view
    /// cheap even with thousands of frames.
    @State private var availableKeys: [String] = []

    /// Keys that are actually present (non-empty) in at least one loaded file.
    /// Used to dim curated keys that aren't yet relevant to the current session.
    @State private var presentKeys: Set<String> = []

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Defaults") {
                Picker("Default format", selection: $settings.defaultExportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                Picker("File paths", selection: $settings.exportPathStyle) {
                    ForEach(PathStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Text("Relative paths strip the longest folder shared by all exported frames, so a single-folder session collapses to bare filenames automatically.")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                Toggle("Include rejected frames by default", isOn: $settings.includeRejectedInExport)
                Text("In plain text exports, rejected lines are suffixed with \" # REJECTED\". In CSV and TSV, a status column is added.")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }

            Section("FITS Header Columns") {
                Text("Header keys discovered in the currently-loaded FITS files are merged with a curated list of common keys. Dimmed keys are not present in any loaded file (still selectable; empty columns are dropped at export time).")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                HeaderKeyPicker(
                    selection: $settings.exportHeaderKeys,
                    availableKeys: availableKeys,
                    presentKeys: presentKeys
                )
                HStack {
                    Spacer()
                    Button("Reset to defaults") {
                        settings.exportHeaderKeys = ExportHeaderKeys.defaults
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshAvailableKeys() }
        .onChange(of: store.entries.count) { _, _ in refreshAvailableKeys() }
    }

    private func refreshAvailableKeys() {
        (availableKeys, presentKeys) = ExportHeaderKeys.available(in: store.entries,
                                                                  selected: settings.exportHeaderKeys)
    }
}

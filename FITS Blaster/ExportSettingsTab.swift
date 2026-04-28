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

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Defaults") {
                Picker("Default format", selection: $settings.defaultExportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                Toggle("Include rejected frames by default", isOn: $settings.includeRejectedInExport)
                Text("In plain text exports, rejected lines are suffixed with \" # REJECTED\". In CSV and TSV, a status column is added.")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }

            Section("FITS Header Columns (CSV / TSV)") {
                ExportHeaderKeyPicker(
                    selection: Binding(
                        get: { settings.exportHeaderKeys },
                        set: { settings.exportHeaderKeys = $0 }
                    ),
                    availableKeys: availableKeys
                )
                HStack {
                    Spacer()
                    Button("Reset to defaults") {
                        settings.exportHeaderKeys = [
                            "OBJECT", "DATE-OBS", "EXPTIME", "FILTER",
                            "GAIN", "OFFSET", "CCD-TEMP",
                            "FOCUSPOS", "AIRMASS", "OBJCTALT",
                            "AMBTEMP", "HUMIDITY"
                        ]
                    }
                }
                Text("Header keys discovered in the currently-loaded FITS files are merged with a curated list of common keys. Selected keys appear as columns in the CSV/TSV export.")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshAvailableKeys() }
        .onChange(of: store.entries.count) { _, _ in refreshAvailableKeys() }
    }

    private func refreshAvailableKeys() {
        var keys = Set(AppSettings.knownExportHeaderKeys)
        for entry in store.entries {
            keys.formUnion(entry.headers.keys)
        }
        // Always show selected keys even if neither list contains them anymore
        // (e.g. user typed a custom key in a previous version of the app).
        keys.formUnion(settings.exportHeaderKeys)
        availableKeys = keys.sorted()
    }
}

// MARK: - Header key picker

/// A scrollable, two-column grid of toggles. Selected keys are persisted in
/// `AppSettings.exportHeaderKeys` in the order the user clicks them, but we
/// display the available list alphabetically for findability.
private struct ExportHeaderKeyPicker: View {
    @Binding var selection: [String]
    let availableKeys: [String]

    private let columns = [
        GridItem(.flexible(), alignment: .leading),
        GridItem(.flexible(), alignment: .leading)
    ]

    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(availableKeys, id: \.self) { key in
                    Toggle(isOn: binding(for: key)) {
                        Text(key)
                            .scaledFont(size: 11, monospaced: true)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 160, maxHeight: 240)
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(key) },
            set: { isOn in
                if isOn {
                    if !selection.contains(key) { selection.append(key) }
                } else {
                    selection.removeAll { $0 == key }
                }
            }
        )
    }
}

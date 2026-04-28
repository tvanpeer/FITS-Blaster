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
/// in local `@State` and never written back to settings — same pattern as the
/// open-folder panel. An orange notice appears if the user changes any value
/// from its stored default, mirroring `openFolderPanel(settings:)`.
struct ExportSheet: View {
    @Binding var isPresented: Bool
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var format: ExportFormat = .plainText
    @State private var includeRejected: Bool = false
    @State private var selectedHeaderKeys: [String] = []
    @State private var availableKeys: [String] = []
    @State private var showHeaderPicker: Bool = false

    private var frameCount: Int {
        includeRejected ? store.entries.count
                        : store.entries.count { !$0.isRejected }
    }

    private var divergesFromDefaults: Bool {
        format != settings.defaultExportFormat
            || includeRejected != settings.includeRejectedInExport
            || selectedHeaderKeys != settings.exportHeaderKeys
    }

    private var supportsHeaders: Bool {
        format == .csv || format == .tsv
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
                    Toggle("Include rejected frames", isOn: $includeRejected)
                }

                if supportsHeaders {
                    Section {
                        DisclosureGroup(isExpanded: $showHeaderPicker) {
                            ExportSheetHeaderList(
                                selection: $selectedHeaderKeys,
                                availableKeys: availableKeys
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
                    store.export(format: format,
                                 includeRejected: includeRejected,
                                 headerKeys: selectedHeaderKeys)
                }
                .buttonStyle(.borderedProminent)
                .disabled(frameCount == 0)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: supportsHeaders ? 460 : 280)
        .onAppear {
            format             = settings.defaultExportFormat
            includeRejected    = settings.includeRejectedInExport
            selectedHeaderKeys = settings.exportHeaderKeys
            refreshAvailableKeys()
        }
    }

    private func refreshAvailableKeys() {
        var keys = Set(AppSettings.knownExportHeaderKeys)
        for entry in store.entries {
            keys.formUnion(entry.headers.keys)
        }
        keys.formUnion(selectedHeaderKeys)
        availableKeys = keys.sorted()
    }
}

// MARK: - Header list inside the sheet

/// Two-column scrollable checkbox list for picking FITS header keys.
/// Mirrors the structure used in Settings → Export so the visual language is
/// consistent across both surfaces.
private struct ExportSheetHeaderList: View {
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
        .frame(minHeight: 140, maxHeight: 220)
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

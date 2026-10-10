//
//  OpenFolderOptionsView.swift
//  FITS Blaster
//
//  Sheet that lets the user set scanning options before the folder picker opens.
//

import SwiftUI

struct OpenFolderOptionsView: View {
    @Environment(\.dismiss) private var dismiss

    let excludedNames: [String]
    let onConfirm: (Bool, Bool) -> Void  // (includeSubfolders, includeRejected)

    @State private var includeSubfolders: Bool
    @State private var includeRejected: Bool

    init(defaultSubfolders: Bool,
         defaultIncludeRejected: Bool,
         excludedNames: [String],
         onConfirm: @escaping (Bool, Bool) -> Void) {
        _includeSubfolders = State(initialValue: defaultSubfolders)
        _includeRejected   = State(initialValue: defaultIncludeRejected)
        self.excludedNames = excludedNames
        self.onConfirm     = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open FITS Folder")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Include files from subfolders", isOn: $includeSubfolders)
                Toggle("Include REJECTED folder (mark images as rejected)", isOn: $includeRejected)
            }

            if !excludedNames.isEmpty {
                Text("Skipping: \(excludedNames.joined(separator: ", ")). Edit in Settings → Files & Folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Folder…") {
                    onConfirm(includeSubfolders, includeRejected)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 380, maxWidth: 500)
    }
}

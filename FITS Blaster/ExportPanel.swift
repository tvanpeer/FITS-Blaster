//
//  ExportPanel.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 01/03/2026.
//

import SwiftUI

/// Sheet that lets the user choose export format before opening an NSSavePanel.
struct ExportSheet: View {
    @Binding var isPresented: Bool
    @Environment(ImageStore.self) private var store

    @State private var format = ExportFormat.plainText

    private var keptCount: Int {
        store.entries.filter { !$0.isRejected }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases, id: \.self) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
            }
            .formStyle(.grouped)

            Text("\(keptCount) frame\(keptCount == 1 ? "" : "s") will be exported")
                .scaledFont(size: 10)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Save…") {
                    isPresented = false
                    store.export(format: format)
                }
                .buttonStyle(.borderedProminent)
                .disabled(keptCount == 0)
            }
            .padding()
        }
        .frame(width: 380, height: 180)
    }
}

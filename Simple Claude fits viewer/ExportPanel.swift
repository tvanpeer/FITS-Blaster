//
//  ExportPanel.swift
//  Simple Claude fits viewer
//
//  Created by Tom van Peer on 01/03/2026.
//

import SwiftUI

/// Sheet that lets the user choose export format and minimum star rating
/// before opening an NSSavePanel.
struct ExportSheet: View {
    @Binding var isPresented: Bool
    @Environment(ImageStore.self) private var store

    @State private var format = ExportFormat.plainText
    @State private var minimumRating = 0

    private var keptCount: Int {
        store.entries.filter { !$0.isRejected && $0.rating >= minimumRating }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases, id: \.self) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }

                Picker("Minimum rating", selection: $minimumRating) {
                    Text("All kept frames").tag(0)
                    ForEach(1...5, id: \.self) { n in
                        Text(String(repeating: "★", count: n) + " or above").tag(n)
                    }
                }
            }
            .formStyle(.grouped)

            Text("\(keptCount) frame\(keptCount == 1 ? "" : "s") will be exported")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Save…") {
                    isPresented = false
                    store.export(format: format, minimumRating: minimumRating)
                }
                .buttonStyle(.borderedProminent)
                .disabled(keptCount == 0)
            }
            .padding()
        }
        .frame(width: 380, height: 220)
    }
}

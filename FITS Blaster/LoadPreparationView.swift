//
//  LoadPreparationView.swift
//  FITS Blaster
//
//  Spinner while a folder is scanned, progress bar while the files are checked.
//  Shown in the empty window on a first load, and in the info bar otherwise.
//

import SwiftUI

struct LoadPreparationView: View {
    let preparation: LoadPreparation

    var body: some View {
        switch preparation {
        case .scanning(let folder):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Scanning \(folder)…")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
        case .checking(let done, let total):
            HStack(spacing: 6) {
                Text("Checking files")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(minWidth: 120)
                Text("\(done) / \(total)")
                    .scaledFont(size: 10, monospaced: true)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}

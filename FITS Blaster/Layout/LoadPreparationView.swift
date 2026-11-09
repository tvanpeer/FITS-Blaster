//
//  LoadPreparationView.swift
//  FITS Blaster
//
//  Spinner while a folder is scanned.
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
        }
    }
}

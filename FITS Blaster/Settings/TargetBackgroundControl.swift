//
//  TargetBackgroundControl.swift
//  FITS Blaster
//

import SwiftUI

struct TargetBackgroundControl: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var bound = settings
        Button("Target BG", systemImage: "circle.lefthalf.filled") {
            settings.targetBackground = 0.25
        }
        .tooltip("Target Background — click to reset to 0.25")
        Slider(value: $bound.targetBackground, in: 0.05...0.50)
            .frame(width: 80)
        Text(settings.targetBackground, format: .number.precision(.fractionLength(2)))
            .scaledFont(size: 10, monospaced: true)
            .frame(width: 34, alignment: .leading)
            .foregroundStyle(.secondary)
    }
}

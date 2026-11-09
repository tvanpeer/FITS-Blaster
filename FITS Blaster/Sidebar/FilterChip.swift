//
//  FilterChip.swift
//  FITS Blaster
//

import SwiftUI

struct FilterChip: View {
    let label: String
    let colour: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .scaledFont(size: 9, weight: .bold)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(isSelected ? colour : colour.opacity(0.15))
                .foregroundStyle(isSelected ? .white : colour)
                .clipShape(.rect(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) filter")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

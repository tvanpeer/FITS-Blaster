//
//  HeaderKeyPicker.swift
//  FITS Blaster
//
//  Two-column checkbox grid for choosing FITS header export columns, used by
//  Settings → Export and the Export sheet.
//

import SwiftUI

/// The available keys are listed alphabetically for findability; the selection keeps
/// the order in which keys were ticked, which is the column order of the export.
struct HeaderKeyPicker: View {
    @Binding var selection: [String]
    let availableKeys: [String]
    let presentKeys: Set<String>
    var minHeight: CGFloat = 160
    var maxHeight: CGFloat = 240

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
                            .foregroundStyle(presentKeys.contains(key) ? .primary : .secondary)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: minHeight, maxHeight: maxHeight)
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

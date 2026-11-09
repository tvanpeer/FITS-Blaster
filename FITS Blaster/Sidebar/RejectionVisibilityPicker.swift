//
//  RejectionVisibilityPicker.swift
//  FITS Blaster
//
//  The "Show" picker at the bottom of the sidebar (All / Flagged / Rejected). It takes the
//  first form that fits the sidebar: segments with the full words, segments with short
//  words (All / Flag / Rej), or a pop-up menu — so it is never cut off in a narrow sidebar
//  or with a large text size.
//

import SwiftUI

struct RejectionVisibilityPicker: View {
    @Binding var selection: RejectionVisibility

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Picker("Show", selection: $selection) {
                ForEach(RejectionVisibility.allCases, id: \.self) { v in
                    Text(v.rawValue).tag(v)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()

            // Short words; VoiceOver still reads the full names.
            Picker("Show", selection: $selection) {
                ForEach(RejectionVisibility.allCases, id: \.self) { v in
                    Text(Self.shortName(for: v))
                        .accessibilityLabel(v.rawValue)
                        .tag(v)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .help("Show all frames, the flagged frames or the rejected frames")

            Picker("Show", selection: $selection) {
                ForEach(RejectionVisibility.allCases, id: \.self) { v in
                    Text(v.rawValue).tag(v)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private static func shortName(for visibility: RejectionVisibility) -> String {
        switch visibility {
        case .all:      "All"
        case .active:   "Flag"
        case .rejected: "Rej"
        }
    }
}

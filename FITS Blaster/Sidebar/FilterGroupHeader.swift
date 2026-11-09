//
//  FilterGroupHeader.swift
//  FITS Blaster
//

import SwiftUI

struct FilterGroupHeader: View {
    let group: FilterGroup
    let entryCount: Int
    let stats: GroupStats?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(group.color)
                .frame(width: 8, height: 8)
            Text(group.rawValue)
                .scaledFont(size: 10, weight: .bold)
            Text("\(entryCount)")
                .scaledFont(size: 10)
                .foregroundStyle(.secondary)
            Spacer()
            if let fwhm = stats?.medianFWHM {
                Text("\(fwhm, format: .number.precision(.fractionLength(1)))px")
                    .scaledFont(size: 9, monospaced: true)
                    .foregroundStyle(.secondary)
            }
            if let score = stats?.medianScore {
                Text("▸\(score, format: .number.precision(.fractionLength(0)))")
                    .scaledFont(size: 9, monospaced: true)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.regularMaterial)
        // One item for VoiceOver: "Filter L, 12 frames, median FWHM 3.2 pixels, median score 72" (10d).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FrameAccessibility.filterHeaderLabel(group: group, frameCount: entryCount,
                                                                 medianFWHM: stats?.medianFWHM,
                                                                 medianScore: stats?.medianScore))
        .accessibilityAddTraits(.isHeader)
    }
}

/// Inline filter sub-header used inside a folder section when a single folder
/// contains images from more than one filter group.
struct FolderFilterSubHeader: View {
    let group: FilterGroup
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(group.color)
                .frame(width: 6, height: 6)
            Text(group.rawValue)
                .scaledFont(size: 9, weight: .bold)
            Text("\(count)")
                .scaledFont(size: 9)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .background(.quinary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FrameAccessibility.filterHeaderLabel(group: group, frameCount: count))
        .accessibilityAddTraits(.isHeader)
    }
}

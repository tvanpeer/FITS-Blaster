//
//  FilterLegendMark.swift
//  FITS Blaster
//

import SwiftUI

/// A filter group's mark in the session chart's legend: its coloured dot, or while the
/// chart shows shapes ("Differentiate without color" on, dots mode) its chart shape in the
/// high-contrast colour (step 10d).
struct FilterLegendMark: View {
    let group: FilterGroup
    let showsShape: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if showsShape {
            group.chartSymbol.shape
                .fill(group.chartColor(differentiateWithoutColor: true, colorScheme: colorScheme))
                .frame(width: 9, height: 9)
        } else {
            Circle()
                .fill(group.color)
                .frame(width: 7, height: 7)
        }
    }
}

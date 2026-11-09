//
//  FilterGroup+ChartColour.swift
//  FITS Blaster
//
//  The session chart's dot and legend colours (step 10d). Normally the group's own colour.
//  With macOS "Differentiate without color" on, colours with too little contrast against
//  the chart's background are made lighter (dark mode) or darker (light mode), keeping their
//  hue, to at least 6:1 against the window background (#1E1E1E dark, white light; macOS 27),
//  so every shape stays visible, also with colour blindness (Tom, 2026-11-07).
//

import SwiftUI

extension FilterGroup {

    /// The colour of this group's dots and legend mark.
    func chartColour(differentiateWithoutColor: Bool, colorScheme: ColorScheme) -> Color {
        guard differentiateWithoutColor else { return colour }
        return colorScheme == .dark ? darkHighContrastColour : lightHighContrastColour
    }

    /// At least 6:1 against #1E1E1E. G, OIII, SII, SO and Quad-NB already were.
    var darkHighContrastColour: Color {
        switch self {
        case .luminance:  Color(white: 0.61)
        case .red:        Color(red: 0.904, green: 0.490, blue: 0.490)
        case .blue:       Color(red: 0.453, green: 0.598, blue: 0.964)
        case .ha:         Color(red: 0.953, green: 0.459, blue: 0.459)
        case .hbeta:      Color(red: 0.569, green: 0.569, blue: 0.965)
        case .ho:         Color(red: 0.896, green: 0.430, blue: 0.875)
        case .sho:        Color(red: 0.751, green: 0.501, blue: 0.955)
        case .unfiltered: Color(white: 0.61)
        case .green, .oiii, .sii, .so, .quadNB: colour
        }
    }

    /// At least 6:1 against white. SHO already was.
    var lightHighContrastColour: Color {
        switch self {
        case .luminance:  Color(white: 0.388)
        case .red:        Color(red: 0.749, green: 0.141, blue: 0.141)
        case .green:      Color(red: 0.093, green: 0.449, blue: 0.156)
        case .blue:       Color(red: 0.074, green: 0.321, blue: 0.938)
        case .ha:         Color(red: 0.776, green: 0.068, blue: 0.068)
        case .oiii:       Color(red: 0.000, green: 0.434, blue: 0.434)
        case .sii:        Color(red: 0.560, green: 0.335, blue: 0.030)
        case .hbeta:      Color(red: 0.284, green: 0.284, blue: 0.942)
        case .ho:         Color(red: 0.671, green: 0.123, blue: 0.647)
        case .so:         Color(red: 0.078, green: 0.442, blue: 0.286)
        case .quadNB:     Color(red: 0.463, green: 0.381, blue: 0.041)
        case .unfiltered: Color(white: 0.388)
        case .sho:        colour
        }
    }
}

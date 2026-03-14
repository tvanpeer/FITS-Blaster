//
//  FilterGroup.swift
//  FITS Blaster
//

import SwiftUI

/// Canonical filter group derived from the raw FITS FILTER header value.
///
/// Covers broadband, narrowband mono, and dual/tri/quad narrowband OSC filters.
/// Declared in `CaseIterable` order, which defines the canonical display order
/// used in the sidebar filter strip and session chart legend.
enum FilterGroup: String, CaseIterable, Identifiable, Hashable {
    // Broadband
    case luminance  = "L"
    case red        = "R"
    case green      = "G"
    case blue       = "B"
    // Narrowband mono
    case ha         = "Ha"
    case oiii       = "OIII"
    case sii        = "SII"
    case hbeta      = "Hβ"
    // Dual-narrowband OSC: Hα + OIII (L-eXtreme, L-Ultimate, Antlia ALP-T, etc.)
    case ho         = "HO"
    // Tri-narrowband OSC: SII + Hα + OIII (L-eNhance, Triad Ultra, etc.)
    case sho        = "SHO"
    // Quad-narrowband OSC (Antlia Quad, Astronomik Quad, etc.)
    case quadNB     = "Quad-NB"
    // Unrecognised or missing FILTER header
    case unfiltered = "Unfiltered"

    var id: String { rawValue }

    // MARK: - Classification

    /// True for narrowband mono and OSC multi-narrowband groups.
    var isNarrowband: Bool {
        switch self {
        case .ha, .oiii, .sii, .hbeta, .ho, .sho, .quadNB: return true
        default: return false
        }
    }

    // MARK: - Display

    /// Colour used for chart dots, sidebar group headers, and filter strip chips.
    /// Values are chosen to be distinguishable in both light and dark mode.
    var color: Color {
        switch self {
        case .luminance:  return Color(white: 0.60)
        case .red:        return Color(red: 0.85, green: 0.20, blue: 0.20)
        case .green:      return Color(red: 0.15, green: 0.72, blue: 0.25)
        case .blue:       return Color(red: 0.25, green: 0.45, blue: 0.95)
        case .ha:         return Color(red: 0.92, green: 0.08, blue: 0.08)
        case .oiii:       return Color(red: 0.00, green: 0.75, blue: 0.75)
        case .sii:        return Color(red: 0.95, green: 0.58, blue: 0.08)
        case .hbeta:      return Color(red: 0.38, green: 0.38, blue: 0.95)
        case .ho:         return Color(red: 0.85, green: 0.18, blue: 0.82)   // magenta
        case .sho:        return Color(red: 0.52, green: 0.08, blue: 0.88)   // purple
        case .quadNB:     return Color(red: 0.90, green: 0.74, blue: 0.08)   // gold
        case .unfiltered: return Color(white: 0.50)
        }
    }

    // MARK: - Normalisation

    /// Map a raw FITS FILTER header value to a canonical FilterGroup.
    ///
    /// Matching is case-insensitive and substring-based so that verbose
    /// manufacturer names like `"Optolong L-eXtreme 7nm"` resolve correctly.
    /// Groups are checked from most-specific (quad) to least-specific (broadband)
    /// to prevent partial-match false positives.
    static func normalise(_ raw: String?) -> FilterGroup {
        guard let raw, !raw.isEmpty else { return .unfiltered }
        let s = raw.lowercased()

        // ── Quad-band (checked first — most specific multi-band)
        if s.contains("quad") || s.contains("4-band") || s.contains("4band") {
            return .quadNB
        }

        // ── Tri-narrowband OSC (SHO / L-eNhance / Triad)
        if s.contains("sho") || s.contains("enhance") || s.contains("triad")
            || s.contains("tri-band") || s.contains("triband") {
            return .sho
        }

        // ── Dual-narrowband OSC (HO / L-eXtreme / L-Ultimate / Antlia ALP-T)
        // "ho" and "hoo" must be whole-word or prefix matches to avoid catching "shot", etc.
        if s == "ho" || s == "hoo" || s.hasPrefix("ho ") || s.hasPrefix("hoo ")
            || s.contains("extreme") || s.contains("ultimate") || s.contains("alp-t")
            || s.contains("dual narrowband") || s.contains("dual-narrowband")
            || s.contains("dual nb") {
            return .ho
        }

        // ── Narrowband mono — evaluated after dual/tri to avoid subset matches
        if s == "ha" || s.contains("halpha") || s.contains("h-alpha")
            || s.contains("h_alpha") || s.contains("656nm") {
            return .ha
        }
        if s.contains("oiii") || s.contains("o-iii") || s == "o3"
            || s.contains("500nm") {
            return .oiii
        }
        if s.contains("sii") || s.contains("s-ii") || s == "s2"
            || s.contains("672nm") {
            return .sii
        }
        if s.contains("hbeta") || s.contains("h-beta") || s == "hb"
            || s.contains("486nm") {
            return .hbeta
        }

        // ── Broadband
        if s == "l" || s.contains("lum") || s.contains("clear")
            || s.contains("ir cut") || s.contains("baader l") {
            return .luminance
        }
        if s == "r" || s == "red" { return .red }
        if s == "g" || s == "green" { return .green }
        if s == "b" || s == "blue" { return .blue }

        return .unfiltered
    }
}

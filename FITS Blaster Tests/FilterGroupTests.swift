//
//  FilterGroupTests.swift
//  FITS Blaster Tests
//
//  Tests for FilterGroup.normalise: maps raw FITS FILTER header values
//  to canonical filter groups.
//

import Testing
@testable import FITS_Blaster

struct FilterGroupTests {

    // MARK: - normalise — parameterised over all filter groups

    @Test("Normalises raw header values to correct group", arguments: [
        // Nil / empty / unknown
        (nil          as String?, FilterGroup.unfiltered),
        (""           as String?, FilterGroup.unfiltered),
        ("FooBar"     as String?, FilterGroup.unfiltered),
        // Broadband
        ("L",                     FilterGroup.luminance),
        ("Lum",                   FilterGroup.luminance),
        ("Luminance",             FilterGroup.luminance),
        ("Clear",                 FilterGroup.luminance),
        ("IR Cut",                FilterGroup.luminance),
        ("Baader L",              FilterGroup.luminance),
        ("R",                     FilterGroup.red),
        ("Red",                   FilterGroup.red),
        ("G",                     FilterGroup.green),
        ("Green",                 FilterGroup.green),
        ("B",                     FilterGroup.blue),
        ("Blue",                  FilterGroup.blue),
        // Narrowband mono
        ("Ha",                    FilterGroup.ha),
        ("Halpha",                FilterGroup.ha),
        ("H-Alpha",               FilterGroup.ha),
        ("H_Alpha",               FilterGroup.ha),
        ("656nm",                 FilterGroup.ha),
        ("OIII",                  FilterGroup.oiii),
        ("O-III",                 FilterGroup.oiii),
        ("O3",                    FilterGroup.oiii),
        ("500nm",                 FilterGroup.oiii),
        ("SII",                   FilterGroup.sii),
        ("S-II",                  FilterGroup.sii),
        ("S2",                    FilterGroup.sii),
        ("672nm",                 FilterGroup.sii),
        ("Hbeta",                 FilterGroup.hbeta),
        ("H-Beta",                FilterGroup.hbeta),
        ("Hb",                    FilterGroup.hbeta),
        ("486nm",                 FilterGroup.hbeta),
        // Dual-narrowband OSC
        ("HO",                    FilterGroup.ho),
        ("HOO",                   FilterGroup.ho),
        ("Optolong L-eXtreme",    FilterGroup.ho),
        ("L-Ultimate",            FilterGroup.ho),
        ("Antlia ALP-T",          FilterGroup.ho),
        ("Dual Narrowband",       FilterGroup.ho),
        ("Dual-Narrowband",       FilterGroup.ho),
        ("Dual NB",               FilterGroup.ho),
        ("SO",                    FilterGroup.so),
        ("S+O",                   FilterGroup.so),
        ("SII+OIII",              FilterGroup.so),
        ("SII + OIII",            FilterGroup.so),
        ("C2",                    FilterGroup.so),
        ("Askar C2",              FilterGroup.so),
        // Tri-narrowband
        ("SHO",                   FilterGroup.sho),
        ("L-eNhance",             FilterGroup.sho),
        ("Triad Ultra",           FilterGroup.sho),
        ("Tri-Band",              FilterGroup.sho),
        ("Triband",               FilterGroup.sho),
        // Quad-narrowband
        ("Quad",                  FilterGroup.quadNB),
        ("4-Band",                FilterGroup.quadNB),
        ("4band",                 FilterGroup.quadNB),
    ])
    func normalise(input: String?, expected: FilterGroup) {
        #expect(FilterGroup.normalise(input) == expected)
    }

    // MARK: - Case insensitivity

    @Test("Normalisation is case-insensitive", arguments: [
        ("ha",        FilterGroup.ha),
        ("HA",        FilterGroup.ha),
        ("oiii",      FilterGroup.oiii),
        ("OIII",      FilterGroup.oiii),
        ("luminance", FilterGroup.luminance),
        ("LUMINANCE", FilterGroup.luminance),
    ])
    func caseInsensitive(input: String, expected: FilterGroup) {
        #expect(FilterGroup.normalise(input) == expected)
    }

    // MARK: - isNarrowband classification

    @Test("Narrowband groups are classified correctly", arguments: [
        FilterGroup.ha, .oiii, .sii, .hbeta, .ho, .so, .sho, .quadNB,
    ])
    func narrowbandClassification(group: FilterGroup) {
        #expect(group.isNarrowband == true, "\(group.rawValue) should be narrowband")
    }

    @Test("Broadband groups are classified correctly", arguments: [
        FilterGroup.luminance, .red, .green, .blue, .unfiltered,
    ])
    func broadbandClassification(group: FilterGroup) {
        #expect(group.isNarrowband == false, "\(group.rawValue) should not be narrowband")
    }
}

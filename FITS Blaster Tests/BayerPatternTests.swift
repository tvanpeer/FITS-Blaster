//
//  BayerPatternTests.swift
//  FITS Blaster Tests
//
//  Tests for BayerPattern: rOffset encoding and parse(from:) header lookup.
//

import Testing
@testable import FITS_Blaster

struct BayerPatternTests {

    // MARK: - rOffset encoding

    @Test("rOffset encoding matches Metal kernel convention", arguments: [
        (BayerPattern.rggb, 0 as UInt32),
        (BayerPattern.grbg, 1 as UInt32),
        (BayerPattern.gbrg, 2 as UInt32),
        (BayerPattern.bggr, 3 as UInt32),
    ])
    func rOffset(pattern: BayerPattern, expected: UInt32) {
        #expect(pattern.rOffset == expected)
    }

    // MARK: - parse(from:) — all four patterns via BAYERPAT

    @Test("Parses BAYERPAT header", arguments: [
        ("RGGB", BayerPattern.rggb),
        ("BGGR", BayerPattern.bggr),
        ("GRBG", BayerPattern.grbg),
        ("GBRG", BayerPattern.gbrg),
    ])
    func parseFromBAYERPAT(value: String, expected: BayerPattern) {
        #expect(BayerPattern.parse(from: ["BAYERPAT": value]) == expected)
    }

    // MARK: - parse(from:) — alternative keys

    @Test("Parses from COLORTYP key")
    func parseFromCOLORTYP() {
        #expect(BayerPattern.parse(from: ["COLORTYP": "RGGB"]) == .rggb)
    }

    @Test("Parses from CFA_PAT key")
    func parseFromCFA_PAT() {
        #expect(BayerPattern.parse(from: ["CFA_PAT": "BGGR"]) == .bggr)
    }

    // MARK: - Key priority

    @Test("BAYERPAT takes priority over COLORTYP")
    func bayerpatPriority() {
        #expect(BayerPattern.parse(from: ["BAYERPAT": "RGGB", "COLORTYP": "BGGR"]) == .rggb)
    }

    @Test("COLORTYP takes priority over CFA_PAT")
    func colortypPriority() {
        #expect(BayerPattern.parse(from: ["COLORTYP": "GRBG", "CFA_PAT": "BGGR"]) == .grbg)
    }

    // MARK: - FITS string quoting

    @Test("Strips FITS quotes and whitespace", arguments: [
        ("'RGGB            '", BayerPattern.rggb),
        ("'  BGGR  '",        BayerPattern.bggr),
    ])
    func parseStripsQuotes(value: String, expected: BayerPattern) {
        #expect(BayerPattern.parse(from: ["BAYERPAT": value]) == expected)
    }

    // MARK: - Case insensitivity

    @Test("Case insensitive parsing", arguments: [
        ("rggb", BayerPattern.rggb),
        ("Bggr", BayerPattern.bggr),
    ])
    func parseCaseInsensitive(value: String, expected: BayerPattern) {
        #expect(BayerPattern.parse(from: ["BAYERPAT": value]) == expected)
    }

    // MARK: - Nil cases

    @Test("Returns nil for empty headers")
    func parseReturnsNilForEmptyHeaders() {
        #expect(BayerPattern.parse(from: [:]) == nil)
    }

    @Test("Returns nil for unrecognised value")
    func parseReturnsNilForUnrecognised() {
        #expect(BayerPattern.parse(from: ["BAYERPAT": "MONO"]) == nil)
    }

    @Test("Returns nil when no relevant key present")
    func parseReturnsNilForIrrelevantKeys() {
        #expect(BayerPattern.parse(from: ["OBJECT": "M31", "FILTER": "Ha"]) == nil)
    }
}

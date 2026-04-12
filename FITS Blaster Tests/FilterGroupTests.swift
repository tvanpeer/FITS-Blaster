//
//  FilterGroupTests.swift
//  FITS Blaster Tests
//
//  Tests for FilterGroup.normalise: maps raw FITS FILTER header values
//  to canonical filter groups.
//

import XCTest
@testable import FITS_Blaster

final class FilterGroupTests: XCTestCase {

    // MARK: - Nil and empty

    func testNilReturnsUnfiltered() {
        XCTAssertEqual(FilterGroup.normalise(nil), .unfiltered)
    }

    func testEmptyStringReturnsUnfiltered() {
        XCTAssertEqual(FilterGroup.normalise(""), .unfiltered)
    }

    func testUnrecognisedReturnsUnfiltered() {
        XCTAssertEqual(FilterGroup.normalise("FooBar"), .unfiltered)
    }

    // MARK: - Broadband

    func testLuminance() {
        XCTAssertEqual(FilterGroup.normalise("L"), .luminance)
        XCTAssertEqual(FilterGroup.normalise("Lum"), .luminance)
        XCTAssertEqual(FilterGroup.normalise("Luminance"), .luminance)
        XCTAssertEqual(FilterGroup.normalise("Clear"), .luminance)
        XCTAssertEqual(FilterGroup.normalise("IR Cut"), .luminance)
        XCTAssertEqual(FilterGroup.normalise("Baader L"), .luminance)
    }

    func testRed() {
        XCTAssertEqual(FilterGroup.normalise("R"), .red)
        XCTAssertEqual(FilterGroup.normalise("Red"), .red)
    }

    func testGreen() {
        XCTAssertEqual(FilterGroup.normalise("G"), .green)
        XCTAssertEqual(FilterGroup.normalise("Green"), .green)
    }

    func testBlue() {
        XCTAssertEqual(FilterGroup.normalise("B"), .blue)
        XCTAssertEqual(FilterGroup.normalise("Blue"), .blue)
    }

    // MARK: - Narrowband mono

    func testHalpha() {
        XCTAssertEqual(FilterGroup.normalise("Ha"), .ha)
        XCTAssertEqual(FilterGroup.normalise("Halpha"), .ha)
        XCTAssertEqual(FilterGroup.normalise("H-Alpha"), .ha)
        XCTAssertEqual(FilterGroup.normalise("H_Alpha"), .ha)
        XCTAssertEqual(FilterGroup.normalise("656nm"), .ha)
    }

    func testOIII() {
        XCTAssertEqual(FilterGroup.normalise("OIII"), .oiii)
        XCTAssertEqual(FilterGroup.normalise("O-III"), .oiii)
        XCTAssertEqual(FilterGroup.normalise("O3"), .oiii)
        XCTAssertEqual(FilterGroup.normalise("500nm"), .oiii)
    }

    func testSII() {
        XCTAssertEqual(FilterGroup.normalise("SII"), .sii)
        XCTAssertEqual(FilterGroup.normalise("S-II"), .sii)
        XCTAssertEqual(FilterGroup.normalise("S2"), .sii)
        XCTAssertEqual(FilterGroup.normalise("672nm"), .sii)
    }

    func testHbeta() {
        XCTAssertEqual(FilterGroup.normalise("Hbeta"), .hbeta)
        XCTAssertEqual(FilterGroup.normalise("H-Beta"), .hbeta)
        XCTAssertEqual(FilterGroup.normalise("Hb"), .hbeta)
        XCTAssertEqual(FilterGroup.normalise("486nm"), .hbeta)
    }

    // MARK: - Dual-narrowband OSC

    func testHO() {
        XCTAssertEqual(FilterGroup.normalise("HO"), .ho)
        XCTAssertEqual(FilterGroup.normalise("HOO"), .ho)
        XCTAssertEqual(FilterGroup.normalise("Optolong L-eXtreme"), .ho)
        XCTAssertEqual(FilterGroup.normalise("L-Ultimate"), .ho)
        XCTAssertEqual(FilterGroup.normalise("Antlia ALP-T"), .ho)
        XCTAssertEqual(FilterGroup.normalise("Dual Narrowband"), .ho)
        XCTAssertEqual(FilterGroup.normalise("Dual-Narrowband"), .ho)
        XCTAssertEqual(FilterGroup.normalise("Dual NB"), .ho)
    }

    func testSO() {
        XCTAssertEqual(FilterGroup.normalise("SO"), .so)
        XCTAssertEqual(FilterGroup.normalise("S+O"), .so)
        XCTAssertEqual(FilterGroup.normalise("SII+OIII"), .so)
        XCTAssertEqual(FilterGroup.normalise("SII + OIII"), .so)
        XCTAssertEqual(FilterGroup.normalise("C2"), .so)
        XCTAssertEqual(FilterGroup.normalise("Askar C2"), .so)
    }

    // MARK: - Tri-narrowband OSC

    func testSHO() {
        XCTAssertEqual(FilterGroup.normalise("SHO"), .sho)
        XCTAssertEqual(FilterGroup.normalise("L-eNhance"), .sho)
        XCTAssertEqual(FilterGroup.normalise("Triad Ultra"), .sho)
        XCTAssertEqual(FilterGroup.normalise("Tri-Band"), .sho)
        XCTAssertEqual(FilterGroup.normalise("Triband"), .sho)
    }

    // MARK: - Quad-narrowband

    func testQuadNB() {
        XCTAssertEqual(FilterGroup.normalise("Quad"), .quadNB)
        XCTAssertEqual(FilterGroup.normalise("4-Band"), .quadNB)
        XCTAssertEqual(FilterGroup.normalise("4band"), .quadNB)
    }

    // MARK: - Case insensitivity

    func testCaseInsensitive() {
        XCTAssertEqual(FilterGroup.normalise("ha"), .ha)
        XCTAssertEqual(FilterGroup.normalise("HA"), .ha)
        XCTAssertEqual(FilterGroup.normalise("oiii"), .oiii)
        XCTAssertEqual(FilterGroup.normalise("OIII"), .oiii)
        XCTAssertEqual(FilterGroup.normalise("luminance"), .luminance)
        XCTAssertEqual(FilterGroup.normalise("LUMINANCE"), .luminance)
    }

    // MARK: - isNarrowband

    func testNarrowbandClassification() {
        XCTAssertTrue(FilterGroup.ha.isNarrowband)
        XCTAssertTrue(FilterGroup.oiii.isNarrowband)
        XCTAssertTrue(FilterGroup.sii.isNarrowband)
        XCTAssertTrue(FilterGroup.hbeta.isNarrowband)
        XCTAssertTrue(FilterGroup.ho.isNarrowband)
        XCTAssertTrue(FilterGroup.so.isNarrowband)
        XCTAssertTrue(FilterGroup.sho.isNarrowband)
        XCTAssertTrue(FilterGroup.quadNB.isNarrowband)
    }

    func testBroadbandClassification() {
        XCTAssertFalse(FilterGroup.luminance.isNarrowband)
        XCTAssertFalse(FilterGroup.red.isNarrowband)
        XCTAssertFalse(FilterGroup.green.isNarrowband)
        XCTAssertFalse(FilterGroup.blue.isNarrowband)
        XCTAssertFalse(FilterGroup.unfiltered.isNarrowband)
    }
}

//
//  BayerPatternTests.swift
//  FITS Blaster Tests
//
//  Tests for BayerPattern: rOffset encoding and parse(from:) header lookup.
//

import XCTest
@testable import FITS_Blaster

final class BayerPatternTests: XCTestCase {

    // MARK: - rOffset encoding

    func testROffsetValues() {
        XCTAssertEqual(BayerPattern.rggb.rOffset, 0)
        XCTAssertEqual(BayerPattern.grbg.rOffset, 1)
        XCTAssertEqual(BayerPattern.gbrg.rOffset, 2)
        XCTAssertEqual(BayerPattern.bggr.rOffset, 3)
    }

    // MARK: - parse(from:) — BAYERPAT key

    func testParseFromBAYERPAT() {
        XCTAssertEqual(BayerPattern.parse(from: ["BAYERPAT": "RGGB"]), .rggb)
        XCTAssertEqual(BayerPattern.parse(from: ["BAYERPAT": "BGGR"]), .bggr)
        XCTAssertEqual(BayerPattern.parse(from: ["BAYERPAT": "GRBG"]), .grbg)
        XCTAssertEqual(BayerPattern.parse(from: ["BAYERPAT": "GBRG"]), .gbrg)
    }

    // MARK: - parse(from:) — COLORTYP key

    func testParseFromCOLORTYP() {
        XCTAssertEqual(BayerPattern.parse(from: ["COLORTYP": "RGGB"]), .rggb)
    }

    // MARK: - parse(from:) — CFA_PAT key

    func testParseFromCFA_PAT() {
        XCTAssertEqual(BayerPattern.parse(from: ["CFA_PAT": "BGGR"]), .bggr)
    }

    // MARK: - parse(from:) — key priority

    func testBAYERPATTakesPriorityOverCOLORTYP() {
        let headers = ["BAYERPAT": "RGGB", "COLORTYP": "BGGR"]
        XCTAssertEqual(BayerPattern.parse(from: headers), .rggb)
    }

    func testCOLORTYPTakesPriorityOverCFA_PAT() {
        let headers = ["COLORTYP": "GRBG", "CFA_PAT": "BGGR"]
        XCTAssertEqual(BayerPattern.parse(from: headers), .grbg)
    }

    // MARK: - parse(from:) — FITS string quoting

    func testParseStripsQuotesAndWhitespace() {
        // FITS headers often store values as "'RGGB    '" with padding
        XCTAssertEqual(BayerPattern.parse(from: ["BAYERPAT": "'RGGB            '"]), .rggb)
        XCTAssertEqual(BayerPattern.parse(from: ["BAYERPAT": "'  BGGR  '"]), .bggr)
    }

    // MARK: - parse(from:) — case insensitivity

    func testParseCaseInsensitive() {
        XCTAssertEqual(BayerPattern.parse(from: ["BAYERPAT": "rggb"]), .rggb)
        XCTAssertEqual(BayerPattern.parse(from: ["BAYERPAT": "Bggr"]), .bggr)
    }

    // MARK: - parse(from:) — nil cases

    func testParseReturnsNilForEmptyHeaders() {
        XCTAssertNil(BayerPattern.parse(from: [:]))
    }

    func testParseReturnsNilForUnrecognisedValue() {
        XCTAssertNil(BayerPattern.parse(from: ["BAYERPAT": "MONO"]))
    }

    func testParseReturnsNilWhenNoRelevantKey() {
        XCTAssertNil(BayerPattern.parse(from: ["OBJECT": "M31", "FILTER": "Ha"]))
    }
}

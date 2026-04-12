//
//  QualityScoreTests.swift
//  FITS Blaster Tests
//
//  Tests for MetricsCalculator.qualityScore: weight renormalisation,
//  boundary values, and expected scores for typical astrophotography data.
//

import XCTest
@testable import FITS_Blaster

final class QualityScoreTests: XCTestCase {

    // MARK: - All metrics nil

    func testAllNilReturnsZero() {
        let score = MetricsCalculator.qualityScore(fwhm: nil, eccentricity: nil,
                                                    snr: nil, starCount: nil)
        XCTAssertEqual(score, 0)
    }

    // MARK: - Perfect values

    func testPerfectFWHMAloneScores100() {
        // FWHM ≤ 2.0 → sub-score 1.0, renormalised to 100
        let score = MetricsCalculator.qualityScore(fwhm: 1.5, eccentricity: nil,
                                                    snr: nil, starCount: nil)
        XCTAssertEqual(score, 100)
    }

    func testPerfectEccentricityAloneScores100() {
        // Eccentricity 0 → sub-score 1.0
        let score = MetricsCalculator.qualityScore(fwhm: nil, eccentricity: 0,
                                                    snr: nil, starCount: nil)
        XCTAssertEqual(score, 100)
    }

    func testPerfectSNRAloneScores100() {
        // SNR ≥ 200 → sub-score 1.0
        let score = MetricsCalculator.qualityScore(fwhm: nil, eccentricity: nil,
                                                    snr: 250, starCount: nil)
        XCTAssertEqual(score, 100)
    }

    func testPerfectStarCountAloneScores100() {
        // 500+ stars → sub-score 1.0
        let score = MetricsCalculator.qualityScore(fwhm: nil, eccentricity: nil,
                                                    snr: nil, starCount: 600)
        XCTAssertEqual(score, 100)
    }

    func testAllPerfectScores100() {
        let score = MetricsCalculator.qualityScore(fwhm: 1.5, eccentricity: 0,
                                                    snr: 250, starCount: 600)
        XCTAssertEqual(score, 100)
    }

    // MARK: - Worst values

    func testWorstFWHMAloneScores0() {
        // FWHM ≥ 7.0 → sub-score 0.0
        let score = MetricsCalculator.qualityScore(fwhm: 10, eccentricity: nil,
                                                    snr: nil, starCount: nil)
        XCTAssertEqual(score, 0)
    }

    func testWorstEccentricityAloneScores0() {
        // Eccentricity ≥ 0.5 → sub-score 0.0
        let score = MetricsCalculator.qualityScore(fwhm: nil, eccentricity: 0.6,
                                                    snr: nil, starCount: nil)
        XCTAssertEqual(score, 0)
    }

    func testWorstSNRAloneScores0() {
        // SNR ≤ 10 → sub-score 0.0
        let score = MetricsCalculator.qualityScore(fwhm: nil, eccentricity: nil,
                                                    snr: 5, starCount: nil)
        XCTAssertEqual(score, 0)
    }

    func testZeroStarsScores0() {
        let score = MetricsCalculator.qualityScore(fwhm: nil, eccentricity: nil,
                                                    snr: nil, starCount: 0)
        XCTAssertEqual(score, 0)
    }

    // MARK: - Mid-range values

    func testMidRangeFWHM() {
        // FWHM 4.5 → (1 - (4.5-2)/5) = 0.5 → score 50
        let score = MetricsCalculator.qualityScore(fwhm: 4.5, eccentricity: nil,
                                                    snr: nil, starCount: nil)
        XCTAssertEqual(score, 50)
    }

    func testMidRangeEccentricity() {
        // Eccentricity 0.25 → (1 - 0.25/0.5) = 0.5 → score 50
        let score = MetricsCalculator.qualityScore(fwhm: nil, eccentricity: 0.25,
                                                    snr: nil, starCount: nil)
        XCTAssertEqual(score, 50)
    }

    func testMidRangeSNR() {
        // SNR 105 → (105-10)/190 = 0.5 → score 50
        let score = MetricsCalculator.qualityScore(fwhm: nil, eccentricity: nil,
                                                    snr: 105, starCount: nil)
        XCTAssertEqual(score, 50)
    }

    // MARK: - Weight renormalisation

    func testTwoMetricsRenormalise() {
        // FWHM perfect (1.0 × 0.35) + eccentricity perfect (1.0 × 0.35)
        // totalWeight = 0.70, weightedSum = 0.70, score = 100
        let score = MetricsCalculator.qualityScore(fwhm: 1.5, eccentricity: 0,
                                                    snr: nil, starCount: nil)
        XCTAssertEqual(score, 100)
    }

    func testMixedGoodAndBadRenormalises() {
        // FWHM perfect (1.0 × 0.35) + eccentricity worst (0.0 × 0.35)
        // totalWeight = 0.70, weightedSum = 0.35, score = 50
        let score = MetricsCalculator.qualityScore(fwhm: 1.5, eccentricity: 0.6,
                                                    snr: nil, starCount: nil)
        XCTAssertEqual(score, 50)
    }

    // MARK: - Typical astrophotography values

    func testTypicalGoodFrame() {
        // Good seeing: FWHM 2.5, round stars, decent SNR, healthy star count
        let score = MetricsCalculator.qualityScore(fwhm: 2.5, eccentricity: 0.15,
                                                    snr: 120, starCount: 350)
        XCTAssertGreaterThanOrEqual(score, 65)
        XCTAssertLessThanOrEqual(score, 90)
    }

    func testTypicalBadFrame() {
        // Poor seeing: bloated stars, trailing, low SNR from clouds
        let score = MetricsCalculator.qualityScore(fwhm: 5.5, eccentricity: 0.4,
                                                    snr: 25, starCount: 40)
        XCTAssertLessThanOrEqual(score, 30)
    }
}

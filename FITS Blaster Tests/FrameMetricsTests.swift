//
//  FrameMetricsTests.swift
//  FITS Blaster Tests
//
//  Tests for FrameMetrics: filtered(by:), merging, covers, hasData,
//  badgeProblem, and MetricsConfig.
//

import XCTest
@testable import FITS_Blaster

final class FrameMetricsTests: XCTestCase {

    // MARK: - Helpers

    /// Full metrics with known values for testing.
    private func fullMetrics(fwhm: Float = 3.0, eccentricity: Float = 0.2,
                             snr: Float = 100, starCount: Int = 200) -> FrameMetrics {
        FrameMetrics(fwhm: fwhm, eccentricity: eccentricity, snr: snr, starCount: starCount,
                     qualityScore: MetricsCalculator.qualityScore(fwhm: fwhm, eccentricity: eccentricity,
                                                                   snr: snr, starCount: starCount))
    }

    private func broadbandStats(medianFWHM: Float = 3.0, medianStarCount: Int = 200) -> GroupStats {
        GroupStats(medianFWHM: medianFWHM, medianEccentricity: 0.2,
                   medianStarCount: medianStarCount, medianSNR: 100,
                   medianScore: 70, topThirdScoreFloor: 80, isNarrowband: false)
    }

    // MARK: - hasData

    func testHasDataWithAllMetrics() {
        XCTAssertTrue(fullMetrics().hasData)
    }

    func testHasDataWithNoMetrics() {
        let m = FrameMetrics(fwhm: nil, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 0)
        XCTAssertFalse(m.hasData)
    }

    func testHasDataWithSingleMetric() {
        let m = FrameMetrics(fwhm: 3.0, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 50)
        XCTAssertTrue(m.hasData)
    }

    // MARK: - filtered(by:)

    func testFilteredKeepsEnabledMetrics() {
        let m = fullMetrics()
        let config = MetricsConfig(computeFWHM: true, computeEccentricity: false,
                                   computeSNR: true, computeStarCount: false)
        let filtered = m.filtered(by: config)

        XCTAssertNotNil(filtered.fwhm)
        XCTAssertNil(filtered.eccentricity)
        XCTAssertNotNil(filtered.snr)
        XCTAssertNil(filtered.starCount)
    }

    func testFilteredRecomputesScore() {
        let m = fullMetrics()
        let allEnabled = MetricsConfig()
        let fwhmOnly = MetricsConfig(computeFWHM: true, computeEccentricity: false,
                                     computeSNR: false, computeStarCount: false)

        let filteredAll  = m.filtered(by: allEnabled)
        let filteredFWHM = m.filtered(by: fwhmOnly)

        // Same FWHM but different active set → score is renormalised.
        // With only FWHM, the score reflects only FWHM quality.
        XCTAssertEqual(filteredFWHM.qualityScore,
                       MetricsCalculator.qualityScore(fwhm: m.fwhm, eccentricity: nil,
                                                       snr: nil, starCount: nil))
        // The all-enabled score should use all values.
        XCTAssertEqual(filteredAll.qualityScore, m.qualityScore)
    }

    func testFilteredAllDisabledReturnsZeroScore() {
        let m = fullMetrics()
        let config = MetricsConfig(computeFWHM: false, computeEccentricity: false,
                                   computeSNR: false, computeStarCount: false)
        let filtered = m.filtered(by: config)
        XCTAssertEqual(filtered.qualityScore, 0)
    }

    // MARK: - merging

    func testMergingPrefersOtherValues() {
        let base = FrameMetrics(fwhm: 3.0, eccentricity: 0.2, snr: nil, starCount: nil, qualityScore: 50)
        let other = FrameMetrics(fwhm: nil, eccentricity: nil, snr: 120, starCount: 300, qualityScore: 50)

        let merged = base.merging(other)

        XCTAssertEqual(merged.fwhm, 3.0)           // from base (other is nil)
        XCTAssertEqual(merged.eccentricity, 0.2)    // from base (other is nil)
        XCTAssertEqual(merged.snr, 120)             // from other
        XCTAssertEqual(merged.starCount, 300)       // from other
    }

    func testMergingOverridesBaseWithOtherNonNil() {
        let base  = FrameMetrics(fwhm: 3.0, eccentricity: 0.2, snr: 80, starCount: 150, qualityScore: 50)
        let other = FrameMetrics(fwhm: 2.5, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 50)

        let merged = base.merging(other)

        XCTAssertEqual(merged.fwhm, 2.5)            // other overrides base
        XCTAssertEqual(merged.eccentricity, 0.2)    // base kept
    }

    func testMergingRecomputesScore() {
        let base = FrameMetrics(fwhm: 3.0, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 50)
        let other = FrameMetrics(fwhm: nil, eccentricity: 0.1, snr: nil, starCount: nil, qualityScore: 50)

        let merged = base.merging(other)
        let expectedScore = MetricsCalculator.qualityScore(fwhm: 3.0, eccentricity: 0.1,
                                                            snr: nil, starCount: nil)
        XCTAssertEqual(merged.qualityScore, expectedScore)
    }

    // MARK: - covers

    func testCoversAllWhenAllPresent() {
        let m = fullMetrics()
        XCTAssertTrue(m.covers(MetricsConfig()))
    }

    func testCoversFailsWhenMissing() {
        let m = FrameMetrics(fwhm: 3.0, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 50)
        XCTAssertFalse(m.covers(MetricsConfig()))                  // needs all four
        XCTAssertTrue(m.covers(MetricsConfig(computeFWHM: true,    // only needs FWHM
                                             computeEccentricity: false,
                                             computeSNR: false,
                                             computeStarCount: false)))
    }

    func testCoversAllDisabledAlwaysTrue() {
        let m = FrameMetrics(fwhm: nil, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 0)
        let config = MetricsConfig(computeFWHM: false, computeEccentricity: false,
                                   computeSNR: false, computeStarCount: false)
        XCTAssertTrue(m.covers(config))
    }

    // MARK: - MetricsConfig

    func testNeedsStarDetectionAllEnabled() {
        XCTAssertTrue(MetricsConfig().needsStarDetection)
    }

    func testNeedsStarDetectionAllDisabled() {
        let config = MetricsConfig(computeFWHM: false, computeEccentricity: false,
                                   computeSNR: false, computeStarCount: false)
        XCTAssertFalse(config.needsStarDetection)
    }

    func testNeedsStarDetectionSingleEnabled() {
        let config = MetricsConfig(computeFWHM: false, computeEccentricity: false,
                                   computeSNR: true, computeStarCount: false)
        XCTAssertTrue(config.needsStarDetection)
    }

    // MARK: - badgeProblem

    func testTrailingDetected() {
        let m = fullMetrics(eccentricity: 0.6)
        XCTAssertEqual(m.badgeProblem(stats: broadbandStats()), .trailing)
    }

    func testTrailingNotDetectedAtThreshold() {
        let m = fullMetrics(eccentricity: 0.5)
        XCTAssertNotEqual(m.badgeProblem(stats: broadbandStats()), .trailing)
    }

    func testFocusFailDetected() {
        // FWHM > median × 1.5 (3.0 × 1.5 = 4.5)
        let m = fullMetrics(fwhm: 5.0, eccentricity: 0.1)
        XCTAssertEqual(m.badgeProblem(stats: broadbandStats(medianFWHM: 3.0)), .focusFail)
    }

    func testLowStarsDetectedBroadband() {
        // Stars < median × 0.40 (200 × 0.40 = 80)
        let m = fullMetrics(fwhm: 3.0, eccentricity: 0.1, starCount: 50)
        XCTAssertEqual(m.badgeProblem(stats: broadbandStats(medianStarCount: 200)), .lowStars)
    }

    func testLowStarsNarrowbandUsesTighterThreshold() {
        let stats = GroupStats(medianFWHM: 3.0, medianEccentricity: 0.2,
                               medianStarCount: 100, medianSNR: 80,
                               medianScore: 60, topThirdScoreFloor: 70, isNarrowband: true)

        // 35 stars: below 30% threshold (100 × 0.30 = 30)? No, 35 > 30 → no problem.
        let m1 = fullMetrics(fwhm: 3.0, eccentricity: 0.1, starCount: 35)
        XCTAssertNil(m1.badgeProblem(stats: stats))

        // 25 stars: below 30% threshold → lowStars.
        let m2 = fullMetrics(fwhm: 3.0, eccentricity: 0.1, starCount: 25)
        XCTAssertEqual(m2.badgeProblem(stats: stats), .lowStars)
    }

    func testNoProblemDetected() {
        let m = fullMetrics(fwhm: 3.0, eccentricity: 0.2, starCount: 200)
        XCTAssertNil(m.badgeProblem(stats: broadbandStats()))
    }

    func testNoProblemWithNilStats() {
        // Without group stats, only trailing can be detected.
        let m = fullMetrics(fwhm: 3.0, eccentricity: 0.2, starCount: 200)
        XCTAssertNil(m.badgeProblem(stats: nil))
    }

    func testTrailingTakesPriorityOverFocusFail() {
        // Both trailing (ecc > 0.5) and focus fail (FWHM >> median)
        let m = fullMetrics(fwhm: 8.0, eccentricity: 0.7)
        XCTAssertEqual(m.badgeProblem(stats: broadbandStats()), .trailing)
    }
}

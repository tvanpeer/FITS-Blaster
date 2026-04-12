//
//  FrameMetricsTests.swift
//  FITS Blaster Tests
//
//  Tests for FrameMetrics: filtered(by:), merging, covers, hasData,
//  badgeProblem, and MetricsConfig.
//

import Testing
@testable import FITS_Blaster

struct FrameMetricsTests {

    // MARK: - Helpers

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

    @Test("hasData with all metrics")
    func hasDataWithAllMetrics() {
        #expect(fullMetrics().hasData == true)
    }

    @Test("hasData with no metrics")
    func hasDataWithNoMetrics() {
        let m = FrameMetrics(fwhm: nil, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 0)
        #expect(m.hasData == false)
    }

    @Test("hasData with single metric")
    func hasDataWithSingleMetric() {
        let m = FrameMetrics(fwhm: 3.0, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 50)
        #expect(m.hasData == true)
    }

    // MARK: - filtered(by:)

    @Test("filtered keeps enabled metrics and nils disabled ones")
    func filteredKeepsEnabledMetrics() throws {
        let m = fullMetrics()
        let config = MetricsConfig(computeFWHM: true, computeEccentricity: false,
                                   computeSNR: true, computeStarCount: false)
        let filtered = m.filtered(by: config)

        _ = try #require(filtered.fwhm, "FWHM should be kept")
        #expect(filtered.eccentricity == nil, "Eccentricity should be nil")
        _ = try #require(filtered.snr, "SNR should be kept")
        #expect(filtered.starCount == nil, "Star count should be nil")
    }

    @Test("filtered recomputes score for active subset")
    func filteredRecomputesScore() {
        let m = fullMetrics()
        let fwhmOnly = MetricsConfig(computeFWHM: true, computeEccentricity: false,
                                     computeSNR: false, computeStarCount: false)

        let filtered = m.filtered(by: fwhmOnly)
        let expected = MetricsCalculator.qualityScore(fwhm: m.fwhm, eccentricity: nil,
                                                       snr: nil, starCount: nil)
        #expect(filtered.qualityScore == expected)
    }

    @Test("filtered with all disabled returns zero score")
    func filteredAllDisabledReturnsZeroScore() {
        let config = MetricsConfig(computeFWHM: false, computeEccentricity: false,
                                   computeSNR: false, computeStarCount: false)
        #expect(fullMetrics().filtered(by: config).qualityScore == 0)
    }

    // MARK: - merging

    @Test("merging fills in missing values from base")
    func mergingPrefersOtherValues() {
        let base = FrameMetrics(fwhm: 3.0, eccentricity: 0.2, snr: nil, starCount: nil, qualityScore: 50)
        let other = FrameMetrics(fwhm: nil, eccentricity: nil, snr: 120, starCount: 300, qualityScore: 50)
        let merged = base.merging(other)

        #expect(merged.fwhm == 3.0)
        #expect(merged.eccentricity == 0.2)
        #expect(merged.snr == 120)
        #expect(merged.starCount == 300)
    }

    @Test("merging overrides base with other's non-nil values")
    func mergingOverridesBase() {
        let base  = FrameMetrics(fwhm: 3.0, eccentricity: 0.2, snr: 80, starCount: 150, qualityScore: 50)
        let other = FrameMetrics(fwhm: 2.5, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 50)
        let merged = base.merging(other)

        #expect(merged.fwhm == 2.5, "Other's FWHM should override base")
        #expect(merged.eccentricity == 0.2, "Base eccentricity should be kept")
    }

    @Test("merging recomputes score")
    func mergingRecomputesScore() {
        let base = FrameMetrics(fwhm: 3.0, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 50)
        let other = FrameMetrics(fwhm: nil, eccentricity: 0.1, snr: nil, starCount: nil, qualityScore: 50)
        let merged = base.merging(other)
        let expected = MetricsCalculator.qualityScore(fwhm: 3.0, eccentricity: 0.1,
                                                       snr: nil, starCount: nil)
        #expect(merged.qualityScore == expected)
    }

    // MARK: - covers

    @Test("covers returns true when all requested metrics present")
    func coversAllWhenAllPresent() {
        #expect(fullMetrics().covers(MetricsConfig()) == true)
    }

    @Test("covers returns false when a requested metric is missing")
    func coversFailsWhenMissing() {
        let m = FrameMetrics(fwhm: 3.0, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 50)
        #expect(m.covers(MetricsConfig()) == false, "Needs all four")
        let fwhmOnly = MetricsConfig(computeFWHM: true, computeEccentricity: false,
                                     computeSNR: false, computeStarCount: false)
        #expect(m.covers(fwhmOnly) == true, "Only needs FWHM")
    }

    @Test("covers with all disabled always returns true")
    func coversAllDisabledAlwaysTrue() {
        let m = FrameMetrics(fwhm: nil, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 0)
        let config = MetricsConfig(computeFWHM: false, computeEccentricity: false,
                                   computeSNR: false, computeStarCount: false)
        #expect(m.covers(config) == true)
    }

    // MARK: - MetricsConfig

    @Test("needsStarDetection with all enabled")
    func needsStarDetectionAllEnabled() {
        #expect(MetricsConfig().needsStarDetection == true)
    }

    @Test("needsStarDetection with all disabled")
    func needsStarDetectionAllDisabled() {
        let config = MetricsConfig(computeFWHM: false, computeEccentricity: false,
                                   computeSNR: false, computeStarCount: false)
        #expect(config.needsStarDetection == false)
    }

    @Test("needsStarDetection with single enabled")
    func needsStarDetectionSingleEnabled() {
        let config = MetricsConfig(computeFWHM: false, computeEccentricity: false,
                                   computeSNR: true, computeStarCount: false)
        #expect(config.needsStarDetection == true)
    }

    // MARK: - badgeProblem

    @Test("Trailing detected when eccentricity > 0.5")
    func trailingDetected() {
        #expect(fullMetrics(eccentricity: 0.6).badgeProblem(stats: broadbandStats()) == .trailing)
    }

    @Test("Trailing not detected at eccentricity = 0.5")
    func trailingNotDetectedAtThreshold() {
        #expect(fullMetrics(eccentricity: 0.5).badgeProblem(stats: broadbandStats()) != .trailing)
    }

    @Test("Focus fail detected when FWHM > median × 1.5")
    func focusFailDetected() {
        let m = fullMetrics(fwhm: 5.0, eccentricity: 0.1)
        #expect(m.badgeProblem(stats: broadbandStats(medianFWHM: 3.0)) == .focusFail)
    }

    @Test("Low stars detected for broadband")
    func lowStarsDetectedBroadband() {
        let m = fullMetrics(fwhm: 3.0, eccentricity: 0.1, starCount: 50)
        #expect(m.badgeProblem(stats: broadbandStats(medianStarCount: 200)) == .lowStars)
    }

    @Test("Low stars uses tighter threshold for narrowband")
    func lowStarsNarrowbandThreshold() {
        let stats = GroupStats(medianFWHM: 3.0, medianEccentricity: 0.2,
                               medianStarCount: 100, medianSNR: 80,
                               medianScore: 60, topThirdScoreFloor: 70, isNarrowband: true)

        // 35 stars > 30% of 100 → no problem
        #expect(fullMetrics(fwhm: 3.0, eccentricity: 0.1, starCount: 35)
            .badgeProblem(stats: stats) == nil)
        // 25 stars < 30% of 100 → lowStars
        #expect(fullMetrics(fwhm: 3.0, eccentricity: 0.1, starCount: 25)
            .badgeProblem(stats: stats) == .lowStars)
    }

    @Test("No problem detected for normal values")
    func noProblemDetected() {
        #expect(fullMetrics().badgeProblem(stats: broadbandStats()) == nil)
    }

    @Test("No problem with nil stats (only trailing possible)")
    func noProblemWithNilStats() {
        #expect(fullMetrics().badgeProblem(stats: nil) == nil)
    }

    @Test("Trailing takes priority over focus fail")
    func trailingTakesPriority() {
        let m = fullMetrics(fwhm: 8.0, eccentricity: 0.7)
        #expect(m.badgeProblem(stats: broadbandStats()) == .trailing)
    }
}
